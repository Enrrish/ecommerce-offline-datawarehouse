#!/bin/bash
# ==============================================================================
# ads_export.sh —— 把 ADS 结果导成看板可直接加载的数据文件
#
# 用法：
#   bash ads_export.sh                    # 默认导出到 /home/cy/dashboard/data
#   OUT=/tmp/d bash ads_export.sh         # 指定输出目录
#   DB=mydb bash ads_export.sh
#
# 为什么导静态文件而不是让看板直连 Hive：
#   1) 看板每刷新一次就要查 5~7 次；Hive CLI 每次冷启动 ≈6 s，10 个图要 60 s；
#   2) 离线数仓本来就是 T+1，一天只产一次数，前端读静态文件与业务节奏一致；
#   3) ADS 全量才 14.6 MB（RFM 单表 13.8 MB / 302 万行），
#      而看板只需要聚合结果，导出来不到 1 MB，前端一次加载即可。
#
# 产出（每个数据集两个文件，.js 是为了让看板用 file:// 直接打开也能跑，
#       因为浏览器在 file:// 下会拦 fetch 本地 json）：
#   overview   大盘日报          ads_trade_overview_day
#   funnel     漏斗与人群结构    ads_user_funnel_day
#   retention  留存 cohort       ads_user_retention_day
#   products   商品 TOP50        ads_product_rank_day
#   categories 品类销售          ads_category_sales_day
#   brands     品牌 TOP30        ads_brand_sales_day
#   rfm        用户价值分层      ads_user_value_rfm（只导 9 类聚合，不搬 302 万行明细）
#   meta       生成时间/日期范围/行数
#
# 注意：Hive 3.1.2 没有 to_json()（那是 Hive 4 的 UDF），所以这里用 concat 手工拼 JSON。
#       字段值只有数字和安全字符串（日期、品类码、品牌、RFM 类型），
#       品牌/品类里的双引号统一用 regexp_replace 去掉，避免破坏 JSON 结构。
# ==============================================================================
set -uo pipefail

DB="${DB:-mydb}"
OUT="${OUT:-/home/cy/dashboard/data}"
ERR="/tmp/ads_export_stderr.log"
mkdir -p "$OUT"

TMPD=$(mktemp -d /tmp/ads_export_XXXX)
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------- 通用执行函数
# $1 = 数据集名（输出文件名）  $2 = 大写变量名  $3 = SQL 文件
run_set() {
    local name="$1" var="$2" sqlf="$3"
    local json="$OUT/$name.json"

    if ! hive -S -f "$sqlf" 2>"$ERR" | tr -d '\r' > "$json.tmp"; then
        echo "  [FAIL] $name：hive 执行失败"
        grep -aiE "error|exception|FAILED" "$ERR" | head -3 | sed 's/^/         /'
        rm -f "$json.tmp"
        return 1
    fi

    # 用 python 真正解析一次：既校验合法性，又拿到行数
    # （不这样写就会踩坑：某行为 NULL 时 concat 返回 NULL，被 collect_list 静默丢掉）
    local rows
    if ! rows=$(python -c "import json;print(len(json.load(open('$json.tmp'))))" 2>/dev/null); then
        echo "  [FAIL] $name：输出不是合法 JSON"
        grep -aiE "error|exception|FAILED" "$ERR" | head -3 | sed 's/^/         /'
        rm -f "$json.tmp"
        return 1
    fi

    mv "$json.tmp" "$json"
    { printf 'window.DATA_%s = ' "$var"; cat "$json"; printf ';\n'; } > "$OUT/$name.js"

    local bytes
    bytes=$(wc -c < "$json")
    printf "  [OK]   %-11s %6d 条  %7.1f KB\n" "$name" "$rows" "$(echo "$bytes" | awk '{print $1/1024}')"
}

echo "[INFO] 导出 ADS → $OUT（库 $DB）"
S=$(date +%s)

# ------------------------------------------------------------------- 1 大盘日报
# 看板用：GMV/订单趋势、活跃与新客、客单价与 ARPU
cat > "$TMPD/overview.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', sort_array(collect_list(j))), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","active_users":',   CAST(active_users AS STRING),
        ',"new_users":',       CAST(new_users AS STRING),
        ',"old_users":',       CAST(old_users AS STRING),
        ',"new_user_ratio":',  COALESCE(CAST(new_user_ratio AS STRING), 'null'),
        ',"view_pv":',         CAST(view_pv AS STRING),
        ',"cart_pv":',         CAST(cart_pv AS STRING),
        ',"purchase_pv":',     CAST(purchase_pv AS STRING),
        ',"pay_users":',       CAST(pay_users AS STRING),
        ',"pay_user_ratio":',  COALESCE(CAST(pay_user_ratio AS STRING), 'null'),
        ',"total_gmv":',       CAST(total_gmv AS STRING),
        ',"avg_order_value":', COALESCE(CAST(avg_order_value AS STRING), 'null'),
        ',"arpu":',            COALESCE(CAST(arpu AS STRING), 'null'),
        '}') AS j
    FROM ads_trade_overview_day
) t;
SQL
run_set overview OVERVIEW "$TMPD/overview.sql" || exit 1

# ------------------------------------------------------------- 2 漏斗与人群结构
# 看板用：四级行为漏斗、严格漏斗、转化率趋势、新老客 GMV 拆分
cat > "$TMPD/funnel.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', sort_array(collect_list(j))), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","active_users":',        CAST(active_users AS STRING),
        ',"view_users":',           CAST(view_users AS STRING),
        ',"cart_users":',           CAST(cart_users AS STRING),
        ',"pay_users":',            CAST(pay_users AS STRING),
        ',"strict_funnel_users":',  CAST(strict_funnel_users AS STRING),
        ',"view_to_cart_rate":',    COALESCE(CAST(view_to_cart_rate AS STRING), 'null'),
        ',"cart_to_pay_rate":',     COALESCE(CAST(cart_to_pay_rate AS STRING), 'null'),
        ',"view_to_pay_rate":',     COALESCE(CAST(view_to_pay_rate AS STRING), 'null'),
        ',"new_pay_users":',        CAST(new_pay_users AS STRING),
        ',"old_pay_users":',        CAST(old_pay_users AS STRING),
        ',"new_user_gmv":',         COALESCE(CAST(new_user_gmv AS STRING), 'null'),
        ',"old_user_gmv":',         COALESCE(CAST(old_user_gmv AS STRING), 'null'),
        ',"new_gmv_ratio":',        COALESCE(CAST(new_gmv_ratio AS STRING), 'null'),
        '}') AS j
    FROM ads_user_funnel_day
) t;
SQL
run_set funnel FUNNEL "$TMPD/funnel.sql" || exit 1

# --------------------------------------------------------------- 3 留存 cohort
# 看板用：cohort 热力图。窗口不足的 15/30 日留存是 NULL，前端据此显示为空白而不是 0
cat > "$TMPD/retention.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', sort_array(collect_list(j))), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","new_users":',           CAST(new_users AS STRING),
        ',"retain_1d":',            COALESCE(CAST(retain_1d AS STRING), 'null'),
        ',"retain_3d":',            COALESCE(CAST(retain_3d AS STRING), 'null'),
        ',"retain_7d":',            COALESCE(CAST(retain_7d AS STRING), 'null'),
        ',"retain_15d":',           COALESCE(CAST(retain_15d AS STRING), 'null'),
        ',"retain_30d":',           COALESCE(CAST(retain_30d AS STRING), 'null'),
        ',"retention_1d_rate":',    COALESCE(CAST(retention_1d_rate AS STRING), 'null'),
        ',"retention_3d_rate":',    COALESCE(CAST(retention_3d_rate AS STRING), 'null'),
        ',"retention_7d_rate":',    COALESCE(CAST(retention_7d_rate AS STRING), 'null'),
        ',"retention_15d_rate":',   COALESCE(CAST(retention_15d_rate AS STRING), 'null'),
        ',"retention_30d_rate":',   COALESCE(CAST(retention_30d_rate AS STRING), 'null'),
        ',"is_data_start_cohort":', CAST(is_data_start_cohort AS STRING),
        '}') AS j
    FROM ads_user_retention_day
) t;
SQL
run_set retention RETENTION "$TMPD/retention.sql" || exit 1

# ------------------------------------------------------------------ 4 商品 TOP50
cat > "$TMPD/products.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', collect_list(j)), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","rank_no":',          CAST(rank_no AS STRING),
        ',"product_id":',        CAST(product_id AS STRING),
        ',"category_code":"',    replace(COALESCE(category_code, ''), chr(34), ''), '"',
        ',"brand":"',            replace(COALESCE(brand, ''), chr(34), ''), '"',
        ',"view_cnt":',          CAST(view_cnt AS STRING),
        ',"cart_cnt":',          CAST(cart_cnt AS STRING),
        ',"purchase_cnt":',      CAST(purchase_cnt AS STRING),
        ',"total_gmv":',         CAST(total_gmv AS STRING),
        ',"gmv_share":',         COALESCE(CAST(gmv_share AS STRING), 'null'),
        ',"view_to_pay_rate":',  COALESCE(CAST(view_to_pay_rate AS STRING), 'null'),
        '}') AS j
    FROM ads_product_rank_day
) t;
SQL
run_set products PRODUCTS "$TMPD/products.sql" || exit 1

# ---------------------------------------------------------------------- 5 品类
cat > "$TMPD/categories.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', collect_list(j)), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","cat_level1":"',      replace(COALESCE(cat_level1, ''), chr(34), ''), '"',
        ',"category_code":"',    replace(COALESCE(category_code, ''), chr(34), ''), '"',
        ',"sku_cnt":',           CAST(sku_cnt AS STRING),
        ',"view_cnt":',          CAST(view_cnt AS STRING),
        ',"purchase_cnt":',      CAST(purchase_cnt AS STRING),
        ',"total_gmv":',         CAST(total_gmv AS STRING),
        ',"gmv_share":',         COALESCE(CAST(gmv_share AS STRING), 'null'),
        ',"gmv_rank":',          CAST(gmv_rank AS STRING),
        ',"avg_order_value":',   COALESCE(CAST(avg_order_value AS STRING), 'null'),
        '}') AS j
    FROM ads_category_sales_day
) t;
SQL
run_set categories CATEGORIES "$TMPD/categories.sql" || exit 1

# ---------------------------------------------------------------------- 6 品牌
cat > "$TMPD/brands.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', collect_list(j)), ']') FROM (
    SELECT concat('{"dt":"', dt,
        '","brand":"',           replace(COALESCE(brand, ''), chr(34), ''), '"',
        ',"sku_cnt":',           CAST(sku_cnt AS STRING),
        ',"view_cnt":',          CAST(view_cnt AS STRING),
        ',"purchase_cnt":',      CAST(purchase_cnt AS STRING),
        ',"total_gmv":',         CAST(total_gmv AS STRING),
        ',"gmv_share":',         COALESCE(CAST(gmv_share AS STRING), 'null'),
        ',"gmv_rank":',          CAST(gmv_rank AS STRING),
        '}') AS j
    FROM ads_brand_sales_day
) t;
SQL
run_set brands BRANDS "$TMPD/brands.sql" || exit 1

# ------------------------------------------------------------ 7 用户价值 RFM
# 关键：只导 9 类聚合（几行），绝不把 302 万行明细搬到前端
cat > "$TMPD/rfm.sql" <<SQL
USE $DB;
SELECT concat('[', concat_ws(',', sort_array(collect_list(j))), ']') FROM (
    SELECT concat('{"rfm_type":"', rfm_type,
        '","cnt":',           CAST(COUNT(1) AS STRING),
        ',"gmv":',            CAST(ROUND(SUM(monetary), 2) AS STRING),
        ',"avg_recency":',    COALESCE(CAST(ROUND(AVG(CASE WHEN recency_days IS NULL THEN NULL ELSE recency_days END), 1) AS STRING), 'null'),
        ',"avg_frequency":',  CAST(ROUND(AVG(frequency), 2) AS STRING),
        ',"avg_monetary":',   CAST(ROUND(AVG(monetary), 2) AS STRING),
        '}') AS j
    FROM ads_user_value_rfm
    GROUP BY rfm_type
) t;
SQL
run_set rfm RFM "$TMPD/rfm.sql" || exit 1

# ------------------------------------------------------------------ 8 元信息
STAT_DATE=$(hive -S -e "USE $DB; SHOW PARTITIONS ads_trade_overview_day;" 2>/dev/null | tr -d '\r' | sed 's/^dt=//' | sort | tail -1)
MIN_DATE=$(hive -S -e "USE $DB; SHOW PARTITIONS ads_trade_overview_day;" 2>/dev/null | tr -d '\r' | sed 's/^dt=//' | sort | head -1)
DAYS=$(hive -S -e "USE $DB; SHOW PARTITIONS ads_trade_overview_day;" 2>/dev/null | tr -d '\r' | grep -c '^dt=')

{
    printf 'window.DATA_META = {"generated_at":"%s","start":"%s","end":"%s","days":%d,"db":"%s"};\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$MIN_DATE" "$STAT_DATE" "$DAYS" "$DB"
} > "$OUT/meta.js"
{
    printf '{"generated_at":"%s","start":"%s","end":"%s","days":%d,"db":"%s"}\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$MIN_DATE" "$STAT_DATE" "$DAYS" "$DB"
} > "$OUT/meta.json"
printf "  [OK]   %-11s 截止 %s，覆盖 %s 起 %d 天\n" "meta" "$STAT_DATE" "$MIN_DATE" "$DAYS"

E=$(date +%s)
echo "[PASS] 导出完成，耗时 $((E - S))s，输出目录 $OUT"
du -sh "$OUT" | awk '{print "       合计 " $1}'
exit 0
