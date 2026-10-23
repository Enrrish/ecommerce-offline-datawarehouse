## 一、ODS 层到底是什么

ODS（Operational Data Store）叫**贴源层**。它的唯一使命是：**在 HDFS 上给源系统的数据拍一张“原样照片”**。

为什么要有这一层，而不是直接从 CSV 算指标？三个现实原因：

1. **可回溯**。三个月后业务说“10 月 5 号的 GMV 不对”，你要能回答“源文件当时是什么样”。如果 ODS 里做了清洗，你就再也证明不了“是源就脏，还是我算错了”。
2. **可重放**。DWD 改了清洗逻辑要全量重跑时，ODS 是唯一稳定的输入。没有 ODS，每次重跑都要重新找业务方要数据。
3. **解耦**。源系统表结构变了，只需要改 ODS 一处映射，DWD 以上不动。

由此推出**三条铁律**，也是判断 ODS 做得对不对的标准：

- **不做清洗**：空值、脏数据、异常值原样保留，它是源系统的“特征”不是“bug”；
- **不改结构**：源表几列、什么顺序，ODS 就几列什么顺序（只允许加审计字段，不许改原始字段）；
- **不删数据**：不允许 `WHERE` 过滤掉任何一行。

你现在的 `ods_user_behavior.txt` **这三点都守住了**——9 个字段全 STRING、外部表、无过滤。这是你项目里做得最规范的地方，我要先肯定这一点。

## 二、规范 ODS 落地的八个步骤

### 第 1 步：数据探查（profiling）——90% 的新手跳过

在写任何 DDL 之前，必须先摸清数据。这不是形式主义，我拿你的数据举例，这些数字都是我在本地实际算出来的：

| 探查项              | 你的数据实况                           | 对设计的影响                              |
| ---------------- | -------------------------------- | ----------------------------------- |
| 总行数              | 9,244,421（不含表头）                  | 决定分区粒度和文件切分                         |
| 时间范围             | 2019-10-01 ~ 10-31，31 天          | **按天分区，31 个分区，天然合适**                |
| event_type 枚举    | 仅 view / cart / purchase，无异常值    | 但 ODS 不校验，留给 DWD                    |
| brand 空值         | 121.7 万条（13%），37,079 个商品**整列为空** | 说明不能 NOT NULL                       |
| category_code 空值 | 约 290 万条（31%），622 个品类中 370 个整列为空 | 同上                                  |
| price = 0        | 12,850 条（0.14%）                  | 不是空值，是业务真值，不能删                      |
| 字段包裹             | 全部带双引号，空值写作 `""`                 | 必须用 CSV SerDe，不能用默认 LazySimpleSerDe |

**新手错误 ①：不探查就建表。** 后果是 DECIMAL(10,2) 装不下、日期格式对不上、字符集炸掉——你之前改 UTF-8 那次就是典型，如果先探查就不会拖到建表后才发现。

### 第 2 步：定目录规范

ODS 数据在 HDFS 上的目录必须有明确规范，**不能随手放**。推荐结构：

```
/origin_data/
└── {业务域}/                        ecommerce
    └── {db}/                       mydb
        └── {表名}/                  ods_user_behavior_di
            ├── dt=2019-10-01/
            │   └── ecommerce_events_20191001.csv
            ├── dt=2019-10-02/
            └── dt=2019-10-31/
```

**新手错误 ②：把业务数据放 `/tmp`。** 你现在的 LOCATION 是 `'/tmp/upload_ecommerce/'`，这是真实项目里会被骂的做法：`/tmp` 语义上就是临时区，很多集群还配了自动清理策略；而且它违反了“按业务域隔离”的原则，别人一眼看不出这批数据属于哪个项目。

### 第 3 步：源文件预处理

三个必须处理的问题：

- **表头**：建议**源文件直接不带表头**。原因是 `skip.header.line.count=1` 的作用是**跳过每个文件的第一行**——如果你按天拆成 31 个文件、每个都带表头，Hive 会乖乖跳过 31 次，看起来正常；但如果哪天一个目录下放了 2 个文件，就会多丢数据行。更隐蔽的是：它只对 TEXTFILE 生效，且部分老版本对某些 SerDe 不生效。你现在之所以做了 `ecommerce_events_no_header.csv`，很可能当时就是被这个坑逼的。
- **换行符**：Windows 上传的 CSV 是 CRLF，Hive 读出来字段末尾会带 `\r`。你在 DWD 里写 `REGEXP_REPLACE(..., '[\\r\\n]', '')` 说明踩过。规范做法是在上传前 `dos2unix`，不要在 SQL 里补救——补救逻辑散落在 DWD，换一张表就忘了。
- **BOM**：Excel 导出的 UTF-8 带 BOM，第一个字段名会变成 `\ufeffevent_time`，直接导致列名对不上。

### 第 4 步：建表（标准模板）

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS ods_user_behavior (
    event_time    STRING COMMENT '事件时间',
    event_type    STRING COMMENT '事件类型',
    product_id    STRING COMMENT '产品ID',
    category_id   STRING COMMENT '分类ID',
    category_code STRING COMMENT '分类代码',
    brand         STRING COMMENT '品牌',
    price         STRING COMMENT '价格',
    user_id       STRING COMMENT '用户ID',
    user_session  STRING COMMENT '会话ID'
)
PARTITIONED BY (dt STRING COMMENT '业务日期 yyyy-MM-dd')
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ("separatorChar"=",", "quoteChar"="\"", "escapeChar"="\\")
STORED AS TEXTFILE
LOCATION '/origin_data/ecommerce/mydb/ods_user_behavior/'

```

四个关键点，一一对应新手常见错误：

- **`EXTERNAL`**：外部表。新手错误 ③ 是用内部表，`DROP TABLE` 直接把 HDFS 数据删掉，而外部表只删元数据。
- **全 `STRING`**：新手错误 ④ 是在 ODS 用 BIGINT/DECIMAL。一条 `"abc"` 的价格会让整个任务失败，而且**因为失败你连数据都看不到**。ODS 的任务是“先收下来”，类型解析是 DWD 的事。
- **`IF NOT EXISTS`**：脚本可重复执行，不会因表已存在报错。
- **`PARTITIONED BY (dt)`**：这是你现在唯一缺的、也是最关键的一项。

关于 ODS 存储格式，行业有两种做法，你要知道取舍：**保持 TEXTFILE**（贴源保真，可随时回看原始文本，代价是占空间）vs **转 ORC+Snappy**（省 70% 空间、查询快，代价是丢失“原始文本可读性”）。学习项目建议 TEXTFILE，面试时能讲清这个取舍就是加分。

### 第 5 步：上传（必须幂等）

```bash
HDFS_DIR=/origin_data/ecommerce/mydb/ods_user_behavior/dt=2019-10-01
hdfs dfs -rm -r -f $HDFS_DIR                 # 先清，保证重复上传不翻倍
hdfs dfs -mkdir -p $HDFS_DIR
hdfs dfs -put ecommerce_events_20191001.csv $HDFS_DIR/
```

**新手错误 ⑤：直接 `put`。** 你的 ODS 是外部表指向一个目录，只要目录里多一个文件，Hive 就多读一份——**整表翻倍且不报任何错**。所以必须先删后传，并在上传后核对行数。

### 第 6 步：挂载分区

```sql
ALTER TABLE ods_user_behavior
  ADD IF NOT EXISTS PARTITION (dt='2019-10-01')
  LOCATION '/origin_data/ecommerce/mydb/ods_user_behavior/dt=2019-10-01';
```

注意用 `ADD IF NOT EXISTS`（重跑不报错）。`MSCK REPAIR TABLE` 也能自动发现分区，但它会全目录扫描、且严格要求路径写成 `dt=xxx`，分区多了之后性能很差，生产上更推荐显式 ADD。

**这里有个最容易踩的坑，我要单独讲：分区值从哪来？**

你现在 DWD 的写法是 `SUBSTRING(event_time,1,10)` —— **在 ODS 层这是错的**。ODS 的 `dt` 含义是“这批数据属于哪个业务日”，它应该由**调度系统传入**（`${bizdate}`），而不是从数据内容里算。原因：如果源数据里有一行时间是 NULL 或者是 `1970-01-01`，你就会得到一个 `dt=__HIVE_DEFAULT_PARTITION__` 的幽灵分区，或者把 10-01 的数据错放到 10-02。ODS 忠实反映“这一批是什么”，而不是“这一行属于哪天”——**按业务日期分区，不按数据内容分区**。

### 第 7 步：入库校验

上传之后、交给 DWD 之前，跑三条断言：

```sql
SELECT COUNT(1) FROM ods_user_behavior WHERE dt='2019-10-01';   -- 行数
SHOW PARTITIONS ods_user_behavior;                              -- 分区是否挂上
SELECT * FROM ods_user_behavior WHERE dt='2019-10-01' LIMIT 5;  -- 抽样看是否串行
```

### 第 8 步：留痕

建一张 `ods_etl_log`（或写进文档）记录：`dt / 源文件名 / 源文件行数 / HDFS 行数 / md5 / 入库时间 / 责任人`。这一步在个人项目里往往被省略，但它正是“数据血缘与溯源”的起点，简历上写“建立数据溯源机制”靠的就是它。

## 三、新手在 ODS 层最常犯的错（对照自查）

| #   | 错误                   | 后果                              | 正确做法                     |
| --- | -------------------- | ------------------------------- | ------------------------ |
| 1   | ODS 里做清洗过滤           | 无法回溯，出问题说不清                     | 只搬运，清洗放 DWD              |
| 2   | 用强类型（BIGINT/DECIMAL） | 一条脏数据炸掉整个任务                     | 全 STRING                 |
| 3   | 用内部表                 | `DROP` 即丢数据                     | `EXTERNAL`               |
| 4   | 多文件 + `skip.header`  | 静默丢行，且难发现                       | 源文件去表头                   |
| 5   | 数据放 `/tmp`           | 被清理、语义不清                        | `/origin_data/{业务域}/...` |
| 6   | 直接 `put` 不幂等         | 重复上传数据翻倍                        | 先 `rm -r` 再传 + 行数核对      |
| 7   | 分区值取自数据内容            | 产生 `__HIVE_DEFAULT_PARTITION__` | 由调度传 `${bizdate}`        |
| 8   | 不探查就建表               | 类型溢出、字符集错误                      | 先做 profiling             |
| 9   | Windows CRLF 不处理     | 字段末尾带 `\r`                      | 上传前 `dos2unix`           |
| 10  | 源数据用 gzip 压缩         | 不可切分，1.2G 只跑 1 个 map            | 用 bzip2 或提前拆分            |
| 11  | 分区粒度选小时              | 31 天 ×24 = 744 分区，小文件爆炸         | 按天；仅高吞吐场景才按小时            |

## 四、对照你的现状，需要改的 6 处

| 位置       | 现在                       | 要改成                                              |
| -------- | ------------------------ | ------------------------------------------------ |
| LOCATION | `/tmp/upload_ecommerce/` | `/origin_data/ecommerce/mydb/ods_user_behavior/` |
| 分区       | 无                        | `PARTITIONED BY (dt)` + 按天目录                     |
| dt 来源    | 无（DWD 里从 event_time 切）   | 由调度 `${bizdate}` 决定，ODS 阶段手动挂载                   |
| 审计字段     | 无                        | 可选加 `etl_time`，但不能动原始 9 列                        |
| 表命名      | `ods_user_behavior`      | 建议 `ods_user_behavior_di`（di=日增量）                |
| 表头       | 依赖 `skip.header`         | 源文件提前去表头，或维持单文件 + 该参数                            |

**保留不变**：外部表 ✅、全 STRING ✅、OpenCSVSerde ✅、不清洗不删行 ✅——这四条你一开始就做对了。

## 五、下一步

ODS 讲完了。下一步是 DWD，它的核心命题和 ODS 完全相反：**ODS 是“什么都别动”，DWD 是“什么都别放过”**——类型收敛、空值语义、去重、脏数据拦截、以及你最关心的**幂等分区写入**，全在这一层。
