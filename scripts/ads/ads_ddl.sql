-- ==============================================================================
-- ads_ddl.sql —— ADS 应用数据层建表（7 张）
-- 执行：hive -f ads_ddl.sql
--
-- ADS 的定位：一表一需求。每张表对应看板上的一个具体页面，
--   字段名直接对齐看板展示，业务方不需要再写 SQL 就能取数。
--
-- 与 DWS 的分界（面试常问）：
--   DWS 是"主题域汇总"（用户 / 商品 / 漏斗），粒度由数据模型决定；
--   ADS 是"需求汇总"，粒度由看板决定——可能跨主题域 join，也可能只取 TOP N，
--   还可能带窗口函数算排名。所以 ADS 允许"冗余"，只要看板好用。
--
-- 七张表分三条主线：
--   大盘   ads_trade_overview_day
--   用户   ads_user_funnel_day / ads_user_retention_day / ads_user_value_rfm
--   商品   ads_product_rank_day / ads_category_sales_day / ads_brand_sales_day
--
-- 通用口径（7 张表一致）：
--   1) 金额字段沿用 DWS，名为 gmv，但源数据无 quantity，严格含义是"成交单价之和"；
--   2) category_code / brand 缺失分别保留为 未知品类 / 未知品牌 单独成组，
--      保证各表 GMV 加总等于大盘，不做丢弃；
--   3) 比率类字段统一 DECIMAL(10,4)，占比类 DECIMAL(10,6)，分子分母为 0 时结果为 NULL。
-- ==============================================================================

USE mydb;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
-- Hive 3.1 在开并行时偶发 ConcurrentModificationException，本项目统一关闭
SET hive.exec.parallel=false;
-- dim_user_first_active 有 302 万行，map join 走 Hive CLI 本地 JVM 会 OOM，统一改 shuffle join
SET hive.auto.convert.join=false;

-- ------------------------------------------------------------------------------
-- 表1：大盘日报（看板第一屏）
-- 粒度：dt，一天一行
-- 来源：dws_user_action_day
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_trade_overview_day;
CREATE TABLE ads_trade_overview_day (
    active_users      BIGINT         COMMENT '当日活跃用户数（当日有过任意行为的用户去重）',
    new_users         BIGINT         COMMENT '当日新增用户数（当日为首次活跃）',
    old_users         BIGINT         COMMENT '当日老用户数 = 活跃 - 新增',
    new_user_ratio    DECIMAL(10,4)  COMMENT '新用户占比 = 新增 / 活跃。注意：数据集首日为伪新客，见留存表注释',
    view_pv           BIGINT         COMMENT '当日浏览次数（PV，不去重）',
    cart_pv           BIGINT         COMMENT '当日加购次数（PV）',
    purchase_pv       BIGINT         COMMENT '当日购买次数（PV，即订单数）',
    pay_users         BIGINT         COMMENT '当日下单用户数（有 purchase 行为的用户去重）',
    pay_user_ratio    DECIMAL(10,4)  COMMENT '下单用户占比 = 下单用户 / 活跃用户',
    total_gmv         DECIMAL(14,2)  COMMENT '当日成交金额（无 quantity，实为成交单价之和）',
    avg_order_value   DECIMAL(12,2)  COMMENT '客单价 = GMV / 订单数，订单数为 0 时为 NULL',
    arpu              DECIMAL(12,2)  COMMENT '人均成交金额 = GMV / 活跃用户数'
)
COMMENT '大盘日报：规模与产出核心指标'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表2：漏斗与人群结构分析
-- 粒度：dt，一天一行
-- 来源：dws_user_funnel_day（漏斗人数与转化率） + dws_user_action_day（新老拆分）
-- 为什么不放进大盘表：大盘看"规模"，本表看"转化与结构"，字段太多挤一起不好维护。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_user_funnel_day;
CREATE TABLE ads_user_funnel_day (
    active_users         BIGINT         COMMENT '当日活跃人数',
    view_users           BIGINT         COMMENT '当日浏览人数',
    cart_users           BIGINT         COMMENT '当日加购人数',
    pay_users            BIGINT         COMMENT '当日支付人数',
    strict_funnel_users  BIGINT         COMMENT '当日走完 浏览+加购+支付 三步的人数（严格漏斗）',
    view_to_cart_rate    DECIMAL(10,4)  COMMENT '浏览 -> 加购 转化率（人数口径）',
    cart_to_pay_rate     DECIMAL(10,4)  COMMENT '加购 -> 支付 转化率。会 > 1，因大量用户跳过加购直接下单，仅作参考',
    view_to_pay_rate     DECIMAL(10,4)  COMMENT '浏览 -> 支付 转化率，主转化指标',
    new_pay_users        BIGINT         COMMENT '当日下单的新用户数',
    old_pay_users        BIGINT         COMMENT '当日下单的老用户数',
    new_user_gmv         DECIMAL(14,2)  COMMENT '当日新用户贡献的 GMV',
    old_user_gmv         DECIMAL(14,2)  COMMENT '当日老用户贡献的 GMV',
    new_gmv_ratio        DECIMAL(10,4)  COMMENT '新用户 GMV 占比'
)
COMMENT '用户漏斗与新老人群结构分析'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表3：新增用户留存（Cohort 分析）
-- 粒度：dt = 新增日期（cohort 日期），一个 cohort 一行
-- 来源：dim_user_first_active（首活日） + dws_user_action_day（每日活跃明细）
--
-- 两个必须写进注释的口径：
--   1) 留存定义：第 N 日留存 = 首活后第 N 天仍产生任意行为的人数 / 该 cohort 新增人数。
--      用 DATEDIFF(活跃日, 首活日) = N 精确匹配，不是"N 天内活跃过"。
--   2) 数据集只有 31 天，靠后的 cohort 算不满 15 / 30 日留存，
--      此时结果置 NULL 而不是用部分数据凑数——宁可空着，不能给错的数。
--      判断依据：首活日 + N 天 <= 数据最大日期。
--   3) is_data_start_cohort = 1 的行（数据集首日）不要看留存：
--      数据从 2019-10-01 开始，这天所有存量用户都被判成"新用户"，
--      这批人根本不是新客，留存率没有参考意义。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_user_retention_day;
CREATE TABLE ads_user_retention_day (
    new_users            BIGINT         COMMENT '该 cohort 新增用户数',
    retain_1d            BIGINT         COMMENT '次活跃后第 1 日仍活跃的人数',
    retain_3d            BIGINT         COMMENT '第 3 日仍活跃的人数',
    retain_7d            BIGINT         COMMENT '第 7 日仍活跃的人数',
    retain_15d           BIGINT         COMMENT '第 15 日仍活跃的人数',
    retain_30d           BIGINT         COMMENT '第 30 日仍活跃的人数',
    retention_1d_rate    DECIMAL(10,4)  COMMENT '次日留存率',
    retention_3d_rate    DECIMAL(10,4)  COMMENT '3 日留存率',
    retention_7d_rate    DECIMAL(10,4)  COMMENT '7 日留存率',
    retention_15d_rate   DECIMAL(10,4)  COMMENT '15 日留存率，观察窗口不足时为 NULL',
    retention_30d_rate   DECIMAL(10,4)  COMMENT '30 日留存率，观察窗口不足时为 NULL',
    is_data_start_cohort TINYINT        COMMENT '1=数据集首日的 cohort，其新增用户实为存量用户，留存率不可信'
)
COMMENT '新增用户留存分析（Cohort）'
PARTITIONED BY (dt STRING COMMENT '新增日期 yyyy-MM-dd（cohort）')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表4：商品热销榜 TOP 50
-- 粒度：dt × rank_no
-- 来源：dws_product_action_day
-- 排序口径：按当日 GMV 降序，GMV 相同时按 product_id 升序兜底，保证结果可复现。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_product_rank_day;
CREATE TABLE ads_product_rank_day (
    rank_no           INT            COMMENT '当日 GMV 排名，1 开始',
    product_id        BIGINT         COMMENT '商品ID',
    category_code     STRING         COMMENT '品类代码（缺失为 未知品类）',
    brand             STRING         COMMENT '品牌（缺失为 未知品牌）',
    view_cnt          BIGINT         COMMENT '当日浏览次数',
    cart_cnt          BIGINT         COMMENT '当日加购次数',
    purchase_cnt      BIGINT         COMMENT '当日购买次数',
    total_gmv         DECIMAL(14,2)  COMMENT '当日 GMV',
    gmv_share         DECIMAL(10,6)  COMMENT '该商品 GMV 占当日大盘 GMV 的比例',
    view_to_pay_rate  DECIMAL(10,4)  COMMENT '该商品 购买次数 / 浏览次数，浏览量为 0 时为 NULL'
)
COMMENT '商品热销榜 TOP 50'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表5：品类销售分析
-- 粒度：dt × category_code，每天 127 行左右
-- 来源：dws_product_action_day
-- 为什么同时存 cat_level1 和 category_code：源数据的品类码是层级结构
--   （appliances.kitchen.washer），带上一级名看板可以直接做下钻，不用再建一张表。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_category_sales_day;
CREATE TABLE ads_category_sales_day (
    cat_level1        STRING         COMMENT '一级品类（取品类码第一段，如 electronics）',
    category_code     STRING         COMMENT '品类代码（缺失为 未知品类）',
    sku_cnt           BIGINT         COMMENT '当日产生过行为的商品数',
    view_cnt          BIGINT         COMMENT '当日浏览次数',
    cart_cnt          BIGINT         COMMENT '当日加购次数',
    purchase_cnt      BIGINT         COMMENT '当日购买次数',
    total_gmv         DECIMAL(14,2)  COMMENT '当日 GMV',
    gmv_share         DECIMAL(10,6)  COMMENT '该品类 GMV 占当日大盘的比例',
    gmv_rank          INT            COMMENT '当日品类 GMV 排名，1 开始',
    avg_order_value   DECIMAL(12,2)  COMMENT '客单价 = GMV / 购买次数，为 0 时为 NULL'
)
COMMENT '品类销售分析（含一级品类，支持下钻）'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表6：品牌销售榜 TOP 30
-- 粒度：dt × brand
-- 来源：dws_product_action_day
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_brand_sales_day;
CREATE TABLE ads_brand_sales_day (
    brand             STRING         COMMENT '品牌（缺失为 未知品牌）',
    sku_cnt           BIGINT         COMMENT '当日产生过行为的商品数',
    view_cnt          BIGINT         COMMENT '当日浏览次数',
    cart_cnt          BIGINT         COMMENT '当日加购次数',
    purchase_cnt      BIGINT         COMMENT '当日购买次数',
    total_gmv         DECIMAL(14,2)  COMMENT '当日 GMV',
    gmv_share         DECIMAL(10,6)  COMMENT '该品牌 GMV 占当日大盘的比例',
    gmv_rank          INT            COMMENT '当日品牌 GMV 排名，1 开始',
    avg_order_value   DECIMAL(12,2)  COMMENT '客单价 = GMV / 购买次数，为 0 时为 NULL'
)
COMMENT '品牌销售榜 TOP 30'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------------------------
-- 表7：用户价值分层（RFM）
-- 粒度：user_id，全期快照；分区 dt = 统计截止日，重跑即覆盖
-- 来源：dws_user_action_day（全期累计） + dim_user_first_active
--
-- 打分口径（为什么不用纯 NTILE 等频分桶，面试可以讲）：
--   R 固定区间：业务上"最近 7 天内购买过"本身就是明确的高价值信号，
--               等频分桶会让分数随数据分布漂移，跨月无法横向对比，所以固定。
--   F 固定区间：购买次数是离散小整数，绝大多数用户只有 1 次，
--               NTILE(5) 会把并列值随机切到不同桶，同一行为得到不同分数，不可用。
--   M 等频 NTILE：金额是连续变量，分布长尾，用等频分桶最合理。
--   未购买用户：不参与打分，单独归为 未购买用户 层（RFM 本身只描述交易客户）。
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS ads_user_value_rfm;
CREATE TABLE ads_user_value_rfm (
    user_id            BIGINT         COMMENT '用户ID',
    first_active_date  STRING         COMMENT '首次活跃日期',
    last_purchase_date STRING         COMMENT '最近一次购买日期，从未购买为 NULL',
    recency_days       INT            COMMENT '最近购买距统计截止日的天数，从未购买为 NULL',
    frequency          BIGINT         COMMENT '全期累计购买次数',
    monetary           DECIMAL(14,2)  COMMENT '全期累计成交金额',
    r_score            TINYINT        COMMENT 'R 分 1-5，固定区间打分',
    f_score            TINYINT        COMMENT 'F 分 1-5，固定区间打分',
    m_score            TINYINT        COMMENT 'M 分 1-5，NTILE 等频打分',
    rfm_type           STRING         COMMENT '价值分层：重要价值客户/重要保持客户/重要发展客户/重要挽留客户/一般价值客户/一般保持客户/一般发展客户/一般挽留客户/未购买用户'
)
COMMENT '用户价值分层（RFM 全期快照）'
PARTITIONED BY (dt STRING COMMENT '统计截止日 yyyy-MM-dd')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

SHOW TABLES;
