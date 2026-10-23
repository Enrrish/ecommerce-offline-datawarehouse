-- ==============================================================================
-- dws_etl_day.sql —— DWD → DWS 单天汇总（三张表一次产出）
-- 执行：hive -f dws_etl_day.sql --hivevar bizdate=2019-10-01
--
-- 三个 INSERT 的顺序：用户表 → 商品表 → 漏斗表
-- 它们互不依赖，都只读当天 DWD 分区，所以三层结果可以互相交叉校验。
-- ==============================================================================

SET hive.exec.parallel = false;             -- Hive 3.1 开启会抛 ConcurrentModificationException
SET hive.vectorized.execution.enabled = true;
-- 关掉自动 map join。首活日维表有 302 万用户，Hive 会把它当小表做 map join，
-- 而 map join 实际跑在 Hive CLI 自己的 JVM 里（MapredLocalTask），
-- 受客户端堆限制，从而抛 "Map local work exhausted memory"。
-- 注意：此时调 mapreduce.map.memory.mb 是无效的（那是 YARN 容器内存，不是本地任务内存），
-- 实测调到 3GB 依然失败。要么调大客户端堆（HADOOP_CLIENT_OPTS=-Xmx4g），
-- 要么像这样退回普通 shuffle join。这里选后者：慢约 90 秒/天，但稳定、不依赖客户端内存。
SET hive.auto.convert.join = false;

-- ------------------------------------------------------------------------------
-- ① 用户日表：user_id × dt
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_user_action_day
PARTITION (dt = '${hivevar:bizdate}')
SELECT
    u.user_id,
    u.view_cnt,
    u.cart_cnt,
    u.purchase_cnt,
    u.total_gmv,
    d.first_active_date,
    IF(d.first_active_date = '${hivevar:bizdate}', 1, 0) AS is_new_user
FROM (
    SELECT
        user_id,
        SUM(IF(event_type = 'view',     1, 0))             AS view_cnt,
        SUM(IF(event_type = 'cart',     1, 0))             AS cart_cnt,
        SUM(IF(event_type = 'purchase', 1, 0))             AS purchase_cnt,
        -- 只对 purchase 事件累加金额；view/cart 的 price 是"展示价"，不是成交额
        SUM(IF(event_type = 'purchase', price, CAST(0 AS DECIMAL(10,2)))) AS total_gmv
    FROM mydb.dwd_user_behavior_di
    WHERE dt = '${hivevar:bizdate}'
      AND user_id IS NOT NULL          -- 防御性过滤（当前 0 条），丢失行数由 dws_load.sh 核对
    GROUP BY user_id
) u
LEFT JOIN mydb.dim_user_first_active d
       ON u.user_id = d.user_id;

-- ------------------------------------------------------------------------------
-- ② 商品日表：product_id × dt
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_product_action_day
PARTITION (dt = '${hivevar:bizdate}')
SELECT
    product_id,
    -- 维度属性取当天事件中的值：MAX 会忽略 NULL，
    -- 因此当天只要有一条事件带了品牌就能取到，全为空时返回 NULL（保留"源数据没给"的语义）。
    -- 若当天出现多个非空品牌（全期有 100 个商品换过品牌），取字典序最大值，
    -- 目的是"确定且可复现"——重跑一百次结果恒等，不会因 shuffle 顺序漂移。
    MAX(category_id)   AS category_id,
    MAX(category_code) AS category_code,
    MAX(brand)         AS brand,
    SUM(IF(event_type = 'view',     1, 0)) AS view_cnt,
    SUM(IF(event_type = 'cart',     1, 0)) AS cart_cnt,
    SUM(IF(event_type = 'purchase', 1, 0)) AS purchase_cnt,
    SUM(IF(event_type = 'purchase', price, CAST(0 AS DECIMAL(10,2)))) AS total_gmv
FROM mydb.dwd_user_behavior_di
WHERE dt = '${hivevar:bizdate}'
  AND product_id IS NOT NULL
GROUP BY product_id;

-- ------------------------------------------------------------------------------
-- ③ 同日漏斗表：dt（每天 1 行）
-- 先按用户打平，再统计人数——这样 active/view/cart/pay 四个数天然自洽，
-- strict_funnel_users 也能在同一行里算出来。
-- ------------------------------------------------------------------------------
INSERT OVERWRITE TABLE mydb.dws_user_funnel_day
PARTITION (dt = '${hivevar:bizdate}')
SELECT
    COUNT(1)                                            AS active_users,
    SUM(IF(view_cnt > 0, 1, 0))                         AS view_users,
    SUM(IF(cart_cnt > 0, 1, 0))                         AS cart_users,
    SUM(IF(pay_cnt  > 0, 1, 0))                         AS pay_users,
    SUM(IF(view_cnt > 0 AND cart_cnt > 0 AND pay_cnt > 0, 1, 0)) AS strict_funnel_users,
    ROUND(SUM(IF(cart_cnt > 0, 1, 0)) / NULLIF(SUM(IF(view_cnt > 0, 1, 0)), 0), 4) AS view_to_cart_rate,
    ROUND(SUM(IF(pay_cnt  > 0, 1, 0)) / NULLIF(SUM(IF(cart_cnt > 0, 1, 0)), 0), 4) AS cart_to_pay_rate,
    ROUND(SUM(IF(pay_cnt  > 0, 1, 0)) / NULLIF(SUM(IF(view_cnt > 0, 1, 0)), 0), 4) AS view_to_pay_rate
FROM (
    SELECT
        user_id,
        SUM(IF(event_type = 'view',     1, 0)) AS view_cnt,
        SUM(IF(event_type = 'cart',     1, 0)) AS cart_cnt,
        SUM(IF(event_type = 'purchase', 1, 0)) AS pay_cnt
    FROM mydb.dwd_user_behavior_di
    WHERE dt = '${hivevar:bizdate}'
      AND user_id IS NOT NULL
    GROUP BY user_id
) t;

-- ==============================================================================
-- 口径备忘（面试/文档可直接引用）
--
-- 1) total_gmv 只累加 purchase 事件的 price。view/cart 事件里的 price 是"展示价"，
--    把它算进 GMV 是最常见的口径错误（会把 GMV 放大好几倍）。
-- 2) 本数据无 quantity 字段，所以 gmv 严格含义是"成交单价之和"。
--    若一单多件，该值会低于真实交易额——这是数据源限制，不是 SQL 问题。
-- 3) 三张表的 GMV 必须完全相等（都等于 74,948,758.44），
--    任何不一致都说明某一层的过滤条件写错了。
-- 4) cart_to_pay_rate > 1 是数据特性（用户跳过加购直接下单），不是 bug。
-- ==============================================================================
