# Tez 0.10.2 部署手册（Hive 3.1.2 + Hadoop 3.1.3 三节点）

> 环境：hadoop1/2/3（3 × 4 核 / 5.8 GB），JDK 1.8.0_171，Hadoop 3.1.3，Hive 3.1.2。
> 本文记录的是**实际执行过的每一步**，包括三处真实报错和最终结论，不是照抄官网的理想流程。
> 状态：**组件部署完成、AM 能起来，但 Hive CLI 的 Tez 会话握手没通** —— 原因与证据见第六节。

## 一、先回答两个问题

### 1. Tez 0.10.2 能不能用？

**能装上、能起 AM，但不能直接拿 Hive 跑。** 分三层看：

| 层次 | 结论 | 证据 |
|---|---|---|
| 包本身 | 可用 | 72 MB tar.gz，SHA512 与官网一致，解压无损坏 |
| 与 Hadoop 3.1.3 的兼容 | **需要打补丁** | 官方 bin 包 `lib/` 里带的是 Hadoop **3.3.1** 客户端 jar，直接用会 `ClassNotFoundException: org.apache.hadoop.thirdparty.com.google.common.collect.Maps` |
| 与 Hive 3.1.2 的集成 | **未通** | AM 正常启动并监听 DAGClient RPC，但 Hive CLI 始终等不到会话 READY |

关键事实：Apache 官方发布的 `apache-tez-0.10.2-bin.tar.gz` 是**对着 Hadoop 3.3.1 编译**的（`buildJavaVersion=1.8.0_292`，`lib/hadoop-hdfs-client-3.3.1.jar` 等一批 3.3.1 jar 就躺在里面）。Hadoop 3.3 引入了 shaded thirdparty 包，3.1.3 没有，所以两套 Hadoop 客户端混在一个 classpath 里必炸。

### 2. 那该用哪个版本？

- **0.9.2**：官方 bin 是 Hadoop 2.7.3 编的，上 3.1.3 同样要处理 lib 里的老 jar，不省事。
- **0.10.2 + 打补丁**：本次走的路线，能起 AM。
- **源码重编**：`mvn -Dhadoop.version=3.1.3`，最干净，但要本地 Maven 仓库和 20~40 分钟编译。
- **换 Hive 3.1.3+/4.x**：社区对新 Tez 的适配主要在这一侧，成本比改 Tez 低。

结论写进 README 路线图：**Tez 暂不作为当前优化项**，先把 `docs/06` 里的 P1（合并 INSERT、砍重复扫描）做完，收益 3~4 倍且零组件风险。

## 二、下载与校验

官方源 `archive.apache.org` 实测只有 ~6 KB/s（81 MB 要下几小时），换华为云镜像：

```bash
# 3.9 MB/s，2 分钟下完
wget https://repo.huaweicloud.com/apache/tez/0.10.2/apache-tez-0.10.2-bin.tar.gz

# 校验（官方 .sha512 文件同目录可取）
sha512sum apache-tez-0.10.2-bin.tar.gz
# 18511faff5ffdc07792057e178cac10b...  与官网一致
```

下好后先落到 hadoop1，再 `sftp` 分发到 hadoop2/3（内网 2 秒）。

## 三、部署步骤

### 步骤 0：先修 YARN 内存（前置条件，否则后面全是假象）

Tez 的 AM 默认要 1 GB，而原 `yarn-site.xml` 根本没配 `yarn.nodemanager.resource.memory-mb`，YARN 按默认 8192 MB/节点上报，物理只有 5851 MB —— 超卖 40%。不先修，Tez 容器会被"看起来有内存、实际抢不到"坑死。

三节点 `/opt/hadoop/etc/hadoop/yarn-site.xml`：

| 节点 | `yarn.nodemanager.resource.memory-mb` | `cpu-vcores` |
|---|---|---|
| hadoop1（4 GB 内存） | 2560 | 4 |
| hadoop2 / hadoop3（6 GB） | 3072 | 4 |
| 全局 | `yarn.scheduler.maximum-allocation-mb` = 2048 | — |

改完 `yarn --daemon stop nodemanager` 逐台重启，`yarn node -list` 应为
`totalMB=8704, totalVCores=12`（2560+3072+3072）。

### 步骤 1：三节点解压

```bash
sudo mkdir -p /opt/tez
sudo tar -xzf apache-tez-0.10.2-bin.tar.gz -C /opt/tez --strip-components=1
sudo chown -R cy:cy /opt/tez
```

### 步骤 2：把 Hadoop 3.3.1 的 jar 从 lib 里挪走（关键补丁）

```bash
cd /opt/tez
mkdir -p lib-hadoop331
mv lib/hadoop-*.jar lib-hadoop331/          # 只挪 hadoop-*，别动 tez-* 和第三方依赖
ls lib/*.jar | wc -l                        # 挪完剩 18 个
```

同时 `tez-site.xml` 里打开"用集群自带的 Hadoop 依赖"开关（步骤 3），双保险。

> 为什么不能只改配置？`tez.use.cluster.hadoop-libs=true` 只影响**容器内**的 classpath 组装；本地客户端（Hive CLI 自己）仍会扫 `TEZ_JARS` 里的一切，撞上 3.3.1 的 `hadoop-common` 依旧 `NoClassDefFoundError`。所以**挪文件 + 开配置**两件都要做。

### 步骤 3：`/opt/tez/conf/tez-site.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <!-- 用集群自带的 Hadoop 3.1.3 依赖，不用包里 3.3.1 的 -->
    <property><name>tez.use.cluster.hadoop-libs</name><value>true</value></property>
    <!-- Tez 运行库放 HDFS，AM/任务容器从这里取，不用每台机器铺 -->
    <property><name>tez.lib.uris</name><value>hdfs://hadoop1:9000/apps/tez/tez.tar.gz</value></property>
    <!-- 小集群把 AM 压到 1 GB -->
    <property><name>tez.am.resource.memory.mb</name><value>1024</value></property>
    <property><name>tez.am.java.opts</name><value>-Xmx819m</value></property>
    <property><name>tez.container.max.java.heap.fraction</name><value>0.8</value></property>
    <property><name>tez.runtime.io.sort.mb</name><value>256</value></property>
    <property><name>tez.runtime.unordered.output.buffer.size-mb</name><value>100</value></property>
    <property><name>tez.am.container.reuse.enabled</name><value>true</value></property>
    <property><name>tez.session.am.dag.submit.timeout.secs</name><value>600</value></property>
</configuration>
```

三节点内容必须一致（`md5sum` 对一下）。

### 步骤 4：环境变量 `/etc/profile.d/tez.sh`

```bash
export TEZ_HOME=/opt/tez
export TEZ_CONF_DIR=$TEZ_HOME/conf
export TEZ_JARS=$TEZ_HOME/*:$TEZ_HOME/lib/*
export HADOOP_CLASSPATH=$TEZ_CONF_DIR:$TEZ_JARS:$HADOOP_CLASSPATH
```

三节点都放（`sudo` 写，权限 644），然后 `source /etc/profile`。

> 这一条决定了 Hive 能不能 `Class.forName("org.apache.tez.dag.api.TezConfiguration")`。少配就是 `NoClassDefFoundError: org/apache/tez/dag/api/TezConfiguration`。

### 步骤 5：打 tez.tar.gz 上 HDFS

```bash
cd /opt/tez
tar -czf /tmp/tez.tar.gz --exclude=lib-hadoop331 .    # 77,841,135 字节
hdfs dfs -mkdir -p /apps/tez
hdfs dfs -put -f /tmp/tez.tar.gz /apps/tez/
hdfs dfs -ls /apps/tez/tez.tar.gz
```

打包时**必须排除 `lib-hadoop331`**，否则 3.3.1 的 jar 又被塞回 AM 容器。

### 步骤 6：验证清单

```bash
# 1) 类能找到
hive --hiveconf hive.execution.engine=tez -e "set hive.execution.engine;"
# 2) AM 能起（关键看这行）
yarn application -list -appTypes TEZ
grep "In Session mode" $HADOOP_HOME/logs/userlogs/application_*_000001/syslog
# 3) DAGClient RPC 监听
ss -lntp | grep <AM 日志里 Instantiated DAGClientRPCServer at ... :端口>
```

## 四、四阶段报错实录（按实际踩的顺序）

| 阶段 | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | `NoClassDefFoundError: org/apache/tez/dag/api/TezConfiguration` | 本地 shell 把 `/opt/tez/*` 提前展开，`HADOOP_CLASSPATH` 变成 `/opt/tez/conf:/` | 写成远端脚本 `/home/cy/tez_smoke.sh` 再执行，别在命令行里内联通配符 |
| 2 | `ClassNotFoundException: org.apache.hadoop.thirdparty.com.google.common.collect.Maps` | `lib/` 里是 Hadoop 3.3.1 的客户端 jar | 挪到 `lib-hadoop331/` 并重打 `tez.tar.gz` |
| 3 | `Failed to start Tez session: java.io.IOException: java.lang.InterruptedException: sleep interrupted` | 默认 `hive.cli.tez.session.async=true`，CLI 不等会话就绪，查询线程发现 `isOpen=false` 后 close 会话，把等待线程打断 | `--hiveconf hive.cli.tez.session.async=false` |
| 4 | 加了 `async=false` 后不再报错，但**永久卡在** `TezClient.waitTillReady` | 见下一节 | 未解决 |

第 3 阶段的堆栈很典型，值得记住：

```
java.io.IOException: java.lang.InterruptedException: sleep interrupted
    at ...TezSessionState.startSessionAndContainers(TezSessionState.java:456)
Caused by: java.lang.InterruptedException: sleep interrupted
    at java.lang.Thread.sleep(Native Method)
    at org.apache.tez.client.TezClient.waitTillReady(TezClient.java:1002)
```

伴随的告警是 `exec.Task: The session: ... isOpen=false, isDefault=false has not been opened`，并且**每 2 秒烧掉一个 YARN 应用**（`yarn application -list -appTypes TEZ` 里一长串 RUNNING/ACCEPTED）。

## 五、当前阻塞：会话握手不通

`async=false` 之后客户端不再自杀，改为一直等。抓 `jstack` 看得很清楚：

```
"Thread-18" ... TIMED_WAITING (sleeping)
    at java.lang.Thread.sleep(Native Method)
    at org.apache.tez.client.TezClient.waitTillReady(TezClient.java:1002)
    at org.apache.hadoop.hive.ql.exec.tez.TezSessionState.startSessionAndContainers(TezSessionState.java:453)
    at org.apache.hadoop.hive.ql.exec.tez.TezTask.ensureSessionHasResources(TezTask.java:368)
```

对照 AM 侧（同一时刻）：

| 检查项 | 结果 |
|---|---|
| AM 是否起来 | ✅ `[HISTORY][Event:AM_STARTED]`，`In Session mode. Waiting for DAG over RPC` |
| 版本握手 | ✅ `clientVersion=0.10.2, AMVersion=0.10.2` |
| DAGClient RPC 监听 | ✅ `Instantiated DAGClientRPCServer at hadoop1/192.168.10.129:37153`，`ss -lntp` 有，`/dev/tcp` 探测 OPEN |
| Web UI | ✅ `:50000` LISTEN |
| 客户端到 AM 的 IPC 连接 | ❌ 线程栈里只有到 RM `:8032` 和 NameNode 的连接，**从未连过 37153** |
| Web UI | 打不开（ATS 未启动，属预期） |

也就是说：**AM 一切正常，是客户端没去连它。** 客户端要靠 RM 的 `ApplicationReport.getRpcPort()` 拿到 AM 地址，这一步在本环境没成。剩下的可能性集中在：Hive 3.1.2 的 `TezTask` 与 Tez 0.10.x 会话状态机不匹配（社区在 Hive 3.1.3+ 修过），以及缺 ATS 导致状态回读异常。

**没有继续硬啃的原因**：修它要么换 Hive 版本、要么重编 Tez，两者都超出"先把 ADS 跑快"的目标；而同样收益在 SQL 层就能拿到（`docs/06` 第七节）。

## 六、如果要继续推进，三条路

1. **换 Hive 3.1.3**（最小改动）：把 `hive-exec` 等替换成 3.1.3，保留现有 Metastore；Hive 3.1.3 对 Tez 0.10 的会话处理有修复。
2. **源码重编 Tez**：`mvn clean package -Dhadoop.version=3.1.3 -DskipTests`，产物直接对 3.1.3，省掉挪 jar 这种土办法。
3. **上 HiveServer2 + 会话池**：`hive.server2.tez.initialize.default.sessions=true`，用 beeline 连，绕开 CLI 的异步会话逻辑（CLI 本来就是被官方标注"不推荐用于 Tez"的入口）。

## 七、回退（随时可做，无残留）

Tez 是**旁路组件**，不接管任何默认路径：

```bash
# 1) 停掉残留应用
for a in $(yarn application -list -appTypes TEZ | awk '/application_/{print $1}'); do
    yarn application -kill $a
done
# 2) 摘掉环境变量（不删目录也能"关掉" Tez）
sudo mv /etc/profile.d/tez.sh /etc/profile.d/tez.sh.off
# 3) HDFS 上的运行库可留可删
hdfs dfs -rm -r -skipTrash /apps/tez
```

Hive 默认引擎仍是 `mr`，`hive-site.xml` 里没有任何 Tez 相关 property，所以**不 source 那个 profile 就等于没装**。这一点是刻意设计的：避免"装了个半成品把生产链路带崩"。

## 八、命令速查

```bash
# 查 Tez 应用
yarn application -list -appTypes TEZ
yarn application -status application_xxx

# 看 AM 日志
ls -d $HADOOP_HOME/logs/userlogs/application_xxx/container_*_01_000001
grep -E "DAGAppMaster|DAGClientRPCServer|AM_STARTED" .../syslog

# 看客户端卡在哪
jstack $(pgrep -f CliDriver) | grep -A15 "waitTillReady"

# 强制清场（注意方括号，避免 pkill 杀掉自己）
pkill -9 -f 'CliDriv[e]r'
```

## 九、结论

- **下载、校验、分发、HDFS 铺库、AM 启动：全部成功**，`0.10.2` 与 `Hadoop 3.1.3` 的 jar 冲突已有确定解法（挪 jar + `tez.use.cluster.hadoop-libs`）。
- **Hive 3.1.2 CLI 会话握手：未通**，卡在 `TezClient.waitTillReady`，客户端不连 AM 的 DAGClient RPC。
- **不建议在当前项目上继续投入**：同样的 3~4 倍收益在 SQL 层（合并 INSERT、砍重复扫描、合并校验）就能拿到，且不引入版本风险。Tez 留作"引擎级优化"的备选，等 Hive 升级时一并做。
