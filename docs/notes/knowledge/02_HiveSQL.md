# Hive SQL 知识卡

> 项目里所有清洗、聚合、报表都用 Hive SQL 完成。这一章按"建表 → 写数 → 查询 → 调优 → 排错"的顺序整理。

---

## 1. Hive 是什么、SQL 怎么跑起来

Hive 把 SQL 翻译成分布式作业（本项目是 MapReduce，也可以换 Tez/Spark），数据落在 HDFS。

| 角色 | 说明 |
|---|---|
| Metastore | 存库/表/分区/字段等元数据，本项目放在 MySQL |
| HDFS | 存真实数据文件 |
| 执行引擎 | 把 SQL 变成 MR 任务 |
| Hive CLI / Beeline | 客户端，提交 SQL |

**必须建立的直觉**：一条 SQL 不是"一条命令"，而是**一到多个 stage**；每个 `JOIN`、`GROUP BY`、`DISTINCT` 都可能触发一次 shuffle。SQL 写得好不好，本质是**shuffle 的数据量和次数**。

---

## 2. 对象模型

```
Database
└── Table
    ├── 普通表（内部表）
    ├── 外部表 EXTERNAL
    └── Partition（分区目录 dt=xxx）
        └── Bucket（分桶，本项目未用）
```

### 内部表 vs 外部表

| | 内部表 | 外部表 |
|---|---|---|
| `DROP TABLE` | 删元数据 **+ 删数据** | 只删元数据 |
| 适用 | 由 Hive 派生、可重建（DWD 及以上） | 贴源数据、多人共享（ODS） |
| 建表 | `CREATE TABLE` | `CREATE EXTERNAL TABLE` |

外部表还有一个隐藏开关：`TBLPROPERTIES('external.table.purge'='true')` 会让 `DROP` 连数据一起删，别乱加。

### 存储格式

| 格式 | 特点 | 项目用法 |
|---|---|---|
| TEXTFILE | 纯文本、可 `cat`、不压缩 | ODS 贴源 |
| ORC | 列式、压缩比高、支持列裁剪/谓词下推 | DWD/DWS/ADS |
| Parquet | 列式、生态通用 | 未用 |

ORC 的价值：只读用到的列 + Snappy 压缩，扫描量和存储都下降。

---

## 3. DDL 模板

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS ods_xxx_di (
    a STRING COMMENT '原始字段',
    b STRING
)
COMMENT '贴源表'
PARTITIONED BY (dt STRING COMMENT '业务日期')
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ("separatorChar"=",", "quoteChar"="\"", "escapeChar"="\\")
STORED AS TEXTFILE
LOCATION '/origin_data/.../ods_xxx_di/';

CREATE TABLE IF NOT EXISTS dwd_xxx_di (
    a BIGINT COMMENT '收敛后的类型',
    b DECIMAL(10,2)
)
COMMENT '明细表'
PARTITIONED BY (dt STRING)
STORED AS ORC
TBLPROPERTIES ('orc.compress'='SNAPPY');
```

要点：

- `COMMENT` 不是装饰，**口径要写进表/字段注释**，否则半年后没人知道 `gmv` 含不含运费；
- 内部表不写 `LOCATION`，落在库目录下；
- 分区字段不能重复出现在普通字段里；
- 建表脚本开头 `DROP TABLE IF EXISTS` 可重复执行，但外部表要先确认数据能不能删。

---

## 4. 分区：Hive 性能的第一开关

### 静态分区 vs 动态分区

```sql
-- 静态：写给哪一天由调度决定
INSERT OVERWRITE TABLE t PARTITION (dt='2024-01-01') SELECT ...;

-- 动态：由 SELECT 的最后一列决定
INSERT OVERWRITE TABLE t PARTITION (dt)
SELECT ..., dt FROM src GROUP BY ..., dt;
```

| | 静态 | 动态 |
|---|---|---|
| 分区值 | 写死/变量 | 来自数据 |
| 适用 | 日常单天 | 历史批量补数 |
| 风险 | 低（只影响一个分区） | 分区过多、误写脏分区 |

动态分区必开：

```sql
SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
SET hive.exec.max.dynamic.partitions=2000;
SET hive.exec.max.dynamic.partitions.pernode=200;
```

**动态分区列必须放 SELECT 最后一列**，顺序错了会报错或写错分区。

### 分区裁剪

```sql
-- 会裁剪
WHERE dt = '2024-01-01'
WHERE dt BETWEEN '2024-01-01' AND '2024-01-31'

-- 不会裁剪（分区列上套函数）
WHERE SUBSTR(dt,1,7) = '2024-01'
WHERE DATE_FORMAT(dt,'yyyy-MM') = '2024-01'
```

分区裁剪是**写 SQL 时**决定的，不是调参调出来的。所有查询的第一过滤条件应该是分区字段。

### 分区管理

```sql
SHOW PARTITIONS t;
ALTER TABLE t ADD IF NOT EXISTS PARTITION (dt='2024-01-01') LOCATION '/path/dt=2024-01-01';
MSCK REPAIR TABLE t;   -- 目录已存在但元数据没有时，批量修复
```

---

## 5. 写入语义：幂等的关键

| 语句 | 语义 |
|---|---|
| `INSERT OVERWRITE` | 覆盖目标分区/表 |
| `INSERT INTO` | 追加（重跑会翻倍） |
| `CREATE TABLE AS SELECT` | 建表并写入 |

数仓脚本**默认只用 `OVERWRITE`**：

- 静态分区 + `OVERWRITE`：重跑同一天结果不变；
- 动态分区 + `OVERWRITE`：只覆盖本次产出的分区，不碰其他月份。

`INSERT INTO` 只适合"日志追加"这类天然不重复的场景，调度脚本里慎用。

---

## 6. 类型、NULL 与精度

### 全 STRING 贴源，下游再收敛

```sql
CAST(NULLIF(TRIM(t.user_id), '') AS BIGINT)
```

三步缺一不可：

1. `TRIM` 去空格；
2. `NULLIF(...,'')` 把空串变 NULL；
3. `CAST` 转类型。

顺序反了（先 CAST 再 NULLIF）空串会先变 NULL，语义没差别，但脏值更难查。

### NULL 的三个高频坑

| 坑 | 说明 | 写法 |
|---|---|---|
| `NULL = NULL` 不成立 | 用 `IS NULL` | `WHERE x IS NULL` |
| `NULL` 参与运算结果为 NULL | 分母为 0 要用 `NULLIF` | `a / NULLIF(b,0)` |
| `COUNT(col)` 不数 NULL | 想数行用 `COUNT(1)` | `COUNT(1)` |

`COALESCE(a,b,c)` 返回第一个非 NULL，适合做"未知分组"兜底。

### DECIMAL

- 金额统一 `DECIMAL(p,s)`，不要用 `DOUBLE` 累加（二进制浮点会有尾差）；
- `DECIMAL` 与 `DOUBLE` 混算会退化成 `DOUBLE`，比率计算时显式 `CAST`；
- 比率统一 `DECIMAL(10,4)` 或 `ROUND(...,4)`，避免同一指标两种精度。

---

## 7. 查询：五种必须练熟的形状

### ① 条件聚合

```sql
SUM(IF(event_type='purchase', 1, 0))          AS pay_cnt
SUM(IF(event_type='purchase', price, 0))      AS gmv
COUNT(DISTINCT IF(pay_cnt>0, user_id, NULL))  AS pay_users
```

一次扫描算多个指标，比多个 `WHERE` 子查询快，且口径天然一致。

### ② 窗口函数

```sql
ROW_NUMBER() OVER (PARTITION BY dt ORDER BY gmv DESC, product_id) AS rn
RANK()       OVER (PARTITION BY dt ORDER BY gmv DESC)             AS rk
NTILE(5)     OVER (ORDER BY monetary)                             AS bucket
SUM(gmv)     OVER ()                                              AS day_gmv
LAG(gmv, 1)  OVER (PARTITION BY product_id ORDER BY dt)           AS prev_gmv
```

| 函数 | 特点 | 用途 |
|---|---|---|
| `ROW_NUMBER` | 1,2,3 不重复 | 去重、TOP N |
| `RANK` | 并列跳号 | 排行榜（允许并列） |
| `DENSE_RANK` | 并列不跳号 | 分档 |
| `NTILE(n)` | 等频分桶 | RFM 的 M 分 |
| `SUM/AVG OVER` | 窗口内聚合 | 占比、累计 |

窗口函数在 `SELECT` 阶段执行，**不能直接写在 `WHERE` 里**，要套一层子查询再过滤。

### ③ CTE（`WITH`）

```sql
WITH base AS (SELECT ... FROM dwd WHERE dt='...'),
     agg  AS (SELECT ... FROM base GROUP BY ...)
SELECT ... FROM agg;
```

复杂 SQL 用 CTE 拆成"数据流"，比嵌套子查询可读得多。CTE 只是语法糖，不会自动物化。

### ④ JOIN

| 类型 | 语义 | 注意 |
|---|---|---|
| `INNER JOIN` | 两边都匹配 | 会丢不匹配行 |
| `LEFT JOIN` | 左表全保留 | 右表多行会导致左表膨胀 |
| `FULL JOIN` | 两边都保留 | 少用 |
| `CROSS JOIN` | 笛卡尔积 | 单行参数表可用 |

**LEFT JOIN 后 `WHERE` 右表字段** 会把外连接变成内连接（NULL 被过滤），要写 `WHERE r.col IS NULL` 或把条件放 `ON`。

### ⑤ UNION ALL

```sql
SELECT ... FROM a
UNION ALL
SELECT ... FROM b;
```

- `UNION ALL` 不除重，快；
- `UNION` 会除重，慢；
- 两边列数、类型必须一致；`NULL` 要 `CAST(NULL AS BIGINT)` 明确类型，否则可能推断失败。

---

## 8. 函数速查

| 类别 | 常用函数 |
|---|---|
| 条件 | `IF(cond,a,b)`、`CASE WHEN`、`COALESCE`、`NULLIF` |
| 字符串 | `TRIM`、`SPLIT(str,regex)`、`CONCAT`、`SUBSTR`、`REGEXP_REPLACE` |
| 日期 | `DATEDIFF(a,b)`、`DATE_ADD(d,n)`、`DATE_SUB`、`TO_DATE`、`HOUR`、`DATE_FORMAT` |
| 聚合 | `SUM`、`COUNT`、`COUNT(DISTINCT)`、`MAX`、`MIN`、`COLLECT_SET` |
| 窗口 | `ROW_NUMBER`、`RANK`、`DENSE_RANK`、`NTILE`、`LAG`、`LEAD`、`SUM OVER` |
| 类型 | `CAST`、`ROUND`、`FLOOR`、`CEIL` |

注意：

- `SPLIT` 第二个参数是**正则**，分隔 `.` 要写 `'\\.'`；
- `MAX()` 忽略 NULL，常用来取"当天任意一个非空值"；
- `COUNT(DISTINCT)` 在超大基数上很贵，能先聚合再 count 就别直接 distinct。

---

## 9. 调优：先看 shuffle，再看参数

### 三个最常见的性能问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 任务卡在 reduce 99% | 数据倾斜（某个 key 特别多） | 加盐打散、`hive.groupby.skewindata=true`、拆分热点 |
| map 阶段 OOM | map join 把大表当小表 | `hive.auto.convert.join=false` |
| 小文件太多 | 动态分区/多 reducer 产出大量小文件 | 合并小文件、控制 reducer 数 |

### map join 的真相

Hive 会把"小表"读进内存做 map join。但**这个本地任务跑在 Hive 客户端 JVM 里**（`MapredLocalTask`），不在 YARN 容器里。

所以：

- 报 `Map local work exhausted memory` 时，调 `mapreduce.map.memory.mb` **没用**；
- 要么调大客户端堆（`HADOOP_CLIENT_OPTS=-Xmx4g`），要么直接 `SET hive.auto.convert.join=false` 走 shuffle join。

### 常用参数

```sql
SET hive.exec.parallel=false;              -- Hive 3.1 开启偶发 ConcurrentModificationException
SET hive.auto.convert.join=false;          -- 大维表走 shuffle join
SET hive.vectorized.execution.enabled=true;-- 向量化，扫描更快
SET hive.map.aggr=true;                    -- map 端预聚合
SET hive.groupby.skewindata=true;          -- 倾斜时两阶段聚合
SET hive.merge.mapfiles=true;              -- 合并小文件
```

参数是**最后一步**。先看执行计划：

```sql
EXPLAIN SELECT ...;
EXPLAIN EXTENDED SELECT ...;
```

重点看：有没有走分区裁剪、join 是 map join 还是 common join、有几个 stage。

---

## 10. 报错字典

| 报错 | 根因 | 处理 |
|---|---|---|
| `SemanticException ... Invalid table alias or column reference` | 列名/别名写错，或 `SELECT` 别名在同层 `WHERE` 里用了 | 改列名；别名过滤套子查询 |
| `FAILED: ParseException` | 语法错，常见于文件末尾 `/* */` 块注释 | 全改 `--` 行注释 |
| `Map local work exhausted memory` | map join 本地任务内存不足 | 关 map join 或加客户端堆 |
| `Dynamic partition strict mode ...` | 动态分区没开 nonstrict | `SET hive.exec.dynamic.partition.mode=nonstrict` |
| `Number of dynamic partitions exceeded` | 分区数超限 | 调大上限或缩小输入范围 |
| `ConcurrentModificationException` | `hive.exec.parallel=true` | 关并行 |
| `Vertex failed / Container killed` | 容器内存超限 | 调 `mapreduce.map/reduce.memory.mb` 或减小并发 |
| 结果全是 NULL | `CAST` 失败/分隔符不匹配/NULL 参与运算 | 抽样看原始值、检查 SerDe |

---

## 11. Hive vs MySQL（面试常问）

| 维度 | Hive | MySQL |
|---|---|---|
| 定位 | 离线数仓、批量分析 | OLTP、事务 |
| 存储 | HDFS，列式 ORC | 本地磁盘，行式 InnoDB |
| 延迟 | 分钟级 | 毫秒级 |
| 更新 | 以 `OVERWRITE` 为主，不适合行级 update | 支持 `UPDATE/DELETE` |
| 索引 | 无 B+ 树索引，靠分区/列裁剪 | 主键/二级索引 |
| 事务 | 默认不支持（ACID 表另说） | 完整 ACID |
| 适合 | 全量扫描、聚合、窗口 | 点查、事务、元数据 |

结论：**明细和聚合放 Hive，元数据和小表放 MySQL**，不要反过来。

---

## 12. 自测

1. 内部表和外部表在 `DROP` 时分别做什么？ODS 为什么必须外部表？
2. 静态分区和动态分区各适合什么场景？动态分区列为什么必须放最后？
3. `WHERE SUBSTR(dt,1,7)='2024-01'` 为什么不会分区裁剪？
4. `CAST(NULLIF(TRIM(x),'') AS BIGINT)` 每一步分别在解决什么？
5. `ROW_NUMBER` / `RANK` / `DENSE_RANK` 的区别？去重该用哪个？
6. 窗口函数为什么不能直接写在 `WHERE` 里？
7. `LEFT JOIN` 后在 `WHERE` 里过滤右表字段，会发生什么？
8. map join 的内存受谁限制？报 `Map local work exhausted memory` 该调什么？
9. `INSERT OVERWRITE ... PARTITION(dt)` 动态分区会覆盖哪些分区？
10. 一条 SQL 慢，你先看什么？`EXPLAIN` 里重点看哪三件事？
