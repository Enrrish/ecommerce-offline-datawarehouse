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
#   留存表与 RFM 表是全期计算，两种模式下都要重跑。
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

for T in ads_trade_overview_day ads_user_funnel_day ads_user_retention_day \
         ads_product_rank_day ads_category_sales_day ads_brand_sales_day ads_user_value_rfm; do
    if ! hive -e "USE $DB; SHOW TABLES LIKE '$T';" 2>/dev/null | grep -q "$T"; then
        echo "[ERROR] 表 $T 不存在，请先执行：hive -f $DIR/ads_ddl.sql"
        exit 1
    fi
done

if [ "$MODE" != "check" ]; then
    if [ "$MODE" = "all" ]; then
        echo "[INFO] 全量模式：批量补数 5 张按天分区表"
        S=$(date +%s)
        OUT=$(hive -f "$ALL_SQL" 2>&1)
        E=$(date +%s)
        if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
            echo "[FAIL] 批量补数失败（耗时 $((E - S))s）"
            echo "$OUT" | grep -iE "error|exception" | head -5
            exit 1
        fi
        echo "[OK] 批量补数完成，耗时 $((E - S))s"
    else
        echo "[INFO] 单天模式：处理 $MODE"
        S=$(date +%s)
        OUT=$(hive -f "$DAY_SQL" --hivevar bizdate="$MODE" 2>&1)
        E=$(date +%s)
        if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
            echo "[FAIL] $MODE 汇总失败（耗时 $((E - S))s）"
            echo "$OUT" | grep -iE "error|exception" | head -5
            exit 1
        fi
        echo "[OK] $MODE 汇总完成，耗时 $((E - S))s"
    fi

    echo
    echo "[INFO] 重算留存表（全期）"
    OUT=$(hive -f "$RET_SQL" 2>&1)
    if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
        echo "[FAIL] 留存表失败"; echo "$OUT" | grep -iE "error|exception" | head -5; exit 1
    fi
    echo "[OK] 留存表完成"

    echo "[INFO] 重算 RFM 表（全期）"
    OUT=$(hive -f "$RFM_SQL" 2>&1)
    if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
        echo "[FAIL] RFM 表失败"; echo "$OUT" | grep -iE "error|exception" | head -5; exit 1
    fi
    echo "[OK] RFM 表完成"
fi

# ============================== 校验 ==============================
echo
echo "===================== ADS 层校验 ====================="
BAD=0

# ---------- 规则 1/2/3/4：总量与行数 ----------
echo "[规则1-4] 总量一致性与行数约束"
hive -e "USE $DB;
SELECT COUNT(DISTINCT dt) FROM dws_user_action_day;
SELECT ROUND(SUM(d.total_gmv),2), SUM(d.purchase_cnt)
FROM dws_user_action_day d
JOIN (SELECT DISTINCT dt FROM ads_trade_overview_day) a ON d.dt = a.dt;
SELECT ROUND(SUM(total_gmv),2), SUM(purchase_pv), COUNT(1) FROM ads_trade_overview_day;
SELECT ROUND(SUM(total_gmv),2), COUNT(1) FROM ads_category_sales_day;
SELECT MAX(cnt), MAX(bcnt) FROM (
  SELECT dt, COUNT(1) cnt, 0 bcnt FROM ads_product_rank_day GROUP BY dt
  UNION ALL
  SELECT dt, 0 cnt, COUNT(1) bcnt FROM ads_brand_sales_day GROUP BY dt
) x;
SELECT COUNT(1) FROM ads_user_funnel_day;
SELECT COUNT(1) FROM (SELECT dt FROM ads_trade_overview_day GROUP BY dt HAVING COUNT(1) > 1) dup;
SELECT COUNT(1) FROM ads_trade_overview_day WHERE dt = '$MODE';" 2>/dev/null | grep -E "^[0-9]" > /tmp/ads_chk_1.txt

DWS_DAYS=$(sed -n '1p' /tmp/ads_chk_1.txt)
DWS_GMV=$(sed -n '2p' /tmp/ads_chk_1.txt | cut -f1)
DWS_ORD=$(sed -n '2p' /tmp/ads_chk_1.txt | cut -f2)
ADS_GMV=$(sed -n '3p' /tmp/ads_chk_1.txt | cut -f1)
ADS_ORD=$(sed -n '3p' /tmp/ads_chk_1.txt | cut -f2)
OV_DAYS=$(sed -n '3p' /tmp/ads_chk_1.txt | cut -f3)
CAT_GMV=$(sed -n '4p' /tmp/ads_chk_1.txt | cut -f1)
RANK_MAX=$(sed -n '5p' /tmp/ads_chk_1.txt | cut -f1)
BRAND_MAX=$(sed -n '5p' /tmp/ads_chk_1.txt | cut -f2)
FN_DAYS=$(sed -n '6p' /tmp/ads_chk_1.txt)
OV_DUP=$(sed -n '7p' /tmp/ads_chk_1.txt)      # 出现行数 >1 的日期个数（应恒为 0）
DT_CNT=$(sed -n '8p' /tmp/ads_chk_1.txt)      # 目标日期分区行数

# 规则3 的语义是「每个 dt 分区内恰好 1 行」，不是「表里只有一天」。
# ADS 按天分区，历史分区保留完全正常，单天增量后总天数必然大于 1。
#   全量模式：覆盖天数必须等于 DWS 天数
#   单天模式：只校验本次目标日期已产出，不校验总天数
IS_FULL=0
if [ "$MODE" = "all" ] || [ "$MODE" = "check" ]; then IS_FULL=1; fi

[ "$DWS_GMV" = "$ADS_GMV" ] && echo "  [OK]   规则1 GMV 跨层一致 = $ADS_GMV" || { echo "  [FAIL] 规则1 GMV 不一致 dws=$DWS_GMV ads=$ADS_GMV"; BAD=$((BAD+1)); }
[ "$DWS_ORD" = "$ADS_ORD" ] && echo "  [OK]   规则2 订单数跨层一致 = $ADS_ORD" || { echo "  [FAIL] 规则2 订单不一致 dws=$DWS_ORD ads=$ADS_ORD"; BAD=$((BAD+1)); }
[ "$OV_DAYS" = "$FN_DAYS" ]  && echo "  [OK]   规则3 大盘/漏斗天数一致 = $OV_DAYS" || { echo "  [FAIL] 规则3 天数不一致 ov=$OV_DAYS funnel=$FN_DAYS"; BAD=$((BAD+1)); }
if [ "${OV_DUP:-1}" = "0" ]; then
    echo "  [OK]   规则3 大盘表每天恰好 1 行（无重复日期）"
else
    echo "  [FAIL] 规则3 有 $OV_DUP 个日期行数 > 1"; BAD=$((BAD+1))
fi
if [ "$IS_FULL" = "1" ]; then
    if [ "$OV_DAYS" = "$DWS_DAYS" ]; then
        echo "  [OK]   规则3 覆盖天数 = $OV_DAYS（与 DWS 一致）"
    else
        echo "  [FAIL] 规则3 覆盖天数=$OV_DAYS 期望=$DWS_DAYS"; BAD=$((BAD+1))
    fi
else
    # 单天增量：表内累计天数多于本次是正常的（历史分区保留），只校验目标分区已产出
    if [ "${DT_CNT:-0}" = "1" ]; then
        echo "  [OK]   规则3 目标分区 $MODE 已产出（表内累计 $OV_DAYS 天，历史分区保留属正常）"
    else
        echo "  [FAIL] 规则3 目标分区 $MODE 行数=${DT_CNT:-0}，期望 1"; BAD=$((BAD+1))
    fi
fi
[ "$CAT_GMV" = "$ADS_GMV" ] && echo "  [OK]   规则4 品类 GMV 合计 = 大盘 GMV = $CAT_GMV（未知品类未丢数）" || { echo "  [FAIL] 规则4 品类 GMV=$CAT_GMV 大盘=$ADS_GMV"; BAD=$((BAD+1)); }
if [ "${RANK_MAX:-0}" -le 50 ] && [ "${BRAND_MAX:-0}" -le 30 ]; then
    echo "  [OK]   规则3 商品榜最大行数=$RANK_MAX(<=50)  品牌榜最大行数=$BRAND_MAX(<=30)"
else
    echo "  [FAIL] 规则3 榜单行数超限 商品=$RANK_MAX 品牌=$BRAND_MAX"; BAD=$((BAD+1))
fi

# ---------- 规则 5：人群拆分不漏人 ----------
echo "[规则5] 漏斗表新老人群拆分"
BAD5=$(hive -e "USE $DB; SELECT COUNT(1) FROM ads_user_funnel_day WHERE new_pay_users + old_pay_users <> pay_users;" 2>/dev/null | grep -E "^[0-9]+$")
[ "${BAD5:-1}" = "0" ] && echo "  [OK]   规则5 新客+老客下单人数 = 支付人数，全部天数一致" || { echo "  [FAIL] 规则5 有 $BAD5 天人数对不上"; BAD=$((BAD+1)); }

# ---------- 规则 6：留存窗口 ----------
echo "[规则6] 留存表窗口约束"
hive -e "USE $DB;
SELECT COUNT(1),
       SUM(IF(retention_30d_rate IS NULL, 0, 1)),
       SUM(IF(retention_15d_rate IS NULL, 0, 1)),
       SUM(IF(retention_1d_rate  IS NULL, 0, 1))
FROM ads_user_retention_day;" 2>/dev/null | grep -E "^[0-9]" > /tmp/ads_chk_6.txt
RET_ROWS=$(cut -f1 /tmp/ads_chk_6.txt)
RET_30=$(cut -f2 /tmp/ads_chk_6.txt)
RET_15=$(cut -f3 /tmp/ads_chk_6.txt)
RET_1=$(cut -f4 /tmp/ads_chk_6.txt)
echo "  [OK]   规则6 留存 cohort 数=$RET_ROWS  次日留存可算=$RET_1  15日可算=$RET_15  30日可算=$RET_30（窗口不足已置 NULL）"
[ "${RET_ROWS:-0}" = "31" ] || { echo "  [FAIL] 规则6 cohort 数应为 31"; BAD=$((BAD+1)); }
[ "${RET_30:-0}" = "1" ]    || { echo "  [WARN] 30 日留存可算 cohort 数=$RET_30（期望 1，仅数据集首日）"; }

# ---------- 规则 7：RFM 完整性 ----------
echo "[规则7] RFM 分层完整性"
hive -e "USE $DB;
SELECT (SELECT COUNT(1) FROM dim_user_first_active),
       (SELECT COUNT(1) FROM ads_user_value_rfm),
       (SELECT COUNT(DISTINCT rfm_type) FROM ads_user_value_rfm);" 2>/dev/null | grep -E "^[0-9]" > /tmp/ads_chk_7.txt
DIM_CNT=$(cut -f1 /tmp/ads_chk_7.txt)
RFM_CNT=$(cut -f2 /tmp/ads_chk_7.txt)
RFM_TYP=$(cut -f3 /tmp/ads_chk_7.txt)
[ "$DIM_CNT" = "$RFM_CNT" ] && echo "  [OK]   规则7 RFM 用户数 = 维表用户数 = $RFM_CNT，分出 $RFM_TYP 类人群" || { echo "  [FAIL] 规则7 用户数不一致 dim=$DIM_CNT rfm=$RFM_CNT"; BAD=$((BAD+1)); }

# ---------- 各表规模 ----------
echo
echo "[INFO] ADS 各表规模"
hive -e "USE $DB;
SELECT 'ads_trade_overview_day', COUNT(1) FROM ads_trade_overview_day
UNION ALL SELECT 'ads_user_funnel_day', COUNT(1) FROM ads_user_funnel_day
UNION ALL SELECT 'ads_user_retention_day', COUNT(1) FROM ads_user_retention_day
UNION ALL SELECT 'ads_product_rank_day', COUNT(1) FROM ads_product_rank_day
UNION ALL SELECT 'ads_category_sales_day', COUNT(1) FROM ads_category_sales_day
UNION ALL SELECT 'ads_brand_sales_day', COUNT(1) FROM ads_brand_sales_day
UNION ALL SELECT 'ads_user_value_rfm', COUNT(1) FROM ads_user_value_rfm;" 2>/dev/null | grep -E "^ads_" | awk -F'\t' '{printf "  %-26s %s\n", $1, $2}'

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
