-- ==============================================================================
-- dws_backfill.sql —— DWS 批量补数（一次性处理全部日期）
-- 执行：hive -f dws_backfill.sql
--
-- 为什么要有这个脚本，而不是循环调 dws_etl_day.sql？
--   日常调度的单位是"一天"（dws_etl_day.sql），因为每天只新增一天数据；
--   但历史补数要跑 31 天，如果循环调用，每天都要重新 shuffle 302 万行维表，
--   实测单天 142 秒 × 31 天 ≈ 73 分钟。
--   改成"按 (user_id, dt) 一次聚合 + 动态分区"，维表只 join 一次，
--   整个月 5~8 分钟跑完。
--
--   这就是数仓里"日常增量" 与 "历史补数" 必须用两套 SQL 的原因——
--   一个优化的是单次执行成本，一个优化的是总量成本。
--
-- 动态分区的语义（容易误解，务必看清）：
--   INSERT OVERWRITE ... PARTITION(dt) 只覆盖"本次 SELECT 实际产出的分区"。
--   本脚本产出 2019-10 的 31 个分区，就只覆盖这 31 个，
--   不会动其他月份——这既保证了幂等，也不会误删。
-- ==============================================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
SET hive.exec.max.dynamic.partitions = 2000;
SET hive.exec.max.dynamic.partitions.pernode = 200;
SET hive.exec.parallel = false;
SET hive.vectorized.execution.enabled = true;
SET hive.auto.convert.join = false;      -- 302 万行维表走 shuffle join，理由见 dws_etl_day.sql

-- ------------------------------------------------------------------------------
-- ① 用户日表
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_user_action_day
PARTITION (dt)
SELECT
    u.user_id,
    u.view_cnt,
    u.cart_cnt,
    u.purchase_cnt,
    u.total_gmv,
    d.first_active_date,
    IF(d.first_active_date = u.dt, 1, 0) AS is_new_user,
    u.dt                                  -- 动态分区列必须放最后一列
FROM (
    SELECT
        user_id,
        dt,
        SUM(IF(event_type = 'view',     1, 0)) AS view_cnt,
        SUM(IF(event_type = 'cart',     1, 0)) AS cart_cnt,
        SUM(IF(event_type = 'purchase', 1, 0)) AS purchase_cnt,
        SUM(IF(event_type = 'purchase', price, CAST(0 AS DECIMAL(10,2)))) AS total_gmv
    FROM mydb.dwd_user_behavior_di
    WHERE user_id IS NOT NULL
    GROUP BY user_id, dt
) u
LEFT JOIN mydb.dim_user_first_active d
       ON u.user_id = d.user_id;

-- ------------------------------------------------------------------------------
-- ② 商品日表
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_product_action_day
PARTITION (dt)
SELECT
    product_id,
    MAX(category_id)   AS category_id,
    MAX(category_code) AS category_code,
    MAX(brand)         AS brand,
    SUM(IF(event_type = 'view',     1, 0)) AS view_cnt,
    SUM(IF(event_type = 'cart',     1, 0)) AS cart_cnt,
    SUM(IF(event_type = 'purchase', 1, 0)) AS purchase_cnt,
    SUM(IF(event_type = 'purchase', price, CAST(0 AS DECIMAL(10,2)))) AS total_gmv,
    dt
FROM mydb.dwd_user_behavior_di
WHERE product_id IS NOT NULL
GROUP BY product_id, dt;

-- ------------------------------------------------------------------------------
-- ③ 同日漏斗表
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_user_funnel_day
PARTITION (dt)
SELECT
    COUNT(1)                        AS active_users,
    SUM(IF(view_cnt > 0, 1, 0))     AS view_users,
    SUM(IF(cart_cnt > 0, 1, 0))     AS cart_users,
    SUM(IF(pay_cnt  > 0, 1, 0))     AS pay_users,
    SUM(IF(view_cnt > 0 AND cart_cnt > 0 AND pay_cnt > 0, 1, 0)) AS strict_funnel_users,
    ROUND(SUM(IF(cart_cnt > 0, 1, 0)) / NULLIF(SUM(IF(view_cnt > 0, 1, 0)), 0), 4) AS view_to_cart_rate,
    ROUND(SUM(IF(pay_cnt  > 0, 1, 0)) / NULLIF(SUM(IF(cart_cnt > 0, 1, 0)), 0), 4) AS cart_to_pay_rate,
    ROUND(SUM(IF(pay_cnt  > 0, 1, 0)) / NULLIF(SUM(IF(view_cnt > 0, 1, 0)), 0), 4) AS view_to_pay_rate,
    dt
FROM (
    SELECT
        user_id,
        dt,
        SUM(IF(event_type = 'view',     1, 0)) AS view_cnt,
        SUM(IF(event_type = 'cart',     1, 0)) AS cart_cnt,
        SUM(IF(event_type = 'purchase', 1, 0)) AS pay_cnt
    FROM mydb.dwd_user_behavior_di
    WHERE user_id IS NOT NULL
    GROUP BY user_id, dt
) t
GROUP BY dt;
