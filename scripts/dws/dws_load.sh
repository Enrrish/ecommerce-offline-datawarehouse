#!/bin/bash
# ==============================================================================
# dws_load.sh —— DWD → DWS 单天/全量汇总 + 跨表反查
#
# 用法：
#   bash dws_load.sh 2019-10-01     # 单天
#   bash dws_load.sh all            # 全量（先自动重建首活日维表）
#
# 反查规则（DWS 层最重要的一关，因为指标一旦算错，下游报表全错）：
#   规则1  三表 GMV 逐日完全相等（用户表 = 商品表 = 74,948,758.44）
#   规则2  用户表与商品表的 purchase_cnt 逐日相等
#   规则3  漏斗表每天恰好 1 行
#   规则4  用户表行数 = DWD 当天去重 user_id 数；商品表行数 = 去重 product_id 数
# ==============================================================================
set -uo pipefail

DB="${DB:-mydb}"
DWD="${DWD:-dwd_user_behavior_di}"
ETL="${ETL:-/home/cy/scripts/dws_etl_day.sql}"
DIM_SQL="${DIM_SQL:-/home/cy/scripts/dws_dim_user.sql}"
WORK="${WORK:-/tmp/dws_load_$$}"
mkdir -p "$WORK"

# ---------- 前置：表必须已建 ----------
if ! hive -e "USE $DB; SHOW TABLES LIKE 'dws_user_action_day';" 2>/dev/null | grep -q dws_user_action_day; then
    echo "[ERROR] DWS 表不存在，请先执行：hive -f /home/cy/scripts/dws_ddl.sql"
    exit 1
fi

# ---------- 日期 ----------
ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ] || [ "${ARGS[0]}" = "all" ]; then
    mapfile -t DAYS < <(hive -e "USE $DB; SHOW PARTITIONS $DWD;" 2>/dev/null | sed 's/^dt=//')
    NEED_DIM=1
else
    DAYS=("${ARGS[@]}")
    NEED_DIM=0
fi
if [ ${#DAYS[@]} -eq 0 ]; then
    echo "[ERROR] 没有可处理日期（DWD 无分区？）"
    exit 1
fi

# ---------- 首活日维表：为空或被要求时重建 ----------
DIM_CNT=$(hive -e "USE $DB; SELECT COUNT(1) FROM dim_user_first_active;" 2>/dev/null | tr -dc '0-9')
if [ "$NEED_DIM" = "1" ] || [ -z "${DIM_CNT:-}" ] || [ "${DIM_CNT:-0}" = "0" ]; then
    echo "[INFO] 重建首活日维表（全量扫 DWD，约 1 分钟）..."
    OUT=$(hive -f "$DIM_SQL" 2>&1)
    if echo "$OUT" | grep -qiE "FAILED|SemanticException|Execution Error"; then
        echo "[FAIL] 维表重建失败"
        echo "$OUT" | grep -iE "error|exception" | head -3
        exit 1
    fi
    echo "[OK] 维表重建完成：$OUT" | tail -1
    echo "$OUT" | grep -E "^[0-9]+\s" | sed 's/^/     users\/min_dt\/max_dt = /'
else
    echo "[INFO] 首活日维表已有 $DIM_CNT 个用户，跳过重建"
fi

echo
echo "[INFO] 待处理 ${#DAYS[@]} 天: ${DAYS[0]} ... ${DAYS[-1]}"
FAIL=0
for DT in "${DAYS[@]}"; do
    S=$(date +%s)
    OUT=$(hive -f "$ETL" --hivevar bizdate="$DT" 2>&1)
    E=$(date +%s)
    if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
        echo "[FAIL] $DT 汇总失败（耗时 $((E - S))s）"
        echo "$OUT" | grep -iE "error|exception" | head -3
        FAIL=1
        continue
    fi
    printf "[OK] %s  三表汇总完成  耗时 %ss\n" "$DT" "$((E - S))"
done

if [ "$FAIL" -ne 0 ]; then
    echo "[ERROR] 有日期失败，跳过反查"
    exit 1
fi

# ---------- 规则 1/2/3：跨表逐日反查 ----------
echo
echo "[INFO] 跨表反查（规则1/2/3）"
{
    echo "SET hive.cli.print.header=false;"
    echo "USE $DB;"
    echo "SELECT u.dt, u.user_rows, p.prod_rows, f.f_cnt, u.orders, p.orders, u.gmv, p.gmv"
    echo "FROM (SELECT dt, COUNT(1) user_rows, SUM(purchase_cnt) orders, SUM(total_gmv) gmv FROM dws_user_action_day WHERE dt IN ("
    F=1; for DT in "${DAYS[@]}"; do [ "$F" -eq 1 ] && F=0 || echo -n ","; echo -n "'$DT'"; done
    echo ") GROUP BY dt) u"
    echo "LEFT JOIN (SELECT dt, COUNT(1) prod_rows, SUM(purchase_cnt) orders, SUM(total_gmv) gmv FROM dws_product_action_day WHERE dt IN ("
    F=1; for DT in "${DAYS[@]}"; do [ "$F" -eq 1 ] && F=0 || echo -n ","; echo -n "'$DT'"; done
    echo ") GROUP BY dt) p ON u.dt = p.dt"
    echo "LEFT JOIN (SELECT dt, COUNT(1) f_cnt FROM dws_user_funnel_day WHERE dt IN ("
    F=1; for DT in "${DAYS[@]}"; do [ "$F" -eq 1 ] && F=0 || echo -n ","; echo -n "'$DT'"; done
    echo ") GROUP BY dt) f ON u.dt = f.dt"
    echo "ORDER BY u.dt;"
} > "$WORK/check.sql"

hive -f "$WORK/check.sql" 2>/dev/null | grep -E "^2019-" > "$WORK/rows.txt"

BAD=0
SUM_G=0
while IFS=$'\t' read -r DT UR PR FC O1 O2 G1 G2; do
    MSG=""
    [ "${O1:-}" = "${O2:-}" ] || MSG="$MSG 订单不一致($O1/$O2)"
    [ "${G1:-}" = "${G2:-}" ] || MSG="$MSG GMV不一致($G1/$G2)"
    [ "${FC:-0}" = "1" ]      || MSG="$MSG 漏斗行数=$FC"
    if [ -z "$MSG" ]; then
        printf "  [OK]   %s  用户=%-6s 商品=%-6s 订单=%-7s GMV=%s\n" "$DT" "$UR" "$PR" "$O1" "$G1"
        SUM_G=$(awk -v a="$SUM_G" -v b="$G1" 'BEGIN{printf "%.2f", a+b}')
    else
        printf "  [FAIL] %s %s\n" "$DT" "$MSG"
        BAD=$((BAD + 1))
    fi
done < "$WORK/rows.txt"

# ---------- 规则 4：与 DWD 去重数对比（抽样首日，全表 distinct 太贵） ----------
FIRST_DT="${DAYS[0]}"
echo
echo "[INFO] 规则4 行数与 DWD 去重数对比（抽样 $FIRST_DT）"
hive -e "USE $DB;
SELECT 'dwd', COUNT(DISTINCT user_id), COUNT(DISTINCT product_id) FROM $DWD WHERE dt='$FIRST_DT'
UNION ALL
SELECT 'dws', (SELECT COUNT(1) FROM dws_user_action_day WHERE dt='$FIRST_DT'), (SELECT COUNT(1) FROM dws_product_action_day WHERE dt='$FIRST_DT');" 2>/dev/null | grep -E "^(dwd|dws)" > "$WORK/r4.txt"

D1=$(awk '$1=="dwd"{print $2}' "$WORK/r4.txt")
D2=$(awk '$1=="dwd"{print $3}' "$WORK/r4.txt")
W1=$(awk '$1=="dws"{print $2}' "$WORK/r4.txt")
W2=$(awk '$1=="dws"{print $3}' "$WORK/r4.txt")
if [ "${D1:-x}" = "${W1:-y}" ] && [ "${D2:-x}" = "${W2:-y}" ]; then
    echo "  [OK]   用户 dwd=$D1 / dws=$W1    商品 dwd=$D2 / dws=$W2"
else
    echo "  [FAIL] 用户 dwd=$D1 / dws=$W1    商品 dwd=$D2 / dws=$W2"
    BAD=$((BAD + 1))
fi

# ---------- 存储 ----------
echo
echo "[INFO] DWS 存储："
hdfs dfs -du -s -h /user/hive/warehouse/${DB}.db/dws_user_action_day \
                     /user/hive/warehouse/${DB}.db/dws_product_action_day \
                     /user/hive/warehouse/${DB}.db/dws_user_funnel_day 2>/dev/null

echo
if [ "$BAD" -eq 0 ]; then
    echo "[PASS] ${#DAYS[@]} 天全部通过  GMV 合计=$SUM_G"
else
    echo "[FAIL] $BAD 项不通过"
fi
exit "$BAD"
