-- ==============================================================================
-- dwd_etl.sql —— ODS → DWD 单天清洗入仓
-- 执行：hive -f dwd_etl.sql --hivevar bizdate=2019-10-01
--
-- 六道工序在这条 SQL 里的落点：
--   ① 类型收敛  CAST(... AS TIMESTAMP/BIGINT/DECIMAL)
--   ② 空值语义  NULLIF(TRIM(x),'') —— 空串变 NULL，绝不变 0
--   ③ 去重      ROW_NUMBER() 五字段唯一键取 rn=1
--   ④ 脏数据    不丢行：没有 WHERE 过滤，异常值留给 DQ 报警
--   ⑤ 时间解析  HOUR() 派生 event_hour
--   ⑥ 幂等      INSERT OVERWRITE + 静态分区 dt='${bizdate}'
-- ==============================================================================

-- 注意：hive.exec.parallel 在 Hive 3.1.x 上有已知 bug，
--       开启后会抛 java.util.ConcurrentModificationException（已在集群实测）。
--       单条 INSERT 本来就只有一个依赖链，并行也收益不大，这里显式关掉。
SET hive.exec.parallel = false;
SET hive.vectorized.execution.enabled = true;

INSERT OVERWRITE TABLE mydb.dwd_user_behavior_di
PARTITION (dt = '${hivevar:bizdate}')      -- 静态分区：写哪一分区由调度决定，不靠数据内容
SELECT
    CAST(t.event_time AS TIMESTAMP)                          AS event_time,
    t.event_type                                             AS event_type,
    CAST(NULLIF(TRIM(t.product_id),    '') AS BIGINT)        AS product_id,
    CAST(NULLIF(TRIM(t.category_id),   '') AS BIGINT)        AS category_id,
    NULLIF(TRIM(t.category_code), '')                        AS category_code,
    NULLIF(TRIM(t.brand),         '')                        AS brand,
    CAST(NULLIF(TRIM(t.price),         '') AS DECIMAL(10,2)) AS price,
    CAST(NULLIF(TRIM(t.user_id),       '') AS BIGINT)        AS user_id,
    NULLIF(TRIM(t.user_session), '')                         AS user_session,
    HOUR(CAST(t.event_time AS TIMESTAMP))                    AS event_hour
FROM (
    SELECT
        event_time, event_type, product_id, category_id,
        category_code, brand, price, user_id, user_session,
        -- ③ 去重：五字段唯一键
        --    同一用户、同一时刻、同一商品、同一行为、同一会话 → 出现两次必然是重复投递
        ROW_NUMBER() OVER (
            PARTITION BY event_time, user_id, product_id, event_type, user_session
            -- ORDER BY 不能只写分区键，否则并列时取哪条不确定、重跑结果可能漂移。
            -- 这里的规则是"保留信息最全的那条"：有品牌优先、有价格优先。
            ORDER BY
                IF(brand IS NOT NULL AND TRIM(brand) <> '', 0, 1),
                IF(price IS NOT NULL AND TRIM(price) <> '', 0, 1)
        ) AS rn
    FROM mydb.ods_user_behavior_di
    WHERE dt = '${hivevar:bizdate}'   -- 只读当天分区（分区裁剪），不扫全表
) t
WHERE t.rn = 1;

-- ==============================================================================
-- 几个必须理解的取舍
--
-- Q: 为什么只在"当天分区内"去重，不做全局去重？
-- A: 同一用户在 10-01 00:00:01 和 10-02 00:00:01 对同一商品的两次行为，
--    业务上是两次，不是重复。跨天去重需要全表 shuffle，代价放大 31 倍，
--    而且会误杀真实的重复行为。上游重复投递只会发生在"同一批文件"里，
--    所以按业务日分区内去重既准确又便宜。
--
-- Q: 为什么不用 WHERE 过滤掉异常数据？
-- A: DWD 层静默丢行是数仓大忌。一旦上游出问题（比如某天 user_id 全空），
--    加了过滤你只会看到 DWS 数字下降，却不知道为什么；
--    不加过滤，行数守恒，DQ 规则能立刻定位到"哪个字段空了多少"。
--    过滤应该在 DWS/ADS 按业务口径做，且要记 drop_cnt。
--
-- Q: 静态分区和动态分区的区别？
-- A: 静态 PARTITION(dt='2019-10-01')：写哪个分区由你写死，
--    即使忘了写 WHERE 也只会污染这一个分区，不会动其他 30 天。
--    动态 PARTITION(dt) 的 OVERWRITE 只覆盖"本次 SQL 实际产出的分区"，
--    在按天增量场景下同样安全，但静态分区更符合"调度显式指定"的语义。
-- ==============================================================================
