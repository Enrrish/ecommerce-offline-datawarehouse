# ADS 层性能诊断与优化方向

> 诊断对象：2026-10-27 09:20 那次全链路运行（四层全部成功）。
> 数据来源：DolphinScheduler 任务日志、YARN REST API、`sar` 历史采样、Hive CLI 日志、HDFS 文件统计。
> 所有数字都是这台三节点集群（3 × 4 核 / 5.8 GB）实测，不是经验值。
>
> **阅读顺序**：本文是**优化前的诊断**（基线 ADS 1330 s，瓶颈定位与优化方向都在这里）。
> 落地后的实测见 [`07_ADS_SQL优化方案.md`](07_ADS_SQL优化方案.md) 第 5 节（生产 1302 s → 1024 s），
> 换引擎的取舍见 [`08_MR与Spark引擎评估.md`](08_MR与Spark引擎评估.md)。

## 一、结论摘要

| 判断 | 结论 | 关键证据 |
|---|---|---|
| ADS 慢是否由内存不足引起 | **不是主因** | 运行期 CPU 空闲 83%~90%、iowait 0.2%、无 OOM、当日容器被内存杀 0 次 |
| 真正的瓶颈 | **MR 短作业数量过多**（59 个应用）+ Hive CLI 冷启动 + 重复扫描 | 平均每个作业 17.5 s、1.5 个 map、1 个 reduce，累计 CPU 仅 523 s |
| 内存问题是否存在 | 存在，但是**配置错配的隐患**，不是本次瓶颈 | YARN 按默认 8192 MB/节点 上报，物理只有 5851 MB；swap 已用 1 GB |
| 只改配置与 SQL 的收益 | **约 3~4 倍**（22 分 → 6~7 分），且不动组件 | 合并 INSERT、合并 CLI、去掉全表重复扫描 |

一句话：**这次慢不是"机器不够"，是"小任务太多、每次都要重新起一遍 MapReduce"。**

## 二、本次运行的时间账

| 节点 | 起止 | 耗时 | 占比 |
|---|---|---|---|
| ods_load | 09:20:32 → 09:21:16 | 44 s | 2.3% |
| dwd_etl | 09:21:16 → 09:23:45 | 149 s | 7.9% |
| dws_sum | 09:23:46 → 09:29:43 | 357 s | 19.0% |
| **ads_stat** | **09:29:44 → 09:51:54** | **1330 s（22 分 10 秒）** | **70.7%** |
| 全链路 | 09:20:32 → 09:51:54 | 1882 s（31 分 22 秒） | 100% |

ADS 内部再拆（依据任务日志的逐行时间戳）：

| 子阶段 | 耗时 | 占比 | MR 应用数 | MR 累计耗时 | 空档 |
|---|---|---|---|---|---|
| 7 次 `SHOW TABLES` 存在性检查 | 43 s | 3.2% | 0 | 0 s | 43 s（纯 CLI 启动） |
| 5 张日批表 `ads_etl_day.sql` | 278 s | 20.9% | 15 | 230 s | 48 s |
| 留存表全期重算 | 189 s | 14.2% | 6 | 158 s | 31 s |
| RFM 表全期重算 | 294 s | 22.1% | 11 | 256 s | 38 s |
| 校验 7 条规则 + 规模统计 | **526 s** | **39.6%** | 27 | 390 s | 136 s |
| 合计 | 1330 s | 100% | **59** | 1034 s | 296 s |

两个反直觉的点：

1. **校验比生产还贵**（526 s，占 ADS 的 40%）。校验本该是"顺手确认"，现在成了第二大开销。
2. **纯等待占 296 s**（22%）。这段时间没有跑任何作业，全花在 Hive CLI 启动、连 Metastore、编译 SQL 上。

## 三、内存到底是不是瓶颈

### 3.1 支持"不是内存问题"的证据

| 指标 | 实测值 | 含义 |
|---|---|---|
| CPU 空闲率（ADS 运行期，hadoop2） | 83.6% → 86.5% → 90.7% | 三个采样点都空闲，机器大部分时间在等 |
| `%iowait` | 0.15%（均值） | 不是磁盘瓶颈 |
| 负载 `ldavg-1` | 0.38 ~ 1.20（4 核） | 远未跑满 |
| 运行队列 `runq-sz` | 0 ~ 1 | 没有排队 |
| 容器因内存被杀（当日） | **0 次** | 无 OOMKilled |
| `dmesg` 中的 OOM killer | 0 条 | 内核没杀过进程 |
| 累计 CPU / 墙钟 | 523 s / 1330 s | 只相当于单核的 39%；按 12 核算利用率约 **3.3%** |
| 单作业读取量 | 38/57 个 Stage 读 **< 1 MB** | 作业小到几乎不读数据 |

CPU 空闲、IO 不忙、没有 OOM——三个条件同时成立，"内存不足导致慢"就不成立。
内存不足的典型表现是：容器被 kill 后重试、GC 时间占比高、swap 换入换出把 iowait 打满。这次一个都没有。

### 3.2 支持"内存配置确实有问题"的证据

| 指标 | 实测值 | 问题 |
|---|---|---|
| YARN 上报总内存 | 24576 MB（3 × 8192） | `yarn.nodemanager.resource.memory-mb` 未配置，用的默认 8192 |
| 物理内存 | 5851 MB × 3 | 每节点**超卖 40%** |
| YARN 上报 vcore | 24（3 × 8） | 实际每节点 4 核，超卖 2 倍 |
| swap 使用 | hadoop2 从 829 MB 涨到 1097 MB | 有换出 |
| `kswapd` 回收 | 200 ~ 2532 页/秒，`%vmeff` 83%~92% | 内核在持续回收，但强度不高 |

所以准确的说法是：**内存配置是错的（超卖），运行中也确实发生了轻度换页，但它没有成为这次运行的瓶颈。**
它会带来两个后果：① 并发稍高就会真的 OOM；② 换页带来的抖动会让作业耗时不可预测。这是"必须修"，但不是"这次慢的原因"。

### 3.3 怎么验证内存是不是瓶颈（下次照这个顺序看）

```bash
# 1. 运行窗口内的 CPU 空闲率与 iowait（<70% 空闲就说明不是等 CPU）
sar -u -f /var/log/sa/sa27 -s 09:20:00 -e 09:55:00

# 2. 换页强度：pgscank/pgsteal 上万、%vmeff 掉到 50% 以下才是 swap 抖动
sar -B -f /var/log/sa/sa27 -s 09:20:00 -e 09:55:00

# 3. 有没有容器被内存杀（比看 free 靠谱）
grep 'Killing container' /opt/hadoop/logs/hadoop-cy-nodemanager-*.log | grep "$(date +%F)" | wc -l

# 4. OOM killer
dmesg | grep -ci 'killed process'

# 5. 单个作业的真实资源画像（需要 JobHistoryServer）
curl -s 'http://hadoop3:19888/ws/v1/history/mapreduce/jobs/<jobid>/counters'
```

## 四、影响 ADS 性能的其他因素（按影响排序）

### 4.1 作业数量 × 固定开销（影响最大）

本次 ADS 一共提交 **59 个 MR 应用 / 57 个 Stage**，平均每个作业：

| 指标 | 平均值 |
|---|---|
| 墙钟耗时 | 17.5 s |
| map 数 | 1.5 个 |
| reduce 数 | 1 个 |
| 读取量 | 约 20 MB |

一个 MR 作业的最小成本是固定的：申请 AM 容器 → 起 MRAppMaster JVM → 申请 task 容器 → 起 task JVM → 跑 → 写 HDFS → 注销。数据只有 1 MB 时，这些固定动作照样要 10~15 s。
59 × 12 s ≈ **700 s**，这就是 1330 s 里最大的一块。

**验证方法**：`yarn application -list -appStates FINISHED` 数应用个数；或按本文附录的脚本按阶段统计"应用数 / 累计耗时 / 空档"。
**判断标准**：如果"平均每个作业耗时 > 10 s，但读取量 < 10 MB"，就是典型的开销主导型。

### 4.2 5 次重复扫描同一张表

`ads_etl_day.sql` 是 5 条独立 `INSERT`：

| 表 | 扫描的源表 |
|---|---|
| `ads_trade_overview_day` | `dws_user_action_day` |
| `ads_user_funnel_day` | `dws_user_funnel_day` + `dws_user_action_day` |
| `ads_product_rank_day` | `dws_product_action_day` |
| `ads_category_sales_day` | `dws_product_action_day` |
| `ads_brand_sales_day` | `dws_product_action_day` |

`dws_user_action_day` 被扫 2 次、`dws_product_action_day` 被扫 3 次，每次都要重新起一条作业链。
改成 `FROM ... INSERT ... INSERT ...` 的多路插入（multi-insert），一次扫描出 5 个结果，作业数能从 15 降到 6 左右。

**验证方法**：`EXPLAIN` 看有几个 Stage；或数同一张源表在日志里出现的 `HDFS Read` 次数。

### 4.3 15 次 Hive CLI 冷启动

`ads_load.sh` 里有 15 次独立的 `hive -e / -f` 调用（7 次表存在性检查 + 3 次生产 + 5 次校验）。
每次都要起一个 Hive CLI JVM、连一次 Metastore、解析一次配置。实测 7 次 `SHOW TABLES` 花了 **43 s**，平均 6 s/次。

**验证方法**：`time hive -e "show tables"`，单次 5~7 s 即为此类开销。
**解法**：把校验和生产合到一个 `.sql` 文件里用一次 `hive -f` 跑完；表存在性检查用一条 `SHOW TABLES` + `grep -c` 代替。

### 4.4 校验逻辑本身太重

7 条规则里，规则 1/2 要回扫 `dws_user_action_day`（644 万行）做跨层对账，规则 7 要扫全量 RFM 表（300 万用户）。
27 个应用 + 136 s 空档 = 526 s，占了 ADS 的四成。

**验证方法**：单独 `time bash ads_load.sh check`，再和 `hive -e` 单条规则对比。
**优化方向**：
- 跨层对账改成"只对当天分区"，别再全表 `JOIN DISTINCT dt`；
- 规则 5/6/7 只查当天或只查聚合后的小表；
- 把校验做成独立工作流并行跑，不阻塞主链路。

### 4.5 小文件 + split 合并导致并行度不足

| 表 | 目录数 | 文件数 | 总大小 | 单文件 |
|---|---|---|---|---|
| `dwd_user_behavior_di` | 31 | 31 | 460 MB | 15 MB |
| `dws_user_action_day` | 32 | 61 | 22 MB | 0.38 MB |
| `dws_product_action_day` | 32 | 61 | 6 MB | 0.10 MB |

Hive 默认的 `CombineHiveInputFormat` 会把小文件合并成最大 256 MB 的 split，结果读到 361 MB 数据时只起了 **2 个 map**（约 180 MB/map）。
3 台 4 核机器有 12 个核，却只用 2 个 map，剩下的核全在空转。

**验证方法**：`hive.log` 里 `Stage-Stage-x: Map: N Reduce: M`；`N` 明显小于 `数据量/128MB` 就是并行度不足。
**调参方向**：`mapreduce.input.fileinputformat.split.maxsize=134217728`、`hive.merge.smallfiles.avgsize=134217728`、`hive.merge.size.per.task=134217728`。

### 4.6 每个 Stage 只有 1 个 reducer

57 个 Stage 全部是 `Reduce: 1`。原因是 `hive.exec.reducers.bytes.per.reducer` 默认 256 MB，而单个作业的数据量普遍小于这个值。
数据小的时候 1 个 reducer 不算错，但每个 Stage 都要为这 1 个 reducer 付一次容器启动 + shuffle 落地，等于"每次都排队过同一个闸口"。

### 4.7 留存表与 RFM 表每天全期重算

这两张表在单天模式下也是全量重算：

- 留存表：31 个 cohort × 窗口函数，恒读全期 DWD；
- RFM 表：300 万用户 × `NTILE` 分位，恒读全期用户宽表。

单天调度本来只该动"今天"这一格，却每天重算整张表。这也是 ADS 比 DWD/DWS 更"重"的结构性原因。

**优化方向**：留存只重算最近 N 个 cohort（30 日窗口内），RFM 按用户增量更新或降到每周重算。

### 4.8 Hive 几乎没有调优配置

`hive-site.xml` 只有 **8 个 property**，全是 JDBC 连接和 Metastore 相关：

```
javax.jdo.option.ConnectionURL / DriverName / UserName / Password
hive.metastore.schema.verification
hive.metastore.event.db.notification.api.auth
hive.metastore.warehouse.dir
hive.serdes.using.metastore.for.schema
```

没有 `hive.execution.engine`、没有 `hive.exec.parallel`、没有 CBO/统计信息、没有 ORC 合并参数。
**所有执行行为都是 Hive 3.1.2 的默认值**。默认值面向"能跑通"，不面向"跑得快"。

### 4.9 调度是纯串行

四个节点严格串行，ADS 必须等 DWS 全部结束。ADS 内部 59 个作业也是一个接一个提交，`hive.exec.parallel` 默认 `false`。
整条链路 12 个核的利用率只有 3%，等于用一台机器在跑。

## 五、定位瓶颈的标准流程（10 分钟版）

| 步骤 | 看什么 | 命令 | 判据 |
|---|---|---|---|
| 1. 记账 | 每层/每子阶段耗时 | DS 任务日志的时间戳 | 找出占比 > 30% 的那一段 |
| 2. 三率 | CPU 空闲 / iowait / 内存 | `sar -u` `sar -B` `free` | 空闲 > 70% 且 iowait < 5% → 不是资源瓶颈 |
| 3. 作业粒度 | 应用数、平均耗时、map/reduce 数 | `yarn application -list`、`hive.log` 的 `Map: N Reduce: M` | 平均 < 30 s、map ≤ 2 → 开销主导 |
| 4. 数据量 | 每个 Stage 的 `HDFS Read` | `grep 'HDFS Read' hive.log` | 读 < 10 MB 却耗 15 s → 确认是固定成本 |
| 5. 对照实验 | 单条 SQL 单独跑 | 同样的 SQL 用 `hive -e` 跑一遍计时 | 单独跑和链路里差很多 → 调度/排队问题 |

本次就是按这个顺序走完的：第 2 步排除了内存，第 3、4 步锁定了"作业太小、数量太多"。

## 六、优化项优先级（按收益/风险排序）

> 原则：先动 SQL 与调用次数，不动组件、不改引擎。每项都标了"改哪里"和"预期省多少"。

### 第一优先级：调用次数与重复扫描（不改语义，风险最低）

| # | 改动 | 涉及文件 | 预期 |
|---|---|---|---|
| 1 | 表存在性检查 7 次 Hive CLI → 1 次 `SHOW TABLES` | `scripts/ads/ads_load.sh` | 省 ≈43 s |
| 2 | 单天模式把 `dt` 条件下推，不再 `JOIN (SELECT DISTINCT dt ...)` 回扫 DWS 644 万行 | `scripts/ads/ads_load.sh` | 每次校验省 1 次全表扫 |
| 3 | 规则 5/6/7 与各表规模合并成 1 次 `hive -e` | `scripts/ads/ads_load.sh` | 校验从 526 s 降到 1~2 个作业 |
| 4 | 商品类 3 条 `INSERT` 合并为 1 条 `UNION ALL`（**注意**：Hive 3.1 不支持 `FROM ... INSERT ... INSERT` 多路插入，已实测报错） | `scripts/ads/ads_etl_day.sql` | 少扫 2 遍源表 |
| 5 | 留存/RFM 只算需要的日期窗口，不做全期重算 | `scripts/ads/ads_retention.sql`、`ads_rfm.sql` | 各减 1~2 个 Stage |

### 第二优先级：作业粒度（要改 SQL 结构）

6. 所有 `INSERT` 显式写 `DISTRIBUTE BY` 或控制 reducer 数，避免"恒 1 reducer"把 20 MB 数据串行化；
7. 小文件合并：`hive.merge.mapfiles/mapredfiles` + `hive.merge.smallfiles.avgsize`，避免下一层输入碎成 0.38 MB/个；
8. 校验 SQL 只查当天分区，历史分区用一次性对账脚本单独跑。

### 第三优先级：可观测性（不改业务，改运维）

9. 启 JobHistoryServer（19888）+ ATS，拿到 counters，否则永远只能靠 `hive.log` 反推；
10. ADS 每阶段打点（`date +%s` 写日志），避免再靠肉眼拆时间账。

## 七、附录：本次实测原始数据

```
# 任务耗时（DS worker 日志）
09:20:32 ODS 开始 → 09:21:16 结束（44 s）
09:21:16 DWD 开始 → 09:23:45 结束（149 s）
09:23:46 DWS 开始 → 09:29:43 结束（357 s）
09:29:44 ADS 开始 → 09:51:54 结束（1330 s）

# 作业规模（YARN REST + hive.log）
ADS 窗口：59 个应用、57 个 Stage、87 个 map、58 个 reduce
累计 CPU：523 s；HDFS 读取合计：1180 MB；单 Stage 最大读取：361 MB
读取 < 1 MB 的 Stage：38 / 57
每个 Stage 的 reduce 数：恒为 1

# 资源（hadoop2，09:20–09:55）
CPU：%user 8.4，%system 4.5，%iowait 0.15，%idle 86.95
负载：ldavg-1 0.38 ~ 1.20（4 核），runq-sz 0~1
内存：%memused 50.9 → 82.2；swap 829 MB → 1097 MB
换页：pgscank 202 ~ 2672 页/秒，%vmeff 83% ~ 92%
容器内存 kill：0；dmesg OOM：0

# 配置现状
yarn-site.xml：仅 3 个 property，未设 memory-mb → 默认 8192 MB/节点
mapred-site.xml：仅 framework.name 与 classpath
hive-site.xml：仅 8 个 property（JDBC + Metastore），无任何执行参数

# 数据规模
dwd_user_behavior_di：31 分区 / 31 文件 / 460 MB
dws_user_action_day：32 目录 / 61 文件 / 22 MB（644 万行）
dim_user_first_active：300 万用户 / 5.8 MB
```
