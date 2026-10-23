-- ==============================================================================
-- dwd_ddl.sql —— DWD 明细层建表
-- 执行：hive -f dwd_ddl.sql
--
-- 与 ODS 的对照（DWD 的使命就是"什么都别放过"）：
--   ODS 贴源：全 STRING、外部表、TEXTFILE、不清洗 —— 目的是"能回溯"
--   DWD 明细：强类型、内部表、ORC 列存  —— 目的是"能算、算得快、算得准"
--
-- 为什么这里用内部表（托管表）而不是外部表？
--   外部表是给别人数据的"引用"，删表不能删数据；
--   DWD 的数据是 Hive 自己算出来的，删表就该连数据一起清，
--   否则 DROP 之后 HDFS 上会留下一堆没人认的孤儿目录。
--   所以：ODS 外部表、DWD 及以上内部表，这是通用规矩。
-- ==============================================================================

USE mydb;

DROP TABLE IF EXISTS dwd_user_behavior_di;

CREATE TABLE IF NOT EXISTS dwd_user_behavior_di (
    event_time     TIMESTAMP     COMMENT '事件时间 yyyy-MM-dd HH:mm:ss',
    event_type     STRING        COMMENT '事件类型 view/cart/purchase',
    product_id     BIGINT        COMMENT '商品ID',
    category_id    BIGINT        COMMENT '分类ID',
    category_code  STRING        COMMENT '分类代码',
    brand          STRING        COMMENT '品牌（空值保留为 NULL，不填 unknown）',
    price          DECIMAL(10,2) COMMENT '商品价格',
    user_id        BIGINT        COMMENT '用户ID',
    user_session   STRING        COMMENT '会话ID',
    event_hour     INT           COMMENT '事件小时 0-23，供分时分析'
)
COMMENT '用户行为明细表（日增量，已清洗去重）'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd，由调度传入')
-- ORC：列式存储，只扫需要的列；自带索引与压缩，比 TEXTFILE 省 70%+ 空间
STORED AS ORC
TBLPROPERTIES (
    'orc.compress' = 'SNAPPY',       -- 解压快，CPU 友好；追求极致压缩率可换 ZLIB
    'orc.bloom.filter.columns' = 'product_id,user_id'   -- 等值查询加速
);

-- 字段设计说明（面试常问"为什么这么设计"）：
--   1) price 用 DECIMAL(10,2) 而不是 DOUBLE
--      DOUBLE 是浮点近似值，0.1+0.2 != 0.3，金额累加会漂移；
--      DECIMAL 是定点精确值，财务口径必须用 DECIMAL。
--   2) category_id 用 BIGINT：源数据里有 2053013554658804075 这样的 19 位数字，
--      INT 最大约 21 亿（10 位），装不下会溢出成 NULL。
--   3) brand 保留 NULL 而不是填 'unknown'
--      NULL 表示"源数据没给"，'unknown' 表示"我判断它未知"，含义不同。
--      填 'unknown' 应该发生在 ADS 出报表时，而不是在 DWD 破坏原始语义。
--   4) event_hour 是派生列，不是原始列
--      DWD 允许增加派生列（这是对业务的增强），但不允许修改原始 9 列的值。
--   5) 没有 is_valid_* 标记列
--      探查显示脏数据只有 12,850 条 price=0（0.14%），
--      用 WHERE 就能筛，不必为它增加一列；等 DQ 阶段再统一打标。

SHOW TABLES;
