-- ==============================================================================
-- dws_ddl.sql —— DWS 汇总层建表
-- 执行：hive -f dws_ddl.sql
--
-- DWS 与 DWD 的分界：
--   DWD 是"一行一次行为"（明细），谁都能查，但查指标要自己写聚合；
--   DWS 是"一行一个主题粒度"（汇总），把最常用的聚合固化下来，
--       并且——这一层开始引入"业务口径"，必须写进注释。
--
-- 本层三张表 + 一张维表雏形：
--   dim_user_first_active   用户首活日（维表，非分区）
--   dws_user_action_day     用户 × 天
--   dws_product_action_day  商品 × 天
--   dws_user_funnel_day     天（同日漏斗，每天 1 行）
-- ==============================================================================

USE mydb;

-- ------------------------------------------------------------------------------
-- 维表雏形：用户首活日
-- 为什么单独建一张表，而不是每次现算 MIN(dt)？
--   现算要扫 DWD 全表 31 天，每天跑一次就是 31 次全表扫描；
--   而且倒序补数时会算错：先跑 10-05 再跑 10-01，10-01 那天会误判成"老用户"。
--   把首活日固化成一张小表（20 万行），join 时走 map join，又快又准。
-- 这张表就是 dim_user 的起点，P1 阶段会扩展成完整用户维度。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_user_first_active;
CREATE TABLE IF NOT EXISTS dim_user_first_active (
    user_id            BIGINT COMMENT '用户ID',
    first_active_date  STRING COMMENT '首次活跃日期 yyyy-MM-dd（取全期 MIN(dt)）'
)
COMMENT '用户首活日维表（维表雏形）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表1：用户日行为汇总
-- 粒度：user_id × dt，一天一个用户一行
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dws_user_action_day;
CREATE TABLE IF NOT EXISTS dws_user_action_day (
    user_id            BIGINT        COMMENT '用户ID',
    view_cnt           BIGINT        COMMENT '当日浏览次数（PV，同人多次累加）',
    cart_cnt           BIGINT        COMMENT '当日加购次数',
    purchase_cnt       BIGINT        COMMENT '当日购买次数',
    total_gmv          DECIMAL(12,2) COMMENT '当日成交金额 = SUM(price) of purchase 事件。注意：源数据无 quantity 字段，因此严格含义是"成交单价之和"，不是含件数的商品交易总额',
    first_active_date  STRING        COMMENT '用户首次活跃日期（来自 dim_user_first_active）',
    is_new_user        TINYINT       COMMENT '是否新用户 1=当日为首次活跃 0=老用户'
)
COMMENT '用户日行为汇总表'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表2：商品日行为汇总
-- 粒度：product_id × dt，一天一个商品一行
-- 维度属性取"当天事件里的值"（日快照），不做全期回填：
--   同一商品在 30 天内可能有 100 个换过品牌，日快照能保留变更痕迹，
--   全期最新值会让历史报表"回溯变形"（今天改了品牌，昨天报表也跟着变）。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dws_product_action_day;
CREATE TABLE IF NOT EXISTS dws_product_action_day (
    product_id     BIGINT        COMMENT '商品ID',
    category_id    BIGINT        COMMENT '分类ID（取当天事件中的值，MAX 忽略 NULL）',
    category_code  STRING        COMMENT '分类代码（取当天事件中的值，可能为 NULL，源数据 31% 缺失）',
    brand          STRING        COMMENT '品牌（取当天事件中的值，可能为 NULL，源数据 13% 缺失）',
    view_cnt       BIGINT        COMMENT '当日浏览次数',
    cart_cnt       BIGINT        COMMENT '当日加购次数',
    purchase_cnt   BIGINT        COMMENT '当日购买次数',
    total_gmv      DECIMAL(12,2) COMMENT '当日成交金额 = SUM(price) of purchase 事件（无 quantity，同用户表口径）'
)
COMMENT '商品日行为汇总表'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表3：同日漏斗（每天 1 行）
-- 口径：当日有过该行为的人数（去重），不是次数
-- 关键说明（务必写进看板备注，否则业务一定来问）：
--   cart_users 会小于 pay_users，导致 cart_to_pay_rate > 1。
--   这不是 SQL 写错：源数据里 cart 事件仅占 1.06%，purchase 占 3.15%，
--   大量用户浏览后直接下单，不经过加购。所以"加购→支付"不是主转化路径，
--   主指标应看 view_to_pay_rate；cart_to_pay_rate 仅作参考。
--   strict_funnel_users 是真正走完 浏览→加购→支付 三步的人数，
--   它才能反映加购环节的真实漏斗损耗。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS dws_user_funnel_day;
CREATE TABLE IF NOT EXISTS dws_user_funnel_day (
    active_users         BIGINT        COMMENT '当日活跃人数（任意事件去重）',
    view_users           BIGINT        COMMENT '当日浏览人数（view 去重）',
    cart_users           BIGINT        COMMENT '当日加购人数（cart 去重）',
    pay_users            BIGINT        COMMENT '当日支付人数（purchase 去重）',
    strict_funnel_users  BIGINT        COMMENT '当日走完 浏览+加购+支付 三步的人数（严格漏斗）',
    view_to_cart_rate    DECIMAL(10,4) COMMENT '加购人数 / 浏览人数（同日）',
    cart_to_pay_rate     DECIMAL(10,4) COMMENT '支付人数 / 加购人数。注意：会 > 1，见建表注释',
    view_to_pay_rate     DECIMAL(10,4) COMMENT '支付人数 / 浏览人数，主转化指标'
)
COMMENT '同日用户行为漏斗表'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

SHOW TABLES;
