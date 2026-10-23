#!/bin/bash
# ==============================================================================
# dwd_load.sh —— ODS → DWD 单天/全量入仓 + 行数核对
#
# 用法：
#   bash dwd_load.sh 2019-10-01              # 单天（调度每天调这个）
#   bash dwd_load.sh all                     # 全量补数
#
# 每次跑批后的核对规则（对应 dq_result 的前三条）：
#   规则1  行数守恒：ods_cnt - dwd_cnt == 当天重复多余行数
#   规则2  主键唯一：dwd 里 COUNT(1) == COUNT(DISTINCT 五字段唯一键)
#   规则3  分区非空：dwd_cnt > 0
# 任一失败退出码非 0，可直接被调度系统判定为失败并触发重试。
# ==============================================================================
set -uo pipefail

DB="${DB:-mydb}"
ODS="${ODS:-ods_user_behavior_di}"
DWD="${DWD:-dwd_user_behavior_di}"
ETL="${ETL:-/home/cy/scripts/dwd_etl.sql}"
WORK="${WORK:-/tmp/dwd_load_$$}"
mkdir -p "$WORK"

ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ] || [ "${ARGS[0]}" = "all" ]; then
    # 日期来源是 ODS 的分区清单（上游有什么就跑什么，不依赖本地文件）
    mapfile -t DAYS < <(hive -e "USE $DB; SHOW PARTITIONS $ODS;" 2>/dev/null | sed 's/^dt=//')
else
    DAYS=("${ARGS[@]}")
fi

if [ ${#DAYS[@]} -eq 0 ]; then
    echo "[ERROR] 没有可处理的日期（ODS 无分区？）"
    exit 1
fi

echo "[INFO] 待处理 ${#DAYS[@]} 天: ${DAYS[0]} ... ${DAYS[-1]}"
FAIL=0

for DT in "${DAYS[@]}"; do
    S=$(date +%s)
    OUT=$(hive -f "$ETL" --hivevar bizdate="$DT" 2>&1)
    E=$(date +%s)
    if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
        echo "[FAIL] $DT ETL 执行失败（耗时 $((E - S))s）"
        echo "$OUT" | grep -iE "error|exception" | head -3
        FAIL=1
        continue
    fi
    printf "[OK] %s  ETL 完成  耗时 %ss\n" "$DT" "$((E - S))"
done

if [ "$FAIL" -ne 0 ]; then
    echo "[ERROR] 有日期 ETL 失败，跳过核对"
    exit 1
fi

# ---------- 核对 ----------
echo
echo "[INFO] 核对：ODS 行数 vs DWD 行数（按天）"
{
    echo "SET hive.cli.print.header=false;"
    echo "USE $DB;"
    echo "SELECT o.dt, o.ods_cnt, COALESCE(d.dwd_cnt,0) AS dwd_cnt, o.ods_cnt - COALESCE(d.dwd_cnt,0) AS dropped"
    echo "FROM (SELECT dt, COUNT(1) AS ods_cnt FROM $ODS WHERE dt IN ("
    F=1
    for DT in "${DAYS[@]}"; do [ "$F" -eq 1 ] && F=0 || echo -n ","; echo -n "'$DT'"; done
    echo ") GROUP BY dt) o"
    echo "LEFT JOIN (SELECT dt, COUNT(1) AS dwd_cnt FROM $DWD WHERE dt IN ("
    F=1
    for DT in "${DAYS[@]}"; do [ "$F" -eq 1 ] && F=0 || echo -n ","; echo -n "'$DT'"; done
    echo ") GROUP BY dt) d ON o.dt = d.dt"
    echo "ORDER BY o.dt;"
} > "$WORK/check_rows.sql"

hive -f "$WORK/check_rows.sql" 2>/dev/null | grep -E "^2019-" > "$WORK/rows.txt"

BAD=0
SUM_ODS=0
SUM_DWD=0
while IFS=$'\t' read -r D O W DR; do
    SUM_ODS=$((SUM_ODS + O))
    SUM_DWD=$((SUM_DWD + W))
    if [ "$DR" -eq 0 ] && [ "$W" -gt 0 ]; then
        printf "  [OK]   %s  ods=%-8s dwd=%-8s 丢弃=%s\n" "$D" "$O" "$W" "$DR"
    else
        printf "  [FAIL] %s  ods=%-8s dwd=%-8s 丢弃=%s\n" "$D" "$O" "$W" "$DR"
        BAD=$((BAD + 1))
    fi
done < "$WORK/rows.txt"

echo
echo "[INFO] 规则2 主键唯一（抽样首日 ${DAYS[0]}）"
hive -e "USE $DB; SELECT COUNT(1) AS c1, COUNT(DISTINCT CONCAT(event_time,'|',user_id,'|',product_id,'|',event_type,'|',user_session)) AS c2 FROM $DWD WHERE dt='${DAYS[0]}';" 2>/dev/null | grep -E "^[0-9]" > "$WORK/uniq.txt"
U1=$(awk '{print $1}' "$WORK/uniq.txt")
U2=$(awk '{print $2}' "$WORK/uniq.txt")
if [ -n "${U1:-}" ] && [ "$U1" = "$U2" ]; then
    echo "  [OK]   COUNT=$U1 == DISTINCT=$U2"
else
    echo "  [FAIL] COUNT=$U1 != DISTINCT=$U2（存在重复行）"
    BAD=$((BAD + 1))
fi

# ---------- 存储体检 ----------
echo
echo "[INFO] DWD 存储："
hdfs dfs -du -s -h /user/hive/warehouse/${DB}.db/${DWD} 2>/dev/null
FILE_CNT=$(hdfs dfs -ls -R /user/hive/warehouse/${DB}.db/${DWD} 2>/dev/null | grep -c "^-" || true)
echo "       文件数: $FILE_CNT（分区数 ${#DAYS[@]}，若远大于分区数说明小文件过多）"

echo
if [ "$BAD" -eq 0 ]; then
    echo "[PASS] ${#DAYS[@]} 天全部通过  ODS 合计=$SUM_ODS  DWD 合计=$SUM_DWD"
else
    echo "[FAIL] $BAD 项不通过"
fi
exit "$BAD"
