-- ==============================================================================
-- ads_retention.sql —— 新增用户留存（Cohort 分析，全期重算）
-- 执行：由 ads_load.sh 合并调度；手动执行需传两个日期变量：
--   hive --hivevar min_date=2019-10-01 --hivevar max_date=2019-10-31 -f ads_retention.sql
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
--
-- 【2026-10-27 性能改造 1】COUNT(DISTINCT) → SUM(IF())：
--   原来 5 个留存人数都用 COUNT(DISTINCT IF(diff=N, user_id, NULL))，每个 DISTINCT
--   都要维护一份最多 300 万用户的哈希表。但 dws_user_action_day 已经按 (user_id, dt)
--   去过重（实测 6444006 行 = 6444006 个组合），同一 cohort 内每个用户在每个 diff
--   值上只会出现一次，DISTINCT 是多余的，改成 SUM(IF(diff=N, 1, 0)) 结果完全等价。
-- 【2026-10-27 性能改造 2】砍掉两段白付钱的子查询：
--   a) LEFT JOIN 的右表原来包了一层 SELECT DISTINCT user_id, dt——源表本身就唯一
--      （见上），这一层 DISTINCT 白付一次 644 万行的 shuffle 聚合，直接读表；
--   b) MIN(dt)/MAX(dt) 原来对 dws 全表扫一遍，而分区清单在 metastore 里现成就有，
--      改由 ads_load.sh 从 SHOW PARTITIONS 取出后用 hivevar 传入。
-- ==============================================================================

USE mydb;

SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
-- 并行执行在本集群有过 ConcurrentModificationException（docs/03 第 3 条），保持关闭
SET hive.exec.parallel=false;
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
        IF(DATE_ADD(c.first_active_date,  1) <= '${hivevar:max_date}',
           SUM(IF(DATEDIFF(a.dt, c.first_active_date) =  1, 1, 0)),
           CAST(NULL AS BIGINT))                                                     AS retain_1d,
        IF(DATE_ADD(c.first_active_date,  3) <= '${hivevar:max_date}',
           SUM(IF(DATEDIFF(a.dt, c.first_active_date) =  3, 1, 0)),
           CAST(NULL AS BIGINT))                                                     AS retain_3d,
        IF(DATE_ADD(c.first_active_date,  7) <= '${hivevar:max_date}',
           SUM(IF(DATEDIFF(a.dt, c.first_active_date) =  7, 1, 0)),
           CAST(NULL AS BIGINT))                                                     AS retain_7d,
        IF(DATE_ADD(c.first_active_date, 15) <= '${hivevar:max_date}',
           SUM(IF(DATEDIFF(a.dt, c.first_active_date) = 15, 1, 0)),
           CAST(NULL AS BIGINT))                                                     AS retain_15d,
        IF(DATE_ADD(c.first_active_date, 30) <= '${hivevar:max_date}',
           SUM(IF(DATEDIFF(a.dt, c.first_active_date) = 30, 1, 0)),
           CAST(NULL AS BIGINT))                                                     AS retain_30d,
        CAST(IF(c.first_active_date = '${hivevar:min_date}', 1, 0) AS TINYINT)       AS is_data_start_cohort
    FROM dim_user_first_active c
    LEFT JOIN dws_user_action_day a ON c.user_id = a.user_id
    GROUP BY c.first_active_date
) t
ORDER BY cohort_date;

SELECT 'retention_done' AS flag;
