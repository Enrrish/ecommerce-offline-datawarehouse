-- ==============================================================================
-- ads_retention.sql —— 新增用户留存（Cohort 分析，全期重算）
-- 执行：hive -f ads_retention.sql
--
-- 为什么这张表不做"按天增量"：
--   留存天然是跨天计算——10-05 新增的用户，要等到 10-12 才知道他 7 日是否留存。
--   所以 T+1 调度时也必须重跑全量（只有 31 行，成本可忽略），
--   这跟"按天分区的表只写当天"是两种调度模式，项目里两种都要有。
--
-- 口径（与 ads_ddl.sql 表注释一致，这里写实现细节）：
--   1) 第 N 日留存 = 首活后第 N 天仍产生任意行为的人数 / 该 cohort 新增人数；
--      用 DATEDIFF(活跃日, 首活日) = N 精确匹配，不是"N 天内活跃过"的模糊口径。
--   2) 观察窗口不足时（首活日 + N 天 > 数据最大日期）结果置 NULL，不拿部分数据凑数。
--   3) 数据集首日的 cohort 全部是存量用户伪装的"新客"，用 is_data_start_cohort 标记。
-- ==============================================================================

USE mydb;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
SET hive.exec.parallel=true;
SET hive.auto.convert.join=false;

INSERT OVERWRITE TABLE ads_user_retention_day PARTITION (dt)
SELECT
    new_users,
    retain_1d,
    retain_3d,
    retain_7d,
    retain_15d,
    retain_30d,
    CASE WHEN retain_1d  IS NOT NULL AND new_users > 0 THEN ROUND(retain_1d  / new_users, 4) END AS retention_1d_rate,
    CASE WHEN retain_3d  IS NOT NULL AND new_users > 0 THEN ROUND(retain_3d  / new_users, 4) END AS retention_3d_rate,
    CASE WHEN retain_7d  IS NOT NULL AND new_users > 0 THEN ROUND(retain_7d  / new_users, 4) END AS retention_7d_rate,
    CASE WHEN retain_15d IS NOT NULL AND new_users > 0 THEN ROUND(retain_15d / new_users, 4) END AS retention_15d_rate,
    CASE WHEN retain_30d IS NOT NULL AND new_users > 0 THEN ROUND(retain_30d / new_users, 4) END AS retention_30d_rate,
    is_data_start_cohort,
    cohort_date                                          -- 动态分区列必须放最后一列
FROM (
    SELECT
        c.first_active_date                                                          AS cohort_date,
        COUNT(DISTINCT c.user_id)                                                    AS new_users,
        IF(DATE_ADD(c.first_active_date,  1) <= b.max_dt,
           COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) =  1, c.user_id, NULL)),
           CAST(NULL AS BIGINT))                                                     AS retain_1d,
        IF(DATE_ADD(c.first_active_date,  3) <= b.max_dt,
           COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) =  3, c.user_id, NULL)),
           CAST(NULL AS BIGINT))                                                     AS retain_3d,
        IF(DATE_ADD(c.first_active_date,  7) <= b.max_dt,
           COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) =  7, c.user_id, NULL)),
           CAST(NULL AS BIGINT))                                                     AS retain_7d,
        IF(DATE_ADD(c.first_active_date, 15) <= b.max_dt,
           COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) = 15, c.user_id, NULL)),
           CAST(NULL AS BIGINT))                                                     AS retain_15d,
        IF(DATE_ADD(c.first_active_date, 30) <= b.max_dt,
           COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) = 30, c.user_id, NULL)),
           CAST(NULL AS BIGINT))                                                     AS retain_30d,
        CAST(IF(c.first_active_date = b.min_dt, 1, 0) AS TINYINT)                    AS is_data_start_cohort
    FROM (
        SELECT MIN(dt) AS min_dt, MAX(dt) AS max_dt
        FROM dws_user_action_day
    ) b
    CROSS JOIN dim_user_first_active c
    LEFT JOIN (
        SELECT DISTINCT user_id, dt
        FROM dws_user_action_day
    ) a ON c.user_id = a.user_id
    GROUP BY c.first_active_date, b.min_dt, b.max_dt
) t
ORDER BY cohort_date;

SELECT 'retention_done' AS flag;
