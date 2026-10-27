# 数仓分层与 SQL 思维

> 这一章不背语法，只解决一个问题：**拿到一个指标需求，知道该在哪一层、用什么 SQL 形状去实现。**

---

## 0. 动笔前先回答三个问题

| 问题 | 为什么必须先答 | 答错的后果 |
|---|---|---|
| **一行代表什么？**（粒度） | 粒度决定主键、去重键、下游能不能直接加总 | 粒度混了，GMV、人数全部重复计算 |
| **口径是什么？**（分子/分母/过滤条件/时间边界） | 口径是业务契约，SQL 只是实现 | 同一个"转化率"两个部门算出两个数 |
| **数据怎么更新？**（全量覆盖/按天增量/全期重算） | 决定分区设计、SQL 写法和调度方式 | 补数把历史覆盖掉，或者每天重算全月 |

> 粒度、口径、更新方式，这三件事想清楚，SQL 只是打字。想不清楚，写出来的 SQL 一定要返工。

---

## 1. 分层的本质：每一层消灭一种不确定性

| 层 | 消灭的不确定性 | 对外承诺 |
|---|---|---|
| ODS | 源数据"以后还能不能看到原样" | 可回溯、可重放 |
| DWD | "一条行为到底怎么算一条" | 一条记录 = 一次已定义的业务行为 |
| DWS | "这个指标按什么口径算" | 同一主题、同一粒度、口径唯一 |
| ADS | "看板要的数长什么样" | 一表对一需求，拿来即用 |

分层的价值不是"看起来专业"，而是**出问题时能定位到某一层**：

- ODS 行数不对 → 上游投递/上传问题；
- DWD 行数少了 → 清洗逻辑误杀；
- DWS 三张表对不上 → 某张表的过滤条件漏了；
- ADS 数字不对 → 展示口径/截断/占比算错。

---

## 2. ODS：只做"原样保存"，不做任何判断

### 思维

ODS 的职责是**给源数据拍一张不会变的照片**。它不负责干净，只负责"以后能证明当时源数据长什么样"。

三条铁律：

1. 不清洗：不 WHERE、不 CASE、不转类型；
2. 不改结构：字段原样、顺序不变；
3. 不删数据：外部表 + 无过滤。

### 对应 SQL

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS ods_xxx_di (
    col1 STRING COMMENT '全部先按 STRING 接',
    col2 STRING
)
PARTITIONED BY (dt STRING COMMENT '业务日期，由调度传入')
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ("separatorChar"=",", "quoteChar"="\"", "escapeChar"="\\")
STORED AS TEXTFILE
LOCATION '/origin_data/.../ods_xxx_di/';   -- 指向表根，不是分区目录
```

关键点：

- **全 STRING**：源数据有空串、脏值、前导零。先定成数值类型，异常值会不可逆地变 NULL，排查时原始值就没了；
- **外部表**：`DROP TABLE` 只删元数据，HDFS 文件还在；
- **分区键不写在字段里**：`dt` 是"这批数据属于哪个业务日"，由调度传入，不从事件时间推导；
- **不设 `skip.header.line.count`**：多文件时它是"每个文件跳第一行"，很容易静默丢行；表头在拆分阶段就去掉。

### 幂等上传

外部表指向目录，目录里多一个文件 Hive 就多读一份，**不报错、数据翻倍**。所以上传必须：

```bash
hdfs dfs -rm -r -f "$PARTITION_DIR"
hdfs dfs -mkdir -p "$PARTITION_DIR"
hdfs dfs -put "$LOCAL_FILE" "$PARTITION_DIR/"
```

先删再传，是外部表唯一可靠的幂等手段。

---

## 3. DWD：把"一条行为"定义清楚

### 思维

DWD 要回答：**什么算一条干净的行为记录？**

清洗不是"把脏数据删掉"，而是"把语义定清楚"：

| 动作 | 目的 | 典型写法 |
|---|---|---|
| 类型收敛 | 让下游能算 | `CAST(NULLIF(TRIM(x),'') AS BIGINT)` |
| 空串转 NULL | 区分"没给"和"给了 0" | `NULLIF(TRIM(x),'')` |
| 去重 | 同一行为只留一条 | `ROW_NUMBER() OVER (PARTITION BY 业务主键 ORDER BY 确定性规则)` |
| 派生字段 | 方便下游按时间聚合 | `HOUR(event_time)` |
| **不做业务过滤** | 保证行数守恒、可审计 | 没有 `WHERE event_type='purchase'` |

### 去重键怎么设计

问自己：**哪几个字段组合起来，能唯一确定一次业务行为？**

本项目是「时间 + 用户 + 商品 + 行为类型 + 会话」五元组。

两个细节：

1. `ORDER BY` 不能只写分区键，否则并列时保留哪条不确定，**重跑结果会漂移**；
2. 要有明确的 tie-breaker，例如"信息更全的优先"：

```sql
ROW_NUMBER() OVER (
    PARTITION BY event_time, user_id, product_id, event_type, user_session
    ORDER BY IF(brand IS NOT NULL, 0, 1),
             IF(price IS NOT NULL, 0, 1)
) AS rn
```

### 为什么 DWD 不允许静默丢行

一旦加了 `WHERE` 过滤，ODS 与 DWD 行数就对不上，**清洗掉了什么、为什么掉，事后无从审计**。

正确做法：

- DWD 只做"定义级清洗"，不做"业务级过滤"；
- 业务过滤放到 DWS/ADS，并且记录 `drop_cnt`；
- 用"ODS 行数 − 去重条数 = DWD 行数"作为硬约束（源数据无重复时两者严格相等，差额必须能解释）；

### 写入方式

```sql
INSERT OVERWRITE TABLE dwd_xxx_di
PARTITION (dt = '${hivevar:bizdate}')   -- 静态分区：写给哪一天由调度决定
SELECT ...
FROM ods_xxx_di
WHERE dt = '${hivevar:bizdate}';        -- 分区裁剪，只读当天
```

静态分区的意义：**即使忘了写 WHERE，也只污染这一天，不会动其他分区。**

---

## 4. DWS：把业务口径固化成主题表

### 思维

DWS 不是"把明细再存一遍"，而是**按主题和粒度预聚合，并把口径写死**。

设计顺序：

1. 这个主题的分析对象是谁？（用户 / 商品 / 品类 / 渠道）
2. 粒度是什么？（对象 × 天，还是对象 × 天 × 品类）
3. 要看哪些指标？（次数、人数、金额、比率）
4. 哪些维度需要"当天快照"？（商品品牌、品类）

### 四种最常用的 SQL 形状

**① 条件聚合：一次扫描算多个指标**

```sql
SELECT user_id,
       SUM(IF(event_type='view',     1, 0)) AS view_cnt,
       SUM(IF(event_type='cart',     1, 0)) AS cart_cnt,
       SUM(IF(event_type='purchase', 1, 0)) AS pay_cnt,
       SUM(IF(event_type='purchase', price, 0)) AS gmv
FROM dwd_xxx_di
WHERE dt = '${bizdate}'
GROUP BY user_id;
```

比 `WHERE event_type='view'` 扫三遍便宜得多，而且四个指标天然同一批数据、口径一致。

**② 先打平到用户，再算人数（漏斗必用）**

```sql
SELECT COUNT(1) AS active_users,
       SUM(IF(view_cnt>0, 1, 0)) AS view_users,
       SUM(IF(view_cnt>0 AND cart_cnt>0 AND pay_cnt>0, 1, 0)) AS strict_users
FROM (SELECT user_id, ... FROM dwd_xxx_di GROUP BY user_id) t;
```

如果直接 `COUNT(DISTINCT CASE WHEN ...)`，各步骤人数是"各自去重"，没法保证同一批人；先按用户打平，**四个数才自洽**。

**③ 维度取当天快照：`MAX()` 会忽略 NULL**

```sql
MAX(category_code) AS category_code,  -- 当天任意一条带了品类就能取到；全空则 NULL
MAX(brand)         AS brand
```

为什么不用"全期最新值"：那会让历史报表**回溯变形**——商品今天换品牌，上个月的报表也跟着变。

为什么用 `MAX` 而不是 `FIRST_VALUE`：`MAX` 结果确定、可复现，重跑不会因 shuffle 顺序漂移。

**④ 小表广播/维表关联**

```sql
SELECT u.*, d.first_active_date,
       IF(d.first_active_date = u.dt, 1, 0) AS is_new_user
FROM user_day u
LEFT JOIN dim_user_first_active d ON u.user_id = d.user_id;
```

新老用户判断不要在 ADS 现算 `MIN(dt)`，要 join 已经固化好的维表（见第 6 节）。

### 比率怎么写

```sql
ROUND(pay_users / NULLIF(view_users, 0), 4)
```

- 分母为 0 用 `NULLIF` 变 NULL，**不要用 0 填充**——0 会被读成"转化率为零"，NULL 才是"无法计算"；
- 比率字段统一小数位，避免同一指标两种精度。

---

## 5. ADS：面向"看板问题"做一次算完

### 思维

ADS 的粒度由**看板需求**决定，不由数据模型决定。所以它允许冗余、允许截断、允许跨主题 join。

判断标准：**业务方拿到这张表，还需不需要再写 SQL？**

### 五种常用形状

**① 窗口函数做排名 + 占比**

```sql
SELECT product_id, gmv,
       ROW_NUMBER() OVER (ORDER BY gmv DESC, product_id) AS rn,
       gmv / SUM(gmv) OVER () AS gmv_share
FROM product_day
WHERE dt = '${bizdate}';
```

`SUM(...) OVER ()` 把"当日大盘"挂在每一行上，省掉一次自关联。

**② 排名截断**

```sql
... WHERE rn <= 50
```

先算排名再截断，不能先 `LIMIT 50` 再算占比——那样占比的分母就只剩 50 行了。

**③ 缺失维度保留成"未知"**

```sql
COALESCE(category_code, '未知品类') AS category_code
```

不能直接丢掉 NULL 分组，否则各品类金额加总 ≠ 大盘，对不上账。

**④ 层级维度下钻**

```sql
SPLIT(category_code, '\\.')[0] AS cat_level1
```

`category_code` 本身是 `a.b.c` 的层级结构，取第一段就能支持"一级品类"下钻，不必再建一张维表。

**⑤ 留存 / Cohort：自关联 + 精确天差**

```sql
COUNT(DISTINCT IF(DATEDIFF(a.dt, c.first_active_date) = 1, c.user_id, NULL))
```

口径是"第 N 天当天仍有行为"，不是"N 天内活跃过"。差一天，数就差很多。

观察窗口不足时：

```sql
IF(DATE_ADD(cohort_date, 30) <= max_dt, 计算结果, CAST(NULL AS BIGINT))
```

**宁可留 NULL，也不拿部分数据凑数。**

**⑥ 分层打标：能固定区间就别用等频**

RFM 的三种打分法就是三种思维：

| 分数 | 方法 | 为什么 |
|---|---|---|
| R | 固定天数区间 | 业务信号明确，跨月可比 |
| F | 固定次数区间 | 离散小整数，NTILE 会把并列值随机切桶 |
| M | NTILE 等频，且只对购买用户 | 金额长尾，等频合理；不排除未购买用户会挤爆第一桶 |

---

## 6. 维表：什么时候值得固化

判断标准：**这个属性是否跨天共享、是否计算昂贵、是否会被补数顺序影响。**

典型例子：用户首活日。

```sql
INSERT OVERWRITE TABLE dim_user_first_active
SELECT user_id, MIN(dt) AS first_active_date
FROM dwd_xxx_di
WHERE user_id IS NOT NULL
GROUP BY user_id;
```

不固化的两个问题：

1. 性能：每次 join 都要全表扫；
2. 正确性：倒序补数会算错——先跑 10-05 再跑 10-01，10-05 那天会把用户判成"新客"，等 10-01 跑完才发现错了。

维表不是"必须有的层"，**是为了解决具体问题才存在的**。

---

## 7. 增量与补数：为什么必须两套 SQL

| 场景 | 目标 | SQL 形状 | 分区 |
|---|---|---|---|
| 日常 T+1 | 单次执行成本最低 | `WHERE dt = '常量'` + 静态分区 | 只写一天 |
| 历史回填 | 总量成本最低 | `GROUP BY dt` + 动态分区 | 一次写多天 |

按天循环的问题：每天都要重新 shuffle 一遍维表、重新启停一次作业，**固定开销被重复支付 N 次**。

批量补数的写法：

```sql
INSERT OVERWRITE TABLE dws_xxx_di PARTITION (dt)
SELECT ..., dt          -- 动态分区列必须放最后一列
FROM dwd_xxx_di
GROUP BY ..., dt;
```

动态分区 `OVERWRITE` 的语义：**只覆盖本次 SELECT 实际产出的分区**，不会误删其他月份。

需要开的参数：

```sql
SET hive.exec.dynamic.partition=true;
SET hive.exec.dynamic.partition.mode=nonstrict;
SET hive.exec.max.dynamic.partitions=2000;
```

两套 SQL 的口径必须完全一致，并且用同一套校验证明结果相同——否则"补数和日常跑出两个数"是迟早的事。

---

## 8. 校验：每层留一个"跨层等式"

校验不是"跑完看看有没有报错"，而是**用另一条路径证明结果对**。

| 层 | 等式 | 证明什么 |
|---|---|---|
| ODS | 各分区行数 = 拆分清单 | 上传没丢没重 |
| DWD | DWD 行数 = ODS 行数 − 去重条数；主键唯一 | 清洗没误杀、去重没多删 |
| DWS | 用户表与商品表的 GMV、订单数逐日相等；漏斗表每天恰好 1 行 | 两个主题读的是同一批事实，漏斗粒度没写错 |
| ADS | 大盘 GMV = DWS GMV；品类合计 = 大盘 | 展示层没漏分组、没重复 |

三个容易写错的校验：

1. **拿单天结果去比全月**——比较边界要一致（按 ADS 已覆盖的日期比）；
2. **分区表数总天数**——增量跑完历史分区还在，"总天数 = 1"永远不成立；正确语义是"每个分区恰好 1 行"；
3. **只校验总量不校验分布**——总量对但某天为 0，一样是事故。

校验脚本要能返回非 0 退出码，调度系统才能捕获。

---

## 9. 需求来了，放哪层？

| 需求特征 | 放哪层 | 理由 |
|---|---|---|
| 只是把源文件接进来 | ODS | 不做加工 |
| 要"一条干净明细"、要可追溯 | DWD | 定义事实 |
| 某个主题的固定指标（用户日、商品日） | DWS | 口径固化、可复用 |
| 一张具体看板/报表 | ADS | 面向展示，允许冗余 |
| 跨主题、要排名/占比/分层 | ADS | 需要 join 和窗口 |
| 会被很多报表复用的稳定属性 | 维表 | 避免重复计算和口径漂移 |

一个反例：把"支付成功才计入"的过滤写在 DWD。这样 DWD 就不是"全部行为"，下游想看"加购未支付"就没了。**过滤是口径，口径属于 DWS/ADS。**

---

## 10. 反模式清单

| 反模式 | 后果 |
|---|---|
| ODS 里做类型转换/清洗 | 原始值不可回溯 |
| DWD 里 `WHERE` 过滤业务数据 | 行数不守恒，问题无法定位 |
| 在 ADS 直接查 DWD 明细 | 绕过 DWS 口径，指标漂移 |
| 用 `COUNT(DISTINCT)` 直接算漏斗各步 | 各步人群不是同一批，漏斗不自洽 |
| 先 `LIMIT` 再算占比 | 分母错 |
| 分区表用"总行数/总天数"做校验 | 增量场景必然误报 |
| 按天循环跑历史补数 | 固定开销 ×N，慢一个数量级 |
| 维表现算不固化 | 补数顺序一变结果就错 |
| 分母为 0 填 0 | 把"无法计算"误读成"为零" |

---

## 11. 面试怎么讲（三分钟版）

1. **为什么分层**：把清洗、聚合、口径拆开，每层只做一件事，出错能定位；
2. **ODS**：外部表 + 全 STRING + 按天分区，保证可回溯、可重放，上传先删再传保证幂等；
3. **DWD**：类型收敛、空串转 NULL、五元组去重、不做业务过滤，保证行数守恒；
4. **DWS**：按用户/商品/漏斗三个主题预聚合，条件聚合一次算多指标，维表固化首活日；
5. **ADS**：窗口排名、占比、Cohort 留存、RFM 分层，一表对一需求；
6. **工程化**：增量与补数两套 SQL、每层跨层校验、DolphinScheduler 串成 T+1 工作流。

---

## 12. 自测

1. 如果 ODS 就做成 ORC + 强类型，会丢失什么能力？
2. DWD 的去重键为什么不能只用 `user_id`？`ORDER BY` 不写确定性规则会怎样？
3. 为什么漏斗要先"按用户打平"再统计人数？
4. `MAX(brand)` 取当天快照，和"取全期最新品牌"各自的问题是什么？
5. 动态分区 `INSERT OVERWRITE` 会覆盖哪些分区？会不会误删其他月份？
6. 留存为什么不能用"N 天内活跃过"？窗口不足为什么置 NULL 而不是 0？
7. 分区表校验"每天 1 行"应该怎么写？为什么不能写 `COUNT(DISTINCT dt)=1`？
8. 一个"支付成功才计入"的过滤，应该放在哪一层？为什么？
