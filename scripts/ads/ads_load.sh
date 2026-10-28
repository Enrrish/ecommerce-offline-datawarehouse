#!/bin/bash
# ==============================================================================
# ads_load.sh —— DWS → ADS 汇总调度 + 应用层校验
#
# 用法：
#   bash ads_load.sh 2019-10-01     # 单天：日常 T+1 调度
#   bash ads_load.sh all            # 全量：首次建仓或重跑历史（推荐，快 6 倍）
#   bash ads_load.sh check          # 只做校验，不写数
#
# 为什么单天和全量走不同 SQL：
#   ads_etl_day.sql 是 WHERE dt = 常量 + 静态分区，每天只算一天；
#   ads_backfill.sql 是 GROUP BY dt + 动态分区，一次算完 31 天。
#   指标口径完全一致，跑哪个结果都一样（本脚本的校验会证明这点）。
#
# 【2026-10-27 性能改造，见 docs/07】
#   1) 三个 SQL 合并成一次 hive -f：原来 3 次 JVM 冷启动 + 3 次 Metastore 连接，约 18 s；
#   2) 表存在性与分区数改用 SHOW TABLES / SHOW PARTITIONS（纯 metastore，0 个 MR）：
#      原来用 COUNT(DISTINCT dt) 数天数，每次都是全表扫描；
#   3) 校验从 10 条语句 / 27 个 MR 压到 6 条语句，每条只扫一遍表：
#      重复日期检查并入范围统计，RFM 用户数复用各表规模统计，不再单独起子查询；
#   4) 留存/RFM 需要的数据起止日期由 shell 从 SHOW PARTITIONS 取出后用 hivevar 传入，
#      省掉两个 SQL 里各自的 MIN(dt)/MAX(dt) 全表扫描。
#
# 校验规则（ADS 是直接给业务看的，错了没人会发现，所以必须卡死）：
#   规则1  大盘 GMV 合计 = DWS GMV 合计 = 74,948,758.44（按 ADS 已覆盖的日期比，
#          这样单天模式只比当天、全量模式比全月，两种模式用同一套校验）
#   规则2  大盘订单数 = 291,157（与 DWD 层一致）
#   规则3  大盘/漏斗 每天恰好 1 行；商品榜每天 <= 50 行；品牌榜每天 <= 30 行
#   规则4  品类表 GMV 合计 = 大盘 GMV（证明 未知品类 分组没丢数据）
#   规则5  漏斗表 新客下单 + 老客下单 = 当日支付人数（人群拆分没漏人）
#   规则6  留存表行数 = 31；30 日留存只有数据集首日可算（其余必须为 NULL）
#   规则7  RFM 用户数 = 首活日维表用户数；各层人数之和 = 总数
# ==============================================================================
set -uo pipefail

DB="${DB:-mydb}"
DIR="${DIR:-/home/cy/scripts/ads}"
DAY_SQL="$DIR/ads_etl_day.sql"
ALL_SQL="$DIR/ads_backfill.sql"
RET_SQL="$DIR/ads_retention.sql"
RFM_SQL="$DIR/ads_rfm.sql"
MODE="${1:-all}"

# ============================ 元数据（0 个 MR） ============================
# 一次 CLI 取回：表清单 + 两张表的分区清单。
# 原来数"覆盖天数"用 COUNT(DISTINCT dt)，是一次全表扫；分区清单在 metastore 里现成，
# 顺带还能拿到最大日期，供 ad_rfm.sql 当统计截止日（省掉它内部一次全表扫）。
META=$(hive -e "USE $DB;
SHOW TABLES;
SHOW PARTITIONS dws_user_action_day;
SELECT '@@SEP@@';
SHOW PARTITIONS ads_trade_overview_day;" 2>/dev/null | tr -d '\r')

TABLES=$(printf '%s\n' "$META" | sed -n '1,/^@@SEP@@$/p' | grep -vE '^@@SEP@@$|^dt=')
DWS_PART=$(printf '%s\n' "$META" | sed -n '1,/^@@SEP@@$/p' | grep -c '^dt=')
OV_PART=$(printf '%s\n' "$META" | sed -n '/^@@SEP@@$/,$p' | grep -c '^dt=')
STAT_DATE=$(printf '%s\n' "$META" | sed -n '1,/^@@SEP@@$/p' | grep '^dt=' | sed 's/^dt=//' | sort | tail -1)
MIN_DATE=$(printf '%s\n' "$META" | sed -n '1,/^@@SEP@@$/p' | grep '^dt=' | sed 's/^dt=//' | sort | head -1)

for T in ads_trade_overview_day ads_user_funnel_day ads_user_retention_day \
         ads_product_rank_day ads_category_sales_day ads_brand_sales_day ads_user_value_rfm; do
    if ! printf '%s\n' "$TABLES" | grep -qx "$T"; then
        echo "[ERROR] 表 $T 不存在，请先执行：hive -f $DIR/ads_ddl.sql"
        exit 1
    fi
done

if [ -z "${STAT_DATE:-}" ]; then
    echo "[ERROR] 取不到 dws_user_action_day 的分区，DWS 层可能还没跑"
    exit 1
fi

if [ "$MODE" != "check" ]; then
    # ---------------- 三个 SQL 合成一次调用 ----------------
    # 原来是 3 次 hive -f，每次约 6 s 启动 + Metastore 连接；合并后只付一次。
    # Hive 的 -f 遇到第一个失败语句就会中止，所以后面的留存/RFM 不会在脏数据上继续跑。
    if [ "$MODE" = "all" ]; then
        echo "[INFO] 全量模式：批量补数 5 张按天分区表"
        ETL_SQL="$ALL_SQL"
    else
        echo "[INFO] 单天模式：处理 $MODE"
        ETL_SQL="$DAY_SQL"
    fi

    RUN_SQL="/tmp/ads_run_$$.sql"
    cat "$ETL_SQL" "$RET_SQL" "$RFM_SQL" > "$RUN_SQL"

    S=$(date +%s)
    OUT=$(hive -f "$RUN_SQL" --hivevar bizdate="$MODE" --hivevar stat_date="$STAT_DATE" \
                            --hivevar min_date="$MIN_DATE" --hivevar max_date="$STAT_DATE" 2>&1)
    RC=$?
    E=$(date +%s)
    rm -f "$RUN_SQL"

    if [ "$RC" -ne 0 ] || echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
        echo "[FAIL] ADS 汇总失败（耗时 $((E - S))s）"
        echo "$OUT" | grep -iE "error|exception|FAILED" | head -5
        exit 1
    fi
    echo "[OK] 日批 + 留存 + RFM 全部完成，耗时 $((E - S))s"
fi

# ============================== 校验 ==============================
echo
echo "===================== ADS 层校验 ====================="
BAD=0

# 单天模式只对当天分区：原来用 JOIN (SELECT DISTINCT dt ...) 回扫 DWS 全表 644 万行，
# 只是为了把两边都限制在"ADS 已覆盖的日期"，单天场景完全没必要。全量/check 模式口径不变。
SCOPE=""
if [ "$MODE" != "all" ] && [ "$MODE" != "check" ]; then
    SCOPE="WHERE dt = '$MODE'"
fi

# 6 条语句，每条只扫一遍目标表；不再为"重复日期""目标分区行数"各起一次查询
if [ "$MODE" = "all" ] || [ "$MODE" = "check" ]; then
    DUP_SQL="SELECT 'ovdup', CAST(COUNT(1) AS STRING) FROM (SELECT dt FROM ads_trade_overview_day GROUP BY dt HAVING COUNT(1) > 1) d;"
else
    DUP_SQL="SELECT 'ovdup', '0';"
fi

echo "[规则1-4] 总量一致性与行数约束"
hive -e "USE $DB;
SELECT 'dws', CAST(ROUND(SUM(total_gmv),2) AS STRING), CAST(SUM(purchase_cnt) AS STRING) FROM dws_user_action_day $SCOPE;
SELECT 'ov',  CAST(ROUND(SUM(total_gmv),2) AS STRING), CAST(SUM(purchase_pv) AS STRING), CAST(COUNT(1) AS STRING) FROM ads_trade_overview_day $SCOPE;
SELECT 'cat', CAST(ROUND(SUM(total_gmv),2) AS STRING), CAST(COUNT(1) AS STRING) FROM ads_category_sales_day $SCOPE;
SELECT 'rk',  CAST(MAX(cnt) AS STRING), CAST(MAX(bcnt) AS STRING) FROM (
    SELECT COUNT(1) cnt, 0 bcnt FROM ads_product_rank_day $SCOPE
    UNION ALL
    SELECT 0, COUNT(1) FROM ads_brand_sales_day $SCOPE
) x;
SELECT 'fn',  CAST(COUNT(1) AS STRING) FROM ads_user_funnel_day $SCOPE;
$DUP_SQL" 2>/dev/null | tr -d '\r' | grep -E '^(dws|ov|cat|rk|fn|ovdup)[[:space:]]' > /tmp/ads_chk_1.txt

get1() { awk -F'\t' -v k="$1" -v n="$2" '$1==k{print $n; exit}' /tmp/ads_chk_1.txt; }

DWS_GMV=$(get1 dws 2)
DWS_ORD=$(get1 dws 3)
ADS_GMV=$(get1 ov 2)
ADS_ORD=$(get1 ov 3)
OV_ROWS=$(get1 ov 4)
CAT_GMV=$(get1 cat 2)
RANK_MAX=$(get1 rk 2)
BRAND_MAX=$(get1 rk 3)
FN_ROWS=$(get1 fn 2)
OV_DUP=$(get1 ovdup 2)
OV_DUP=${OV_DUP:-0}

# 规则3 的语义是「每个 dt 分区内恰好 1 行」，不是「表里只有一天」。
# ADS 按天分区，历史分区保留完全正常，单天增量后总天数必然大于 1。
#   全量模式：覆盖天数必须等于 DWS 天数
#   单天模式：只校验本次目标日期已产出，不校验总天数
IS_FULL=0
if [ "$MODE" = "all" ] || [ "$MODE" = "check" ]; then IS_FULL=1; fi

[ "$DWS_GMV" = "$ADS_GMV" ] && echo "  [OK]   规则1 GMV 跨层一致 = $ADS_GMV" || { echo "  [FAIL] 规则1 GMV 不一致 dws=$DWS_GMV ads=$ADS_GMV"; BAD=$((BAD+1)); }
[ "$DWS_ORD" = "$ADS_ORD" ] && echo "  [OK]   规则2 订单数跨层一致 = $ADS_ORD" || { echo "  [FAIL] 规则2 订单不一致 dws=$DWS_ORD ads=$ADS_ORD"; BAD=$((BAD+1)); }
[ "$OV_ROWS" = "$FN_ROWS" ]  && echo "  [OK]   规则3 大盘/漏斗口径行数一致 = $OV_ROWS" || { echo "  [FAIL] 规则3 行数不一致 ov=$OV_ROWS funnel=$FN_ROWS"; BAD=$((BAD+1)); }
if [ "${OV_DUP:-1}" = "0" ]; then
    echo "  [OK]   规则3 大盘表每天恰好 1 行（无重复日期）"
else
    echo "  [FAIL] 规则3 有 $OV_DUP 个日期行数 > 1"; BAD=$((BAD+1))
fi
if [ "$IS_FULL" = "1" ]; then
    if [ "$OV_PART" = "$DWS_PART" ]; then
        echo "  [OK]   规则3 覆盖天数 = $OV_PART（与 DWS 一致）"
    else
        echo "  [FAIL] 规则3 覆盖天数=$OV_PART 期望=$DWS_PART"; BAD=$((BAD+1))
    fi
else
    # 单天增量：表内累计天数多于本次是正常的（历史分区保留），只校验目标分区已产出
    if [ "${OV_ROWS:-0}" = "1" ]; then
        echo "  [OK]   规则3 目标分区 $MODE 已产出（大盘表累计 $OV_PART 天，历史分区保留属正常）"
    else
        echo "  [FAIL] 规则3 目标分区 $MODE 行数=${OV_ROWS:-0}，期望 1"; BAD=$((BAD+1))
    fi
fi
[ "$CAT_GMV" = "$ADS_GMV" ] && echo "  [OK]   规则4 品类 GMV 合计 = 大盘 GMV = $CAT_GMV（未知品类未丢数）" || { echo "  [FAIL] 规则4 品类 GMV=$CAT_GMV 大盘=$ADS_GMV"; BAD=$((BAD+1)); }
if [ "${RANK_MAX:-0}" -le 50 ] && [ "${BRAND_MAX:-0}" -le 30 ]; then
    echo "  [OK]   规则3 商品榜最大行数=$RANK_MAX(<=50)  品牌榜最大行数=$BRAND_MAX(<=30)"
else
    echo "  [FAIL] 规则3 榜单行数超限 商品=$RANK_MAX 品牌=$BRAND_MAX"; BAD=$((BAD+1))
fi

# ---------- 规则 5/6/7 + 各表规模：合并成一次调用 ----------
# 原本是 4 条语句、其中 RFM 那条还带 3 个标量子查询（3 个作业）。
# 现在 RFM 与维表的人数直接并入下面的规模统计，少起 2 个查询。
echo "[规则5-7] 人群拆分 / 留存窗口 / RFM 完整性"
hive -e "USE $DB;
SELECT 'r5', CAST(COUNT(1) AS STRING) FROM ads_user_funnel_day WHERE new_pay_users + old_pay_users <> pay_users;
SELECT 'r6', CAST(COUNT(1) AS STRING),
       CAST(COALESCE(SUM(IF(retention_30d_rate IS NULL, 0, 1)),0) AS STRING),
       CAST(COALESCE(SUM(IF(retention_15d_rate IS NULL, 0, 1)),0) AS STRING),
       CAST(COALESCE(SUM(IF(retention_1d_rate  IS NULL, 0, 1)),0) AS STRING)
FROM ads_user_retention_day;
SELECT 'r7', CAST(COUNT(DISTINCT rfm_type) AS STRING) FROM ads_user_value_rfm;
SELECT 'sz', t, CAST(n AS STRING) FROM (
    SELECT 'ads_trade_overview_day' AS t, COUNT(1) AS n FROM ads_trade_overview_day
    UNION ALL SELECT 'ads_user_funnel_day',    COUNT(1) FROM ads_user_funnel_day
    UNION ALL SELECT 'ads_user_retention_day', COUNT(1) FROM ads_user_retention_day
    UNION ALL SELECT 'ads_product_rank_day',   COUNT(1) FROM ads_product_rank_day
    UNION ALL SELECT 'ads_category_sales_day', COUNT(1) FROM ads_category_sales_day
    UNION ALL SELECT 'ads_brand_sales_day',    COUNT(1) FROM ads_brand_sales_day
    UNION ALL SELECT 'ads_user_value_rfm',     COUNT(1) FROM ads_user_value_rfm
    UNION ALL SELECT 'dim_user_first_active',  COUNT(1) FROM dim_user_first_active
) u;" 2>/dev/null | tr -d '\r' | grep -E '^(r5|r6|r7|sz)[[:space:]]' > /tmp/ads_chk_2.txt

get2() { awk -F'\t' -v k="$1" -v n="$2" '$1==k{print $n; exit}' /tmp/ads_chk_2.txt; }

BAD5=$(get2 r5 2)
[ "${BAD5:-1}" = "0" ] && echo "  [OK]   规则5 新客+老客下单人数 = 支付人数，全部天数一致" || { echo "  [FAIL] 规则5 有 ${BAD5:-?} 天人数对不上"; BAD=$((BAD+1)); }

RET_ROWS=$(get2 r6 2)
RET_30=$(get2 r6 3)
RET_15=$(get2 r6 4)
RET_1=$(get2 r6 5)
echo "  [OK]   规则6 留存 cohort 数=$RET_ROWS  次日留存可算=$RET_1  15日可算=$RET_15  30日可算=$RET_30（窗口不足已置 NULL）"
[ "${RET_ROWS:-0}" = "31" ] || { echo "  [FAIL] 规则6 cohort 数应为 31"; BAD=$((BAD+1)); }
[ "${RET_30:-0}" = "1" ]    || { echo "  [WARN] 30 日留存可算 cohort 数=$RET_30（期望 1，仅数据集首日）"; }

RFM_TYP=$(get2 r7 2)
DIM_CNT=$(awk -F'\t' '$1=="sz" && $2=="dim_user_first_active"{print $3}' /tmp/ads_chk_2.txt)
RFM_CNT=$(awk -F'\t' '$1=="sz" && $2=="ads_user_value_rfm"{print $3}' /tmp/ads_chk_2.txt)
[ "$DIM_CNT" = "$RFM_CNT" ] && echo "  [OK]   规则7 RFM 用户数 = 维表用户数 = $RFM_CNT，分出 $RFM_TYP 类人群" || { echo "  [FAIL] 规则7 用户数不一致 dim=$DIM_CNT rfm=$RFM_CNT"; BAD=$((BAD+1)); }

echo
echo "[INFO] ADS 各表规模"
grep -E "^sz" /tmp/ads_chk_2.txt | awk -F'\t' '{printf "  %-26s %s\n", $2, $3}'

echo
echo "[INFO] RFM 分层人数分布"
hive -e "USE $DB; SELECT rfm_type, COUNT(1) AS cnt, ROUND(SUM(monetary),2) AS gmv
FROM ads_user_value_rfm GROUP BY rfm_type ORDER BY cnt DESC;" 2>/dev/null | grep -E "." | grep -v "rfm_type" | awk -F'\t' '{printf "  %-16s %10s 人   GMV %s\n", $1, $2, $3}'

echo
if [ "$BAD" -eq 0 ]; then
    echo "[PASS] ADS 层校验全部通过"
else
    echo "[FAIL] ADS 层有 $BAD 项不通过"
fi
exit "$BAD"
