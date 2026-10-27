-- ==============================================================================
-- ads_rfm.sql —— 用户价值分层（RFM 全期快照）
-- 执行：hive -f ads_rfm.sql
--
-- 结果写到分区 dt = 统计截止日（即数据最大日期），重跑即覆盖，天然幂等。
--
-- 三个分数的打分方式故意不同，理由如下（面试要能说清）：
--   R 固定区间：业务上"最近 7 天内买过"本身就是明确的高价值信号，
--               用固定阈值，不同月份的分层结果可以直接横向对比；
--               若用等频 NTILE，分数会随当月数据分布漂移，跨月无法比较。
--   F 固定区间：购买次数是离散小整数，绝大多数用户只有 1 次，
--               NTILE(5) 会把大量并列值随机切进不同桶——同样的行为拿到不同的分，不可用。
--   M 等频 NTILE：金额是连续长尾变量，等频分桶最合理，且只对有购买行为的用户分桶，
--               否则 300 万未购买用户会把第 1 桶挤满，购买用户的分数全部失真。
--   未购买用户不参与打分，单独归入 未购买用户 层——RFM 模型本身只描述交易客户。
-- ==============================================================================

USE mydb;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
-- 并行执行在本集群有过 ConcurrentModificationException（docs/03 第 3 条），保持关闭
SET hive.exec.parallel=false;
SET hive.auto.convert.join=false;

-- base：每用户全期的 最近购买日 / 购买次数 / 累计金额 / 距今天数
-- first_active_date 直接复用 DWS 已固化的首活日维表，不在 ADS 重算，避免口径漂移
WITH agg AS (
    SELECT
        user_id,
        MAX(IF(purchase_cnt > 0, dt, CAST(NULL AS STRING)))  AS last_purchase_date,
        SUM(purchase_cnt)                                    AS frequency,
        SUM(total_gmv)                                       AS monetary
    FROM dws_user_action_day
    GROUP BY user_id
),
bounds AS (
    SELECT MAX(dt) AS stat_date
    FROM dws_user_action_day
),
base AS (
    SELECT
        a.user_id,
        d.first_active_date,
        a.last_purchase_date,
        DATEDIFF(b.stat_date, a.last_purchase_date)          AS recency_days,
        a.frequency,
        a.monetary,
        b.stat_date
    FROM agg a
    JOIN dim_user_first_active d ON a.user_id = d.user_id
    CROSS JOIN bounds b
)

INSERT OVERWRITE TABLE ads_user_value_rfm PARTITION (dt)
SELECT
    user_id,
    first_active_date,
    last_purchase_date,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    rfm_type,
    stat_date                                              -- 动态分区列必须放最后一列
FROM (
    -- 有购买行为：打分 + 8 类分层
    SELECT
        user_id,
        first_active_date,
        last_purchase_date,
        recency_days,
        frequency,
        monetary,
        r_score,
        f_score,
        m_score,
        CASE
            WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN '重要价值客户'
            WHEN r_score <  3 AND f_score >= 3 AND m_score >= 3 THEN '重要保持客户'
            WHEN r_score >= 3 AND f_score <  3 AND m_score >= 3 THEN '重要发展客户'
            WHEN r_score <  3 AND f_score <  3 AND m_score >= 3 THEN '重要挽留客户'
            WHEN r_score >= 3 AND f_score >= 3 AND m_score <  3 THEN '一般价值客户'
            WHEN r_score <  3 AND f_score >= 3 AND m_score <  3 THEN '一般保持客户'
            WHEN r_score >= 3 AND f_score <  3 AND m_score <  3 THEN '一般发展客户'
            ELSE '一般挽留客户'
        END                                                  AS rfm_type,
        stat_date
    FROM (
        SELECT
            user_id,
            first_active_date,
            last_purchase_date,
            recency_days,
            frequency,
            monetary,
            stat_date,
            CAST(CASE
                     WHEN recency_days <=  3 THEN 5
                     WHEN recency_days <=  7 THEN 4
                     WHEN recency_days <= 15 THEN 3
                     WHEN recency_days <= 25 THEN 2
                     ELSE 1
                 END AS TINYINT)                             AS r_score,
            CAST(CASE
                     WHEN frequency <= 1 THEN 1
                     WHEN frequency =  2 THEN 2
                     WHEN frequency =  3 THEN 3
                     WHEN frequency <= 5 THEN 4
                     ELSE 5
                 END AS TINYINT)                             AS f_score,
            CAST(NTILE(5) OVER (ORDER BY CAST(monetary AS DOUBLE) ASC, user_id ASC) AS TINYINT) AS m_score
        FROM base
        WHERE frequency > 0
    ) scored

    UNION ALL

    -- 无购买行为：不参与打分，单独成层
    SELECT
        user_id,
        first_active_date,
        CAST(NULL AS STRING)                                 AS last_purchase_date,
        CAST(NULL AS INT)                                    AS recency_days,
        frequency,
        monetary,
        CAST(NULL AS TINYINT)                                AS r_score,
        CAST(NULL AS TINYINT)                                AS f_score,
        CAST(NULL AS TINYINT)                                AS m_score,
        '未购买用户'                                          AS rfm_type,
        stat_date
    FROM base
    WHERE frequency = 0
) final_t;

SELECT 'rfm_done' AS flag;
