-- ==============================================================================
-- ods_add_partition.sql —— 挂载单个分区（给调度系统按天调用）
--
-- 用法：
--   hive -f ods_add_partition.sql --hivevar dt=2019-10-01
--
-- 用 hivevar 而不是 hiveconf：
--   hiveconf 会和 Hive 自身配置项混在同一个命名空间，容易误覆盖系统参数；
--   hivevar 是独立的变量空间，只用于传业务变量。
--
-- ADD IF NOT EXISTS：
--   重复执行不报错，这是"可重跑"的基本保障。
--
-- 为什么显式写 LOCATION：
--   不写时 Hive 会自动拼成 {表LOCATION}/dt=值，也能用；
--   但显式写出来，路径一眼可见，排查问题时不用去翻建表语句。
-- ==============================================================================

ALTER TABLE mydb.ods_user_behavior_di
ADD IF NOT EXISTS PARTITION (dt='${hivevar:dt}')
LOCATION '/origin_data/ecommerce/mydb/ods_user_behavior_di/dt=${hivevar:dt}';

-- 挂载后立即自检：非空校验（ODS 最基础的一条质量规则）
SELECT dt, COUNT(1) AS row_cnt
FROM mydb.ods_user_behavior_di
WHERE dt = '${hivevar:dt}'
GROUP BY dt;
