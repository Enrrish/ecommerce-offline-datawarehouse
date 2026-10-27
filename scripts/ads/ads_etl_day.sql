-- ==============================================================================
-- ads_etl_day.sql —— ADS 日常增量（跑一天）
-- 执行：hive --hivevar bizdate=2019-10-01 -f ads_etl_day.sql
--
-- 覆盖 5 张按天分区的表；留存表与 RFM 表是全期计算，走 ads_retention.sql / ads_rfm.sql。
-- 所有 INSERT 都是 OVERWRITE + 静态分区，幂等：同一天重跑结果不变。
--
-- 【为什么没改多路插入】
--   三条商品类 INSERT 同源（dws_product_action_day），本想用
--   FROM (...) p INSERT ... INSERT ... 只扫一次，但 Hive 3.1 的语法不允许
--   INSERT 子句里再带 FROM（报 missing EOF at 'FROM'），子查询必须挪到共享的
--   FROM 里，而三个分支的粒度和窗口口径不同，硬合并只能靠 UNION + tag，
--   反而扫三遍。实测放弃，改走“中间表 + 单次扫描”（docs/07 步骤 4）。
-- ==============================================================================

USE mydb;

-- 并行执行在本集群有过 ConcurrentModificationException（docs/03 第 3 条），保持关闭
SET hive.exec.parallel=false;
SET hive.auto.convert.join=false;

-- ------------------------------------------------------------------------------
-- 1. 大盘日报
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_trade_overview_day PARTITION (dt = '${hivevar:bizdate}')
SELECT
    active_users,
    new_users,
    active_users - new_users                                                       AS old_users,
    CASE WHEN active_users  > 0 THEN ROUND(new_users        / active_users,  4) END AS new_user_ratio,
    view_pv,
    cart_pv,
    purchase_pv,
    pay_users,
    CASE WHEN active_users  > 0 THEN ROUND(pay_users        / active_users,  4) END AS pay_user_ratio,
    total_gmv,
    CASE WHEN purchase_pv   > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_pv,  2) END AS avg_order_value,
    CASE WHEN active_users  > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / active_users, 2) END AS arpu
FROM (
    SELECT
        COUNT(1)                                             AS active_users,
        SUM(CASE WHEN is_new_user = 1 THEN 1 ELSE 0 END)     AS new_users,
        SUM(view_cnt)                                        AS view_pv,
        SUM(cart_cnt)                                        AS cart_pv,
        SUM(purchase_cnt)                                    AS purchase_pv,
        SUM(CASE WHEN purchase_cnt > 0 THEN 1 ELSE 0 END)    AS pay_users,
        SUM(total_gmv)                                       AS total_gmv
    FROM dws_user_action_day
    WHERE dt = '${hivevar:bizdate}'
) t;

-- ------------------------------------------------------------------------------
-- 2. 漏斗与人群结构
-- 漏斗人数与转化率直接取 DWS，不重算；本表只补 DWS 没有的新老拆分。
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_user_funnel_day PARTITION (dt = '${hivevar:bizdate}')
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
                  / (CAST(u.new_user_gmv AS DOUBLE) + CAST(u.old_user_gmv AS DOUBLE)), 4) END AS new_gmv_ratio
FROM (
    SELECT active_users, view_users, cart_users, pay_users, strict_funnel_users,
           view_to_cart_rate, cart_to_pay_rate, view_to_pay_rate
    FROM dws_user_funnel_day
    WHERE dt = '${hivevar:bizdate}'
) f
CROSS JOIN (
    SELECT
        SUM(CASE WHEN is_new_user = 1 AND purchase_cnt > 0 THEN 1 ELSE 0 END) AS new_pay_users,
        SUM(CASE WHEN is_new_user = 0 AND purchase_cnt > 0 THEN 1 ELSE 0 END) AS old_pay_users,
        SUM(CASE WHEN is_new_user = 1 THEN total_gmv ELSE CAST(0 AS DECIMAL(14,2)) END) AS new_user_gmv,
        SUM(CASE WHEN is_new_user = 0 THEN total_gmv ELSE CAST(0 AS DECIMAL(14,2)) END) AS old_user_gmv
    FROM dws_user_action_day
    WHERE dt = '${hivevar:bizdate}'
) u;

-- ------------------------------------------------------------------------------
-- 3. 商品热销榜 TOP 50
-- 当日大盘 GMV 用窗口 SUM() OVER () 取，省掉一次自关联。
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_product_rank_day PARTITION (dt = '${hivevar:bizdate}')
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
    CASE WHEN view_cnt > 0 THEN ROUND(purchase_cnt / view_cnt, 4) END                            AS view_to_pay_rate
FROM (
    SELECT
        ROW_NUMBER() OVER (ORDER BY total_gmv DESC, product_id ASC) AS rank_no,
        product_id, category_code, brand,
        view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER () AS day_gmv
    FROM (
        SELECT
            product_id,
            COALESCE(category_code, '未知品类') AS category_code,
            COALESCE(brand,         '未知品牌') AS brand,
            view_cnt, cart_cnt, purchase_cnt, total_gmv
        FROM dws_product_action_day
        WHERE dt = '${hivevar:bizdate}'
    ) b
) r
WHERE rank_no <= 50;

-- ------------------------------------------------------------------------------
-- 4. 品类销售分析（全品类，不截断，127 行左右）
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_category_sales_day PARTITION (dt = '${hivevar:bizdate}')
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
    CASE WHEN purchase_cnt > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_cnt, 2) END        AS avg_order_value
FROM (
    SELECT
        SPLIT(category_code, '\\.')[0] AS cat_level1,
        category_code,
        sku_cnt, view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER () AS day_gmv,
        ROW_NUMBER() OVER (ORDER BY total_gmv DESC, category_code ASC) AS gmv_rank
    FROM (
        SELECT
            COALESCE(category_code, '未知品类') AS category_code,
            COUNT(DISTINCT product_id)          AS sku_cnt,
            SUM(view_cnt)                       AS view_cnt,
            SUM(cart_cnt)                       AS cart_cnt,
            SUM(purchase_cnt)                   AS purchase_cnt,
            SUM(total_gmv)                      AS total_gmv
        FROM dws_product_action_day
        WHERE dt = '${hivevar:bizdate}'
        GROUP BY COALESCE(category_code, '未知品类')
    ) g
) r;

-- ------------------------------------------------------------------------------
-- 5. 品牌销售榜 TOP 30
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE ads_brand_sales_day PARTITION (dt = '${hivevar:bizdate}')
SELECT
    brand,
    sku_cnt,
    view_cnt,
    cart_cnt,
    purchase_cnt,
    total_gmv,
    CASE WHEN day_gmv > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / CAST(day_gmv AS DOUBLE), 6) END AS gmv_share,
    gmv_rank,
    CASE WHEN purchase_cnt > 0 THEN ROUND(CAST(total_gmv AS DOUBLE) / purchase_cnt, 2) END        AS avg_order_value
FROM (
    SELECT
        brand, sku_cnt, view_cnt, cart_cnt, purchase_cnt, total_gmv,
        SUM(total_gmv) OVER () AS day_gmv,
        ROW_NUMBER() OVER (ORDER BY total_gmv DESC, brand ASC) AS gmv_rank
    FROM (
        SELECT
            COALESCE(brand, '未知品牌') AS brand,
            COUNT(DISTINCT product_id)  AS sku_cnt,
            SUM(view_cnt)               AS view_cnt,
            SUM(cart_cnt)               AS cart_cnt,
            SUM(purchase_cnt)           AS purchase_cnt,
            SUM(total_gmv)              AS total_gmv
        FROM dws_product_action_day
        WHERE dt = '${hivevar:bizdate}'
        GROUP BY COALESCE(brand, '未知品牌')
    ) g
) r
WHERE gmv_rank <= 30;

SELECT '${hivevar:bizdate}' AS finished_dt;
