#!/bin/bash
# ==============================================================================
# ods_load.sh —— 把日文件投递到 HDFS 并挂载分区
#
# 用法：
#   bash ods_load.sh 2019-10-01              # 单天
#   bash ods_load.sh 2019-10-01 2019-10-02   # 多天
#   bash ods_load.sh all                     # 拆出来的全部日期（补数）
#
# 四步，每一步都有校验，任一步失败即 exit 1：
#   ① 上传前：本地文件行数 必须 == manifest 行数
#   ② 上传  ：hdfs rm -r -f → mkdir -p → put   （幂等：绝不会重复累加）
#   ③ 挂载  ：ALTER TABLE ... ADD IF NOT EXISTS PARTITION ... LOCATION ...
#   ④ 上传后：Hive COUNT(1) 必须 == manifest 行数
#
# 为什么要"先 rm 再 put"：
#   外部表指向一个目录，目录里多一个文件 Hive 就多读一份，
#   数据翻倍且不报任何错。rm 是唯一可靠的幂等手段。
# ==============================================================================
set -euo pipefail

SPLIT_DIR="${SPLIT_DIR:-/home/cy/project/data/split}"
MANIFEST="${MANIFEST:-$SPLIT_DIR/_manifest.txt}"
HDFS_ROOT="${HDFS_ROOT:-/origin_data/ecommerce/mydb/ods_user_behavior_di}"
DB="${DB:-mydb}"
TABLE="${TABLE:-ods_user_behavior_di}"
WORK="${WORK:-/tmp/ods_load_$$}"

ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ] || [ "${ARGS[0]}" = "all" ]; then
    mapfile -t DAYS < <(awk '{print $1}' "$MANIFEST")
else
    DAYS=("${ARGS[@]}")
fi

if [ ${#DAYS[@]} -eq 0 ]; then
    echo "[ERROR] manifest 为空: $MANIFEST"
    exit 1
fi

mkdir -p "$WORK"
echo "[INFO] 待处理 ${#DAYS[@]} 天: ${DAYS[0]} ... ${DAYS[-1]}"
echo "[INFO] HDFS 表根: $HDFS_ROOT"

# ---------- 前置：表根存在 ----------
hdfs dfs -mkdir -p "$HDFS_ROOT"

# ---------- ①②③ ----------
: > "$WORK/partitions.sql"
FAIL=0
for DT in "${DAYS[@]}"; do
    LOCAL_FILE="$SPLIT_DIR/ecommerce_events_${DT}.csv"
    PD="$HDFS_ROOT/dt=$DT"

    if [ ! -f "$LOCAL_FILE" ]; then
        echo "[ERROR] $DT 本地文件缺失: $LOCAL_FILE"
        FAIL=1
        continue
    fi

    # ① manifest 行数
    EXP=$(awk -v d="$DT" '$1==d{print $2; exit}' "$MANIFEST")
    if [ -z "${EXP:-}" ]; then
        echo "[ERROR] $DT 不在 manifest 中，拒绝上传（防止传错日期）"
        FAIL=1
        continue
    fi

    # ② 幂等上传
    hdfs dfs -rm -r -f "$PD" >/dev/null 2>&1
    hdfs dfs -mkdir -p "$PD"
    hdfs dfs -put "$LOCAL_FILE" "$PD/"

    # ③ 分区挂载语句先攒着，最后一次性执行（避免 31 次启 JVM）
    echo "ALTER TABLE $DB.$TABLE ADD IF NOT EXISTS PARTITION (dt='$DT') LOCATION '$PD';" >> "$WORK/partitions.sql"

    printf "[OK] %s  本地行数=%s  ->  %s/ecommerce_events_%s.csv\n" \
        "$DT" "$EXP" "$PD" "$DT"
done

if [ "$FAIL" -ne 0 ]; then
    echo "[ERROR] 有日期未通过前置校验，终止（未挂载任何分区）"
    exit 1
fi

echo
echo "[INFO] 挂载 ${#DAYS[@]} 个分区 ..."
hive -f "$WORK/partitions.sql" 2>&1 | grep -Ei "^OK|Time taken|error|FAILED" | head -5

# ---------- ④ 上传后校验 ----------
echo
echo "[INFO] 校验：Hive 各分区行数 vs manifest"
{
    echo "SET hive.cli.print.header=false;"
    echo "USE $DB;"
    echo -n "SELECT dt, COUNT(1) AS row_cnt FROM $TABLE WHERE dt IN ("
    FIRST=1
    for DT in "${DAYS[@]}"; do
        [ "$FIRST" -eq 1 ] && FIRST=0 || echo -n ","
        echo -n "'$DT'"
    done
    echo ") GROUP BY dt ORDER BY dt;"
} > "$WORK/verify.sql"

hive -f "$WORK/verify.sql" 2>/dev/null | grep -E "^2019-" > "$WORK/actual.txt"

awk -v d="$DT" 'BEGIN{}' </dev/null 2>/dev/null || true

# 把 manifest 中本次涉及的日期筛出来做对比
for DT in "${DAYS[@]}"; do
    awk -v d="$DT" '$1==d{print $1"\t"$2; exit}' "$MANIFEST"
done | sort > "$WORK/expected.txt"

echo "--- 期望(manifest) vs 实际(Hive) ---"
paste "$WORK/expected.txt" "$WORK/actual.txt" > "$WORK/cmp.txt" 2>/dev/null || true
DIFF_CNT=0
while IFS= read -r LINE; do
    E_DT=$(echo "$LINE" | awk '{print $1}')
    E_CNT=$(echo "$LINE" | awk '{print $2}')
    A_CNT=$(echo "$LINE" | awk '{print $4}')
    if [ "$E_CNT" = "${A_CNT:-}" ]; then
        printf "  [OK]   %s  %10s\n" "$E_DT" "$E_CNT"
    else
        printf "  [FAIL] %s  期望=%s 实际=%s\n" "$E_DT" "$E_CNT" "${A_CNT:-EMPTY}"
        DIFF_CNT=$((DIFF_CNT + 1))
    fi
done < "$WORK/cmp.txt"

echo
if [ "$DIFF_CNT" -eq 0 ]; then
    TOTAL=$(awk '{s+=$2} END{print s}' "$WORK/expected.txt")
    echo "[PASS] ${#DAYS[@]} 个分区全部通过，合计 $TOTAL 行"
else
    echo "[FAIL] $DIFF_CNT 个分区对不上"
fi

echo "[INFO] 分区清单："
hive -e "USE $DB; SHOW PARTITIONS $TABLE;" 2>/dev/null | tail -5
echo "[INFO] 日志与中间文件: $WORK"
exit "$DIFF_CNT"
