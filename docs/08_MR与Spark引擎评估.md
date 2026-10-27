# MR 与 Spark 执行引擎评估

> **结论：当前场景换 Spark 不会带来"明显"提速，不建议现在换。**
> 理由一句话：全库 **501 MB**、ADS 阶段 CPU 利用率 **3.3%**、59 个作业平均 **1.5 个 map**。瓶颈是"作业太多、每个太小"，不是"MR 每行处理太慢"。同样的收益，改 SQL 就能拿到，且不引入新组件。
>
> 数据来源：2026-10-27 09:20 全链路运行记录（`docs/06`）+ 2026-10-27 16:30 HDFS / YARN / `free` 实测。

## 一、四个问题的直接回答

| 问题 | 回答 |
|---|---|
| MR 执行器本身效率低吗？ | 单行吞吐不低，**作业粒度极低**。57 个 Stage 里 38 个读取 < 1 MB，平均 1.5 map / 1 reduce，一个作业真正干活的时间不到 1/3 |
| 换 Spark 会明显提速吗？ | ADS 约 **−30%**（1330 → 850~950 s），全链路 −20%。**低于只改 SQL 的 −55%**，谈不上"明显" |
| 划算吗？ | 不划算。本机 `/opt` 里是 **Spark 3.1.3**，而 Hive 3.1.2 的 `hive-spark-client` 只认 **Spark 2.4.5**（2020 年 EOL），要另装一套；收益又与已排期的 SQL 改造高度重叠 |
| 什么时候该换？ | 单天数据 > 5 GB、或作业数 < 10 但每个 > 1 GB、或需要多轮复用/迭代（见第五节阈值表） |

## 二、底数：这个项目到底有多大

### 2.1 仓库体量（HDFS 实测）

| 表 | 逻辑大小 | 说明 |
|---|---|---|
| `dwd_user_behavior_di` | **459.8 MB** | 31 个分区，**单分区 13.3 MB / 单文件** |
| `dws_user_action_day` | 21.9 MB | 644 万行 |
| `ads_user_value_rfm` | 6.9 MB | |
| `dws_product_action_day` | 6.2 MB | |
| `dim_user_first_active` | 5.8 MB | 维表 |
| 其余 5 张 ADS 表 | 30 ~ 140 KB | 各一行/几十行 |
| **全库合计** | **501 MB** | 副本 2 → 物理 1.0 GB |

也就是说，除 DWD 那张宽表，**没有任何一张表超过 25 MB**，全库装得进一台机器的内存。

### 2.2 时间账（沿用 `docs/06`）

| 阶段 | 耗时 | 占比 |
|---|---|---|
| ODS | 44 s | 2.3% |
| DWD | 149 s | 7.9% |
| DWS | 357 s | 19.0% |
| **ADS** | **1330 s** | **70.7%** |
| 全链路 | 1882 s | 100% |

ADS 内部：59 个 MR 应用，应用内累计 1034 s，**纯等待 296 s**（CLI 冷启动 + 连 Metastore + 编译 SQL）。
59 × 约 12 s 的固定开销 ≈ **700 s**，占 ADS 的一半以上。

## 三、五条判断依据

### 3.1 数据规模落在 Spark 的"不经济区"

Spark 相对 MR 的收益来自三处：低任务启动开销、Stage 间不落盘、内存缓存复用。三处都有**最低数据量门槛**：

- 单任务处理 100 KB 还是 10 GB，任务启动开销都是固定的零点几秒 → **数据越小，省下的绝对时间越少**；
- 不落盘只在多 Stage 链路里才省得出来，本项目单个 `INSERT` 最多 3~4 个 Stage，中间结果 20 MB 量级，落一次盘 2~3 s；
- 缓存要跨语句复用才有意义，本项目每条 SQL 都是"扫一遍、聚合、写出"，没有复用点。

**结论**：501 MB 的总量，Spark 的三大优势全部踩在门槛以下。业界经验值是单作业 GB 级、总量 TB 级才明显，这里差 1~2 个数量级。

### 3.2 瓶颈在"作业数 × 固定开销"，不在单行处理速度

| 证据 | 数值 | 说明 |
|---|---|---|
| 累计 CPU | 523 s / 1330 s | 折合 12 核的 **3.3%** |
| 平均每作业读取量 | 约 20 MB | |
| 读取 < 1 MB 的 Stage | 38 / 57 | 66% 的 Stage 几乎不读数据 |
| 平均 map / reduce 数 | 1.5 / 1 | 并行度完全没用起来 |

CPU 只用了 3.3%，说明**不是算得慢，是在等**。等的是 AM 申请容器、MRAppMaster 起 JVM、task JVM 起停、HDFS 落盘、作业注销。

换 Spark 能把每个作业的这段从 10~15 s 压到 1~3 s，**但压不到 0**。59 个作业的 700 s 顶多变成 150~200 s，省下约 500 s —— 这就是 Spark 在这个项目里的全部天花板。

### 3.3 任务类型：没有 Spark 的用武之地

| 特征 | 本项目 | Spark 是否受益 |
|---|---|---|
| 迭代计算（机器学习、图） | 无 | 否 |
| 跨语句复用同一份数据 | 无（每条 SQL 独立扫） | 否（Hive-on-Spark 不会自动 cache） |
| 大 shuffle（join 大表） | 最大 shuffle 21.9 MB | 否 |
| 复杂多 Stage DAG | 单条 INSERT 最多 3~4 Stage | 轻微 |
| 交互式探索 | 无（调度器定时跑） | 否 |

唯一算得上 Spark 主场的是 **DWD 那张 460 MB 宽表的扫描 + 重写**（149 s），Spark 大概能到 90~110 s，**省 40~60 s，占全链路 3%**。

### 3.4 集群资源：Spark 的常驻模型在这里是劣势

| 节点 | 物理内存 | 已用 | 可用 | Swap 已用 | vCPU |
|---|---|---|---|---|---|
| hadoop1（RM/NM/MySQL/ZK/DS/Metastore） | 5851 MB | 3338 MB | 2210 MB | **1732 MB** | 4 |
| hadoop2 | 5851 MB | 2046 MB | 3499 MB | **1018 MB** | 4 |
| hadoop3 | 5851 MB | 1724 MB | 3829 MB | **827 MB** | 4 |

三台机器 swap 全部在用（合计 3.5 GB），说明内存**本来就紧**。

- **MR 的容器是短命的**：跑完即释放，两个作业之间内存归零；当前 8192 MB/节点的虚报让 MR 能同时起 8 个 1 GB 容器（代价是可能换页）。
- **Spark 的执行器是常驻的**：driver 1 GB + 每节点 1 个 executor（1 GB heap + 384 MB overhead）≈ **全程占住 5 GB**，与 MySQL、ZK、DS、Metastore 硬碰硬。
- 单 executor 可用堆约 700 MB，而 DWD 单分区 13.3 MB 尚可，一旦排序/聚合溢出就落磁盘 —— **"内存计算"这个卖点在这个配置下直接失效**。

结论：**5.8 GB 的机器养不起 Spark 的常驻模型**，要么压缩到 `executor-memory=512m`（GC 压力大），要么频繁被 YARN 杀容器。

### 3.5 迁移不是改一行配置

Hive 3.1.2 的 `hive/lib` 里确实有 `hive-spark-client-3.1.2.jar` 和 `spark-core_2.11-2.4.5.jar` 等 8 个 jar，但**缺 `spark-sql` / `spark-catalyst` / `spark-hive`** —— 它需要外挂一个完整的 **Spark 2.4.x** `SPARK_HOME`。

而机器上装的是 `/opt/spark-3.1.3-bin-hadoop3.2`。**Spark 3.x 与 Hive 3.1.2 的 spark client 不兼容**（Hive 4 才支持 Spark 3），所以：

- 走 `hive.execution.engine=spark`：须另装 Spark 2.4.5（EOL 版本，tar 包 230 MB），再调 `spark.master=yarn`、`spark.executor.memory`、`spark.yarn.queue` 等约 10 项，且 Hive 3.1.2 + Spark 2.4 有已知 bug。**风险和上次 Tez 同级**。
- 走 `spark-sql 3.1.3` 重写：还要解决 metastore 兼容（`spark.sql.hive.metastore.version=3.1.2` + `jars=path` 指向 `/opt/hive/lib`），并把 4 层 SQL、Shell、DolphinScheduler 任务全部改写。**工程量接近重做项目**。

## 四、三种方案的收益对比

| 方案 | ADS 预估 | 全链路预估 | 相对现状 | 增量投入 | 风险 |
|---|---|---|---|---|---|
| 现状（MR + 现有 SQL） | 1330 s | 1882 s | — | — | — |
| **只换 Spark**（SQL 不动） | 850~950 s | 1350~1500 s | ADS −29~36%，全链路 −20~28% | 装 Spark 2.4.5 + 10 项配置 + 压测 | 高 |
| **只改 SQL**（`docs/07`） | ~600 s | ~1150 s | ADS −55%，全链路 −39% | 6 个文件，1 天 | 低 |
| **SQL + Spark** | 450~520 s | 1000~1070 s | ADS −61~66%，全链路 −43~47% | 前两项之和 | 高 |

关键在最后两列的对比：

- Spark 单独上，省 380~530 s，**不如改 SQL 省的 730 s**；
- SQL 改完再上 Spark，只再多省 **80~150 s**，占全链路 4~8%（1.5~2.5 分钟），却要背一个新组件的运维成本。

**原因是两者攻击的是同一块时间**：作业固定开销。SQL 改造把 59 个作业合并到 20 个左右，Spark 能省的那部分已经被吃掉大半。

还有一块 **296 s 的纯等待**（Hive CLI 冷启动 15 次 × 6 s + 编译），**任何引擎都修不了**，只能靠合并 CLI 调用（`docs/07` 步骤 6）。

## 五、什么条件下才该换 Spark

满足任意两条即可重新评估：

| 条件 | 当前值 | 阈值 |
|---|---|---|
| 单天最大分区 | 13.3 MB | > 5 GB |
| 全库体量 | 501 MB | > 1 TB |
| 单作业平均处理量 | 20 MB | > 1 GB |
| ADS 作业数 | 59 | < 15 |
| 是否有跨语句复用 / 迭代 | 无 | 有 |
| 单节点内存 | 5.8 GB | > 32 GB |

反过来说：**如果哪天数据涨到单天 5 GB 以上，Spark 的收益会立刻变得显著**，那时换是对的。现在不是。

## 六、若确定要上 Spark：调优方向与优先级

按"不做就白上"到"锦上添花"排序，参数值已按 3 节点 × 4 核 × 5.8 GB 折算。

### P0（不做等于白换）

| # | 项 | 取值 | 为什么 |
|---|---|---|---|
| 1 | `spark.sql.shuffle.partitions` | 200 → **8** | 默认 200 会让 21.9 MB 的 shuffle 变成 200 个 100 KB 任务，**比 MR 的 1 个 reducer 还慢**；8 个任务每个约 2.7 MB 刚好 |
| 2 | 会话复用 | 一个 `spark-sql -f all.sql` 跑完 | 每次启动 SparkContext 要 30~45 s；3 个文件 = 2 分钟白扔 |
| 3 | 执行器规格 | `--executor-cores 2 --executor-memory 1g --conf spark.executor.memoryOverhead=384 --num-executors 3` | 每节点 1 个；默认 5 core/executor 在 4 核机器上会互相抢 |
| 4 | 动态分配 | `spark.dynamicAllocation.enabled=true`，min=1 / max=4 | 内存紧，必须能缩，否则空闲 executor 一直占着 |

### P1（有实打实收益）

| # | 项 | 取值 | 收益 |
|---|---|---|---|
| 5 | 广播维表 | `spark.sql.autoBroadcastJoinThreshold=10m` | `dim_user_first_active` 5.8 MB 可广播，维表关联免 shuffle。这是 Spark 相对 MR 唯一稳赢的点（MR 只能 map-side join） |
| 6 | 写前合并分区 | `repartition(n)` / `coalesce(n)`，n 按输出 128 MB/个定 | 现在 ADS 表里有 30 KB 级的文件，Spark 默认会更碎 |
| 7 | ORC 读优化 | `spark.sql.orc.impl=native`、`spark.sql.orc.enableVectorizedReader=true` | 全库都是 ORC（见 `ads_ddl.sql` / `dwd_ddl.sql`），向量化读能省 20~30% 扫描时间 |
| 8 | AQE（**仅 Spark 3.x**） | `spark.sql.adaptive.enabled=true` + `coalescePartitions` + `skewJoin` | 自动合并小分区；Hive-on-Spark 2.4 **用不上**，只有走 `spark-sql 3.1.3` 才行 |
| 9 | 裁剪核对 | `EXPLAIN EXTENDED` 确认 `PartitionFilters` 与 `ReadSchema` | 分区/列裁剪没生效，前面全白调 |

### P2（结构性优化）

| # | 项 | 说明 |
|---|---|---|
| 10 | `CACHE TABLE` 复用同源表 | 商品类 3 表、用户类 2 表同源；但用中间表（`docs/07` 步骤 4/5）更简单、可持久化、失败可重跑，**优先中间表** |
| 11 | Kryo 序列化 | `spark.serializer=KryoSerializer`，shuffle 量小时收益有限 |
| 12 | 压测期不要开 `hive.exec.parallel=true` | 本集群已记录 `ConcurrentModificationException`（`docs/03` 第 3 条），两个并行机制叠加只会放大问题 |

## 七、建议的验证路径（不动生产，2 小时）

不必先装 Spark 2.4.5。用机器上现成的 **Spark 3.1.3** 做一次最小对照：

1. 挑 ADS 里最贵的一段——**校验（27 个作业 / 526 s）**；
2. 用 `spark-sql` 重写其中规则 1/2/4 的 `UNION ALL` 版本，跑同一天 `2019-10-02`；
3. 对照两件事：**结果必须逐行一致**、**耗时**。

判定标准：

- Spark 版 < 60 s 且结果一致 → 值得继续投入，再考虑 Hive-on-Spark 全量迁移；
- Spark 版 100 s 以上 → 直接放弃，说明瓶颈确实不在引擎。

前置坑：Spark 3.1.3 默认按 Hive 2.3.7 读 metastore，必须加

```bash
--conf spark.sql.hive.metastore.version=3.1.2 \
--conf spark.sql.hive.metastore.jars=path \
--conf spark.sql.hive.metastore.jars.path=file:///opt/hive/lib/*
```

否则读 ORC 表的分区元数据可能出错。

## 八、附录：本文数据的测量命令

```bash
# 表体量（逻辑大小 / 物理占用）
hdfs dfs -du -h /user/hive/warehouse/mydb.db | sort -k1 -hr
hdfs dfs -du -s -h /user/hive/warehouse/mydb.db

# 单分区文件数（判断小文件）
hdfs dfs -ls /user/hive/warehouse/mydb.db/dwd_user_behavior_di/dt=2019-10-01

# 物理内存与 swap（判断能不能养 Spark executor）
free -m

# 作业数与平均耗时
yarn application -list -appStates FINISHED | grep -c application_
```

## 九、一句话总结

**这个项目的 MR 慢，不是"引擎不行"，是"59 个作业各干 1 MB 的活"。** 换 Spark 只是把每个作业的固定开销从 12 s 降到 3 s，省不出数量级；把作业合并、把重复扫描去掉，才是对症的药。先把 `docs/07` 的 6 步做完（目标 1330 → 600 s），再决定要不要为最后那 80~150 s 背一个新组件。
