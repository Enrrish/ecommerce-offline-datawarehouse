# ADS 层 SQL 优化方案（待执行）

> 基线：2026-10-27 09:20 全链路运行，ADS **1330 s**（占全链路 70.7%）。
> 前提：不动组件、不改引擎、不调集群配置 —— 只改 `scripts/ads/` 下的 SQL 与调用方式。
> 目标：ADS **1330 s → 600 s 上下**，全链路 31 min → 20 min 左右。

## 零、为什么改 SQL 就够了

诊断结论（[`docs/06`](06_ADS性能诊断与优化方向.md)）：ADS 慢不是数据量大，是**作业数太多、每个作业太小**。

- ADS 共 **59 个 MR 应用 / 57 个 Stage**，平均 17.5 s，1.5 个 map、1 个 reduce；
- 38/57 个 Stage 读取 **< 1 MB**，累计 CPU 只用了 523 s（12 核的 3%）；
- 单块耗时排序：**校验 526 s（40%）> RFM 294 s > 留存 189 s > 5 张日批表 278 s**。

也就是说，**把作业数砍下来，时间就下来了**，不需要换引擎。

## 一、总览：6 步，按执行顺序排

| 步 | 改造 | 涉及文件 | 预计耗时变化 | 风险 |
|---|---|---|---|---|
| 1 | 校验规则合并成 1~2 个作业 | `ads_load.sh` | 526 s → **100~140 s** | 低 |
| 2 | RFM 加时间窗口，不再全期重算 | `ads_rfm.sql` | 294 s → **80~110 s** | 中 |
| 3 | 留存只算 6 个目标分区 | `ads_retention.sql` | 189 s → **80~100 s** | 中 |
| 4 | 商品类 3 表用中间表，源表只扫 1 次 | `ads_etl_day.sql` + 新增 `ads_tmp` | 278 s → **170~200 s** | 中 |
| 5 | 用户类 2 表共用中间表 | `ads_etl_day.sql` | 再省 **20~30 s** | 中 |
| 6 | 三个 SQL 合并成一次 `hive -f`，补 reducer/小文件参数 | `ads_load.sh`、`ads_all.sql` | 省 **15~20 s** + 减少小文件 | 低 |

---

## 二、逐步说明

### 步骤 1：校验规则合并（收益最大、风险最低）

**目的**：当前 7 条规则拆成 27 个 MR 作业，光调度开销就吃掉 40% 的时间；而且跨层对账扫的是全期分区，明明只校验一天。

**涉及文件/字段**：`scripts/ads/ads_load.sh`

| 现状 | 改法 |
|---|---|
| 规则 1/2（行数守恒）用 `JOIN (SELECT DISTINCT dt FROM ads_trade_overview_day)` 回扫 | 全部加 `WHERE dt = '$MODE'`，只比当天 |
| 规则 4（金额守恒）`SUM(total_gmv)` 对全表 | 同上，`WHERE dt = '$MODE'` |
| 规则 7（分区覆盖）`SELECT COUNT(DISTINCT dt) FROM ...` 起一个作业 | 改 `SHOW PARTITIONS <table>`，纯 metastore 查询，**0 个 MR** |
| 4 条规则分 4 次 `hive -e` | 合成 1 条 `UNION ALL` SQL，一次提交、一个作业 |

实现要点：把 7 条规则写成一条大 SQL，每行输出 `规则编号, 异常数`，脚本用 `awk` 判断是否全 0：

```sql
SELECT '1' AS rule, COUNT(1) AS bad FROM (...) t WHERE ...
UNION ALL
SELECT '2', COUNT(1) FROM (...) t WHERE ...
```

**预期效果**：27 个作业 → **1~2 个**，526 s → **100~140 s**。

---

### 步骤 2：RFM 只算时间窗口（294 s 那块）

**目的**：R/F/M 的价值只取决于最近 90 天，现在每天都把 31 天全期重算一遍，而且 `R` 值只用 `max(dt)`，扫全表纯浪费。

**涉及文件/字段**：`scripts/ads/ads_rfm.sql`，源表 `dws_user_action_day`

| 指标 | 字段 | 改法 |
|---|---|---|
| R（最近一次消费） | `dt`, `user_id` | `WHERE dt BETWEEN date_sub('${hivevar:dt}', 90) AND '${hivevar:dt}'`，取 `max(dt)` |
| F（消费频次） | `pay_cnt` | 同窗口内 `SUM(pay_cnt)` |
| M（消费金额） | `pay_amount` | 同窗口内 `SUM(pay_amount)` |

三个指标在**同一次扫描**里用条件聚合算完（`SUM(IF(...))`），不要再拆成 3 个 Stage。

**预期效果**：扫描量降到 1/3，Stage 从 11 个降到 3~4 个，294 s → **80~110 s**。

**风险**：窗口外的老用户 R 值会变成 NULL —— 需要确认口径：RFM 表只保留"窗口内有行为的用户"，还是全量用户打标。**建议保留全量，窗口外记 `R=999`**，与现有校验规则 6 对齐。

---

### 步骤 3：留存只算 6 个目标分区

**目的**：留存要的是 `dt` 与 `dt+1/3/7/15/30` 六个 cohort 的对照，现在用 `dt >= ...` 范围扫，把无关分区也读进来了。

**涉及文件/字段**：`scripts/ads/ads_retention.sql`，源表 `dws_user_action_day`（`dt`, `user_id`）

改法：把范围条件换成枚举

```sql
WHERE dt IN ('${hivevar:dt}',
             date_add('${hivevar:dt}', 1),
             date_add('${hivevar:dt}', 3),
             date_add('${hivevar:dt}', 7),
             date_add('${hivevar:dt}', 15),
             date_add('${hivevar:dt}', 30))
```

分区裁剪后每个 Stage 只读 6 个分区（约 6 × 20 MB），而不是 31 个。

**预期效果**：189 s → **80~100 s**。

---

### 步骤 4：商品类 3 张表共用一张中间表

**目的**：`ads_category_sales_day`、`ads_product_rank_day`、`ads_brand_sales_day` 三条 `INSERT` 都从 `dws_product_action_day` 聚合，**同一份数据扫了 3 遍**。

**涉及文件**：`scripts/ads/ads_etl_day.sql`，新增 `ads_tmp_product_agg_day`

**为什么不用多路插入**：Hive 3.1 的 `FROM ... INSERT ... INSERT ...` 要求所有分支共用同一个 `FROM`，而三个分支的粒度和窗口口径不同，硬合并只能靠 `UNION ALL + tag`，反而更慢（已实测报错 `missing EOF at 'FROM'`，见文件头注释）。

改法：先把三个粒度需要的**最细粒度**算出来，落一张小表：

```sql
-- 新增（一次性 DDL）
CREATE TABLE IF NOT EXISTS ads_tmp_product_agg_day (
    dt STRING, category_id STRING, brand_id STRING, product_id STRING,
    pv BIGINT, uv BIGINT, cart_cnt BIGINT, order_cnt BIGINT,
    pay_cnt BIGINT, pay_amount DECIMAL(18,2)
) PARTITIONED BY (dt) STORED AS ORC;

-- 一次扫描
INSERT OVERWRITE TABLE ads_tmp_product_agg_day PARTITION (dt='${hivevar:dt}')
SELECT '${hivevar:dt}', category_id, brand_id, product_id,
       SUM(pv), COUNT(DISTINCT user_id), SUM(cart_cnt), SUM(order_cnt),
       SUM(pay_cnt), SUM(pay_amount)
FROM dws_product_action_day
WHERE dt = '${hivevar:dt}'
GROUP BY category_id, brand_id, product_id;
```

然后三条 `INSERT` 改成从 `ads_tmp_product_agg_day` 聚合（几千行，秒级）。

**字段影响**：`ads_tmp_product_agg_day` 是新增表，需同步 `ads_ddl.sql`；不影响现有 7 张 ADS 表结构。

**预期效果**：源表 3 次扫描 → **1 次**，278 s → **170~200 s**，少 2 个 MR 作业。

---

### 步骤 5：用户类 2 张表共用中间表

**目的**：`ads_trade_overview_day`（大盘）与 `ads_user_funnel_day`（漏斗）都从 `dws_user_action_day` 出，扫 2 遍。

**涉及文件**：`scripts/ads/ads_etl_day.sql`，源表字段 `dt, user_id, pv, cart_cnt, order_cnt, pay_cnt, pay_amount`

改法同上：一张 `ads_tmp_user_agg_day`（按 `dt, user_id` 粒度），两张表从它出。
大盘要的是全站汇总（`SUM`），漏斗要的是人数去重（`COUNT(DISTINCT user_id)`）——**用户粒度的小表两种都能算**，正好复用。

**预期效果**：再省 1 个作业，**20~30 s**。

---

### 步骤 6：合并 CLI 调用 + 补两个参数

**目的**：现在 `ads_load.sh` 分别调 `ads_etl_day.sql`、`ads_retention.sql`、`ads_rfm.sql`，**3 次 JVM 冷启动 + 3 次 Metastore 连接**，每次约 6 s。

**涉及文件**：`scripts/ads/ads_load.sh`，新增 `scripts/ads/ads_all.sql`

改法：

1. `ads_all.sql` 里按顺序写三个 `source`（或直接 cat 三个文件），`ads_load.sh` 改成一次 `hive -f ads_all.sql`；
2. 文件头补两条参数（**写在 SQL 里，不写 hive-site.xml**）：

```sql
SET hive.exec.reducers.bytes.per.reducer=134217728;   -- 现在恒 1 reducer，20MB 也串行
SET hive.merge.mapfiles=true;
SET hive.merge.mapredfiles=true;
SET hive.merge.smallfiles.avgsize=33554432;           -- 合并 32MB 以下小文件
```

**预期效果**：省 15~20 s 冷启动；下游 DWS/ADS 输入不再碎成 0.38 MB/个，split 更合理。

---

## 三、执行与验收

**执行顺序**：1 → 2 → 3 → 6 → 4 → 5（先把收益大、风险低的做掉，中间表放最后）。

**每步的验收方式**：

| 检查项 | 方法 | 通过标准 |
|---|---|---|
| 数据正确 | 单天 `2019-10-02` 跑一遍，比对改前改后 7 张表的 `COUNT(1)`、`SUM(total_gmv)` | 数字完全一致 |
| 作业数下降 | `yarn application -list -appTypes MAPREDUCE` 或 `hive.log` 里 `Stage-Stage-N` 计数 | 每步都有下降 |
| 耗时不退化 | `ads_load.sh 2019-10-02` 前后对照 | 单步不慢于改前 |
| 无小文件恶化 | `hdfs dfs -count /user/hive/warehouse/mydb.db/ads_xxx/dt=...` | 文件数不增加 |

**回滚**：每条 SQL 单独 commit，出问题 `git revert <sha>` 即可；中间表是新增对象，删表不影响现有链路。

## 四、预期总账

| 阶段 | 现状 | 改造后 |
|---|---|---|
| 表存在性检查 | 43 s（已修，1 次 CLI） | ~6 s |
| 5 张日批表 | 278 s | 170~200 s |
| 留存 | 189 s | 80~100 s |
| RFM | 294 s | 80~110 s |
| 校验 | 526 s | 100~140 s |
| **ADS 合计** | **1330 s** | **约 450~560 s** |
| 全链路 | 31 min | 约 18~20 min |

保守估计 **2~2.5 倍**，且不引入任何组件风险。

## 五、实施结果（2026-10-28 实测）

### 5.1 实际落地的改动

| # | 改动 | 文件 | 状态 |
|---|---|---|---|
| 1 | 校验 10 条语句 / 27 个 MR → 6 条，且每条只扫一遍目标表；重复日期检查单天模式直接跳过 | `ads_load.sh` | ✅ |
| 2 | 元数据改走 `SHOW TABLES` / `SHOW PARTITIONS`（纯 metastore，0 个 MR），顺带拿到数据起止日期 | `ads_load.sh` | ✅ |
| 3 | 3 个 SQL 合并成 1 次 `hive -f`（省 2 次 JVM 冷启动 + Metastore 连接） | `ads_load.sh` | ✅ |
| 4 | 留存 5 个去重计数 `COUNT(DISTINCT IF(...))` → `SUM(IF(...))`（源表已按 user_id,dt 唯一，实测 6444006=6444006） | `ads_retention.sql` | ✅ |
| 5 | 砍掉留存 SQL 里冗余的 `SELECT DISTINCT user_id, dt` 右表包装（省一次 644 万行 shuffle） | `ads_retention.sql` | ✅ |
| 6 | 砍掉留存/RFM 里的 `MIN(dt)/MAX(dt)` 全表扫描，日期由 shell 从分区清单取好后 hivevar 传入 | `ads_load.sh` + 两个 SQL | ✅ |

### 5.2 设计阶段否决的改动（重要）

| 原计划 | 否决原因 |
|---|---|
| 步骤 2：RFM 只算最近 90 天 | RFM 的口径是**全期快照**（frequency/monetary 都是累计值），砍窗口会改变业务语义；且本数据集只有 31 天，90 天窗口是空操作 |
| 步骤 3 原案：留存按 `dt IN (...)` 枚举分区 | 实际做的是更彻底的等价改写：去掉 DISTINCT 包装 + 日期下推，效果相同且不碰口径 |
| 步骤 4/5：商品类/用户类共用中间表 | **会变慢**。本项目瓶颈是作业数（每作业 ≈17.5 s 固定开销），单天商品类源分区仅 ~13 MB，3 次扫描的 I/O ≈ 6 s；中间表方案 = 1 扫 + 1 写 + 3 读 = **4 个作业**，比现状 3 个还多一个。多路插入语法在 Hive 3.1 不可行（INSERT 分支内不能带 FROM，且榜单分支需要窗口后过滤，必须子查询），UNION+tag 反而扫三遍 |
| `hive.exec.parallel=true` | docs/03 第 3 条记录过本集群偶发 ConcurrentModificationException，保持 false |

### 5.3 实测耗时（单天 2019-10-02，集群无其他负载）

| 阶段 | 基线（改前） | 改后 | 变化 |
|---|---|---|---|
| 合并段（日批+留存+RFM，1 次 hive -f） | 827 s（322+197+308 三次调用） | **640 s** | −187 s |
| 校验（规则 1-4：144 s；规则 5-7：236 s） | 558 s | **380 s** | −178 s |
| RFM 分层分布打印 | （含在校验内） | 42 s | — |
| **ADS 单天合计** | **1385 s** | **≈1062 s** | **−323 s（−23%）** |

### 5.4 正确性验证

数据指纹法：对 7 张表按行聚合取 `MD5(CONCAT_WS(...))`（榜单类先 `SORT_ARRAY(COLLECT_LIST(...))` 消除顺序影响），改前采一次、改后各采一次比对。

- 第一轮（校验合并/留存 SUM(IF)/日期下推部署后）：**8 项指纹与基线完全一致**
- 第二轮（砍掉 DISTINCT 包装后完整重跑）：**7 项一致，retention 一项不同——深挖后确认是旧 SQL 算错了，新结果才是对的**（详见 5.6）

### 5.6 意外收获：修掉了一个留存人数静默少算一半的 bug

第二轮指纹比对发现 retention 表 MD5 变了。逐层排查（每步都有独立证据）：

1. 源表唯一性复核：`COUNT(1) = COUNT(DISTINCT concat(user_id,'|',dt)) = 6444006`，排除重复行；
2. 真值裁决：cohort 2019-10-01 次日留存，用「分区过滤 + join + COUNT(1)」和「+ COUNT(DISTINCT)」两种独立写法都算出 **31919**，当前表（新 SQL 写入）= 31919，旧 SQL = **15945（少一半）**；
3. 子查询隔离：旧 SQL 的 `SELECT DISTINCT user_id, dt` 单独跑结果正确 → 问题不在子查询；
4. 决定性实验：旧 SQL + `SET hive.optimize.countdistinct=false` → **31919，正确**。

**根因**：`hive.optimize.countdistinct=true`（Hive 3 默认开启）对「GROUP BY + COUNT(DISTINCT) 混合普通聚合（SUM(IF(...))）」的两阶段改写会把普通聚合算错。这是历史遗留 bug：基线留存数据从第一次跑就是少的，且从未报错。新 SQL 用 `SUM(IF(...))` 计数、不含 `COUNT(DISTINCT)` 混用，天然绕开该改写。完整案例见 `docs/03` 第 16 条。

**对账结论**：新 SQL 的留存数据 = 真值；其余 6 张表指纹与基线一致（未受影响）。

### 5.5 与预期目标的差距说明

预期 450~560 s 没有达到（实际 ≈1062 s），差在哪：

1. 预期表里"5 张日批表 170~200 s"低估了——日批 5 张表含窗口函数的 INSERT 各自是独立作业，单天模式下作业固定开销（每次 ≈17.5 s）就是地板，中间表方案（否决）本是这 100 s 的来源；
2. RFM 保持全期口径（正确性优先），308 s 基本没动，它的省法只剩"换引擎"（见 docs/08）；
3. 校验段还有约 100 s 空间（规则 5-7 的 7 表 UNION COUNT 仍起 2~3 个作业），属于下一轮。

**结论：0 组件风险拿到 −23%（4.3 分钟），剩余空间在 SQL 结构（多语句合成）与引擎层，均已另行评估。**
