-- ==============================================================================
-- dws_dim_user.sql —— 重建用户首活日维表（全量，非增量）
-- 执行：hive -f dws_dim_user.sql
--
-- 只在两种时机跑：
--   1) 首次建仓
--   2) 新增了月份/补了历史更早的数据之后
-- 日常按天跑批不需要重建，直接 join 现成的表即可。
-- ==============================================================================

USE mydb;

INSERT OVERWRITE TABLE mydb.dim_user_first_active
SELECT
    user_id,
    MIN(dt) AS first_active_date
FROM mydb.dwd_user_behavior_di
WHERE user_id IS NOT NULL      -- 防御：NULL 用户无法归属，且会在维表里形成一条垃圾记录
GROUP BY user_id;

-- 自检
SELECT COUNT(1) AS user_cnt, MIN(first_active_date) AS min_dt, MAX(first_active_date) AS max_dt
FROM mydb.dim_user_first_active;
