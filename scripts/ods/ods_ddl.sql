-- ==============================================================================
-- ods_ddl.sql —— ODS 贴源层建库建表
-- 执行：hive -f ods_ddl.sql
--
-- ODS 三条铁律（这条 DDL 逐条对应）：
--   1) 不做清洗：无 WHERE、无 CASE、无类型转换，源文件什么样就什么样
--   2) 不改结构：9 个原始字段原样保留，顺序不变
--   3) 不删数据：外部表 + 无过滤
--
-- 关于表命名 ods_user_behavior_di：
--   _di = daily increment（日增量），对应"上游每天投递一个文件"
--   若是每日全量快照则叫 _df（daily full）
--   命名带增量/全量后缀是阿里《大数据之路》的规范，面试能加分
-- ==============================================================================

-- 建库：不指定 LOCATION
-- 原因：库的 LOCATION 是该库下所有"托管表"的默认落点。
--       若设成 /origin_data/...，后面 DWD/DWS/ADS 也会落到贴源区，
--       与原始 CSV 混在一起，违反"贴源数据 vs 加工数据物理隔离"。
--       所以库用默认 /user/hive/warehouse/mydb.db，
--       ODS 外部表的路径在建表时单独用 LOCATION 指定。
CREATE DATABASE IF NOT EXISTS mydb COMMENT '电商离线数仓';

USE mydb;

-- DROP 保证脚本可重复执行。
-- 注意：这是 EXTERNAL 外部表，DROP 只删元数据，HDFS 上的 CSV 不受影响。
DROP TABLE IF EXISTS ods_user_behavior_di;

CREATE EXTERNAL TABLE IF NOT EXISTS ods_user_behavior_di (
    event_time    STRING COMMENT '事件时间 yyyy-MM-dd HH:mm:ss',
    event_type    STRING COMMENT '事件类型 view/cart/purchase',
    product_id    STRING COMMENT '商品ID',
    category_id   STRING COMMENT '分类ID',
    category_code STRING COMMENT '分类代码',
    brand         STRING COMMENT '品牌',
    price         STRING COMMENT '价格',
    user_id       STRING COMMENT '用户ID',
    user_session  STRING COMMENT '会话ID'
)
-- 分区键含义：这批数据属于哪个"业务日"
-- 它由调度系统传入（本阶段手动指定），绝不能从 event_time 里算：
--   若源数据出现 NULL 时间，会产生 __HIVE_DEFAULT_PARTITION__ 幽灵分区
COMMENT '用户行为日志贴源表（日增量）'
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
-- OpenCSVSerde：正确处理逗号分隔与引号包裹
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    "separatorChar" = ",",
    "quoteChar"     = "\"",
    "escapeChar"    = "\\"
)
-- ODS 保持 TEXTFILE：贴源保真，可随时 hdfs dfs -cat 回看原始文本
-- 代价是不压缩、占空间；若追求存储可换 ORC+Snappy，但会失去"原文可读性"
STORED AS TEXTFILE
-- LOCATION 指向"表根"，不是分区目录
-- 表根下面只放 dt=xxx 子目录，绝不直接放数据文件
LOCATION '/origin_data/ecommerce/mydb/ods_user_behavior_di/'
-- 不设 skip.header.line.count：
--   源文件在 split_source.sh 里已去掉表头（NR>1）
--   该参数是"跳过每个文件的第一行"，多文件时极易静默丢行
TBLPROPERTIES ('external.table.purge' = 'false');

-- 说明：为什么不在这里加 etl_time 审计字段？
--   外部表按 CSV 文本解析，文件只有 9 列，第 10 列会恒为 NULL，没有意义。
--   审计信息应单独建 ods_etl_log 表记录（文件名/行数/md5/入库时间）。
-- ==============================================================================
-- 建完立刻自检
-- ==============================================================================
SHOW TABLES;
DESCRIBE FORMATTED ods_user_behavior_di;
