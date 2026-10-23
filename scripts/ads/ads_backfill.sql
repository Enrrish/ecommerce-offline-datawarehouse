-- ==============================================================================
-- ads_backfill.sql —— ADS 历史批量补数（一次跑完 31 天）
-- 执行：hive -f ads_backfill.sql
--
-- 为什么日常增量和历史补数要两套 SQL（DWS 阶段踩过的坑）：
--   按天循环调 ads_etl_day.sql，31 天要启 31×5 个 MR，实测单天 140 秒左右；
--   批量版一次 GROUP BY dt + 动态分区写入，5 张表大约 10 分钟内全部完成。
--   二者 SQL 结构完全对齐，指标口径一致，只是把 WHERE dt = 常量 换成 GROUP BY dt、
--   把 ROW_NUMBER() OVER () 换成 OVER (PARTITION BY dt ...)。
--   上线时：日常 T+1 跑 etl_day，首次建仓或重跑历史跑 backfill。
-- ==============================================================================

USE mydb;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
SET hive.exec.parallel=false;
SET hive.auto.convert.join=false;
-- 单个 mapper/reducer 最多允许产生的动态分区数，31 天远低于阈值，防的是误写爆分区
SET hive.exec.max.dynamic.partitions=1000;
SET hive.exec.max.dynamic.partitions.pernode=1000;

-- ------------------------------------------------------------------------------
-- 1. 大盘日报（31 天）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_trade_overview_day PARTITION (dt)
SELECT
    active_users,
    new_users,
    active_users - new_users                                                        AS old_users,
    CASE WHEN active_users > 0 THEN ROUND(new_users / active_users, 4) END          AS new_user_ratio,
    view_pv,
    cart_pv,
    purchase_pv,
    pay_users,
    CASE WHEN active_users > 0 THEN ROUND(pay_users / active_users, 4) END          AS pay_user_ratio,
    total_gmv,
    CASE WHEN purchase_pv  > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_pv,  2) END AS avg_order_value,
    CASE WHEN active_users > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / active_users, 2) END AS arpu,
    dt
FROM (
    SELECT
        dt,
        COUNT(1)                                          AS active_users,
        SUM(CASE WHEN is_new_user = 1 THEN 1 ELSE 0 END)  AS new_users,
        SUM(view_cnt)                                     AS view_pv,
        SUM(cart_cnt)                                     AS cart_pv,
        SUM(purchase_cnt)                                 AS purchase_pv,
        SUM(CASE WHEN purchase_cnt > 0 THEN 1 ELSE 0 END) AS pay_users,
        SUM(total_gmv)                                    AS total_gmv
    FROM dws_user_action_day
    GROUP BY dt
) t;

-- ------------------------------------------------------------------------------
-- 2. 漏斗与人群结构（31 天）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_user_funnel_day PARTITION (dt)
SELECT
    f.active_users,
    f.view_users,
    f.cart_users,
    f.pay_users,
    f.strict_funnel_users,
    f.view_to_cart_rate,
    f.cart_to_pay_rate,
    f.view_to_pay_rate,
    u.new_pay_users,
    u.old_pay_users,
    u.new_user_gmv,
    u.old_user_gmv,
    CASE WHEN (CAST(u.new_user_gmv AS DOUBLE) + CAST(u.old_user_gmv AS DOUBLE)) > 0
         THEN ROUND(CAST(u.new_user_gmv AS DOUBLE)
                  / (CAST(u.new_user_gmv AS DOUBLE) + CAST(u.old_user_gmv AS DOUBLE)), 4) END AS new_gmv_ratio,
    f.dt
FROM (
    SELECT dt, active_users, view_users, cart_users, pay_users, strict_funnel_users,
           view_to_cart_rate, cart_to_pay_rate, view_to_pay_rate
    FROM dws_user_funnel_day
) f
JOIN (
    SELECT
        dt,
        SUM(CASE WHEN is_new_user = 1 AND purchase_cnt > 0 THEN 1 ELSE 0 END) AS new_pay_users,
        SUM(CASE WHEN is_new_user = 0 AND purchase_cnt > 0 THEN 1 ELSE 0 END) AS old_pay_users,
        SUM(CASE WHEN is_new_user = 1 THEN total_gmv ELSE CAST(0 AS DECIMAL(14,2)) END) AS new_user_gmv,
        SUM(CASE WHEN is_new_user = 0 THEN total_gmv ELSE CAST(0 AS DECIMAL(14,2)) END) AS old_user_gmv
    FROM dws_user_action_day
    GROUP BY dt
) u ON f.dt = u.dt;

-- ------------------------------------------------------------------------------
-- 3. 商品热销榜 TOP 50（31 天）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_product_rank_day PARTITION (dt)
SELECT
    rank_no,
    product_id,
    category_code,
    brand,
    view_cnt,
    cart_cnt,
    purchase_cnt,
    total_gmv,
    CASE WHEN day_gmv > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / CAST(day_gmv AS DOUBLE), 6) END AS gmv_share,
    CASE WHEN view_cnt > 0 THEN ROUND(purchase_cnt / view_cnt, 4) END                            AS view_to_pay_rate,
    dt
FROM (
    SELECT
        ROW_NUMBER() OVER (PARTITION BY dt ORDER BY total_gmv DESC, product_id ASC) AS rank_no,
        dt, product_id, category_code, brand,
        view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER (PARTITION BY dt) AS day_gmv
    FROM (
        SELECT
            dt,
            product_id,
            COALESCE(category_code, '未知品类') AS category_code,
            COALESCE(brand,         '未知品牌') AS brand,
            view_cnt, cart_cnt, purchase_cnt, total_gmv
        FROM dws_product_action_day
    ) b
) r
WHERE rank_no <= 50;

-- ------------------------------------------------------------------------------
-- 4. 品类销售分析（31 天）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_category_sales_day PARTITION (dt)
SELECT
    cat_level1,
    category_code,
    sku_cnt,
    view_cnt,
    cart_cnt,
    purchase_cnt,
    total_gmv,
    CASE WHEN day_gmv > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / CAST(day_gmv AS DOUBLE), 6) END AS gmv_share,
    gmv_rank,
    CASE WHEN purchase_cnt > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_cnt, 2) END        AS avg_order_value,
    dt
FROM (
    SELECT
        SPLIT(category_code, '\\.')[0] AS cat_level1,
        dt,
        category_code,
        sku_cnt, view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER (PARTITION BY dt) AS day_gmv,
        ROW_NUMBER() OVER (PARTITION BY dt ORDER BY total_gmv DESC, category_code ASC) AS gmv_rank
    FROM (
        SELECT
            dt,
            COALESCE(category_code, '未知品类') AS category_code,
            COUNT(DISTINCT product_id)          AS sku_cnt,
            SUM(view_cnt)                       AS view_cnt,
            SUM(cart_cnt)                       AS cart_cnt,
            SUM(purchase_cnt)                   AS purchase_cnt,
            SUM(total_gmv)                      AS total_gmv
        FROM dws_product_action_day
        GROUP BY dt, COALESCE(category_code, '未知品类')
    ) g
) r;

-- ------------------------------------------------------------------------------
-- 5. 品牌销售榜 TOP 30（31 天）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_brand_sales_day PARTITION (dt)
SELECT
    brand,
    sku_cnt,
    view_cnt,
    cart_cnt,
    purchase_cnt,
    total_gmv,
    CASE WHEN day_gmv > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / CAST(day_gmv AS DOUBLE), 6) END AS gmv_share,
    gmv_rank,
    CASE WHEN purchase_cnt > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_cnt, 2) END        AS avg_order_value,
    dt
FROM (
    SELECT
        dt, brand, sku_cnt, view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER (PARTITION BY dt) AS day_gmv,
        ROW_NUMBER() OVER (PARTITION BY dt ORDER BY total_gmv DESC, brand ASC) AS gmv_rank
    FROM (
        SELECT
            dt,
            COALESCE(brand, '未知品牌') AS brand,
            COUNT(DISTINCT product_id)  AS sku_cnt,
            SUM(view_cnt)               AS view_cnt,
            SUM(cart_cnt)               AS cart_cnt,
            SUM(purchase_cnt)           AS purchase_cnt,
            SUM(total_gmv)              AS total_gmv
        FROM dws_product_action_day
        GROUP BY dt, COALESCE(brand, '未知品牌')
    ) g
) r
WHERE gmv_rank <= 30;

SELECT 'backfill_done' AS flag;
