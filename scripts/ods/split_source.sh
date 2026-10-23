#!/bin/bash
# ==============================================================================
# split_source.sh —— 按天拆分源数据，模拟上游"每日投递一个文件"
#
# 用法：
#   bash split_source.sh                 # 拆分全部
#   SRC_FILE=/path/to/xxx.csv bash split_source.sh
#
# 设计要点（面试能讲的）：
#   1) 只做"纵向切分"，不改动任何一个字段的内容 —— 这不是加工，是模拟投递
#   2) NR>1 跳过表头，拆分后的日文件天然无表头
#      => 建表时不需要 skip.header.line.count（见 ods_ddl.sql 说明）
#   3) sub(/\r$/,"") 去掉 Windows CRLF 的 \r
#      => 不在 DWD 用 REGEXP_REPLACE 补救，源头解决
#   4) 先 rm 再生成，保证幂等：跑几次结果都一样
#   5) 产出 manifest（日期 + 行数），后续校验以它为准
# ==============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-/home/cy/project/data}"
SRC_FILE="${SRC_FILE:-$SRC_DIR/ecommerce_events.csv}"
OUT_DIR="${OUT_DIR:-$SRC_DIR/split}"
MANIFEST="${MANIFEST:-$OUT_DIR/_manifest.txt}"

if [ ! -f "$SRC_FILE" ]; then
    echo "[ERROR] 源文件不存在: $SRC_FILE"
    exit 1
fi

echo "[INFO] 源文件: $SRC_FILE  ($(stat -c %s "$SRC_FILE") 字节)"
echo "[INFO] 输出目录: $OUT_DIR"

# 幂等：清掉上一次的拆分结果（先删再建，保证跑几次结果都一样）
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# 磁盘预检：拆分会再产生一份 1.2G，空间不够要提前发现
echo "[INFO] 磁盘余量："
df -h "$OUT_DIR" | tail -1

echo "[INFO] 开始拆分 $(date '+%F %T') ..."

awk -v OUT="$OUT_DIR" -F',' '
NR == 1 { next }                                   # 跳过表头
{
    sub(/\r$/, "")                                 # 去掉 CRLF 的 \r
    d = substr($1, 1, 10)
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        bad++
        next
    }
    print > (OUT "/ecommerce_events_" d ".csv")
    cnt[d]++
    total++
}
END {
    n = 0
    for (k in cnt) n++
    printf "[AWK] 日期数=%d  有效行=%d  异常行=%d\n", n, total + 0, bad + 0
    # 输出 manifest：日期 行数（排序后写入，便于 diff）
    for (k in cnt) printf "%s\t%d\n", k, cnt[k]
}
' "$SRC_FILE" | tee /tmp/_awk_out.txt | grep '^\[AWK\]'

# manifest 只需要日期+行数的行，去掉 [AWK] 那行后排序
grep -v '^\[AWK\]' /tmp/_awk_out.txt | sort > "$MANIFEST"
rm -f /tmp/_awk_out.txt

FILE_CNT=$(ls -1 "$OUT_DIR"/ecommerce_events_*.csv 2>/dev/null | wc -l)
DAY_CNT=$(wc -l < "$MANIFEST")
TOTAL=$(awk '{s+=$2} END{print s}' "$MANIFEST")

echo
echo "[INFO] 拆分完成 $(date '+%F %T')"
echo "[INFO] 生成文件数: $FILE_CNT   日期数: $DAY_CNT   总行数: $TOTAL"
echo
echo "===== manifest ($MANIFEST) ====="
cat "$MANIFEST"
echo "================================"
echo
echo "[INFO] 抽样检查第一个文件前 2 行："
head -2 "$(ls -1 "$OUT_DIR"/ecommerce_events_*.csv | head -1)"
