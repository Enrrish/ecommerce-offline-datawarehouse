# DolphinScheduler 3.2.2 部署手册

> 本文档针对**本项目集群**编写，所有路径、端口、参数均已实测确认，可直接复制执行。
> 网上多数教程基于 3.1.x 的 `install.sh` 一键部署，**在 3.2.x 上全部不适用**，请勿混用。

---

## 0. 为什么是 3.2.2（版本选型的四个硬约束）

| 约束 | 集群现状 | 结论 |
|---|---|---|
| JDK 版本 | `openjdk 1.8.0_161`（`/opt/jdk`） | 3.3.x 起官方要求 JDK 11+，**上限锁死在 3.2.2** |
| 部署方式 | 无 Python 3（仅 2.7.5） | 3.2.0 删掉了 `install.sh` 一键部署，改为逐节点部署；Python Gateway 默认 `enabled: false`，正好不依赖 Python 3 |
| 内存 | 三节点各 5.7G（hadoop1 可用 2.8G） | master/worker 默认 `-Xmx4g`，**不调 JVM 参数必定 OOM** |
| 网络 | 集群 `github.com` 不通，仅阿里云镜像通 | 阿里云镜像无 3.2.x，需由宿主机从 `archive.apache.org` 下载后传入 |

**安装包已备好**（SHA512 与官方归档站一致）：

```
/home/cy/packages/apache-dolphinscheduler-3.2.2-bin.tar.gz   362M
/home/cy/packages/apache-zookeeper-3.8.4-bin.tar.gz           14M
/home/cy/packages/mysql-connector-java-8.0.33.jar            2.4M
```

校验值：`70f23840c4da72e7ed2d24248a9075be8823299e825efe51cf112ceed70a4ec376051f8a36598cef3e3abb685d7cfe05d49621756c88b950a4579c7291d2e13b`

---

## 1. 部署规划

### 1.1 角色分配

| 节点 | 角色 | 说明 |
|---|---|---|
| hadoop1 | master-server、api-server、alert-server | 同时承载 MySQL、NameNode、ResourceManager，压力最大，故不放 worker |
| hadoop2 | worker-server | 空闲内存 3.2G |
| hadoop3 | worker-server | 空闲内存 3.6G |

ZooKeeper 三节点全装（注册中心法定人数需要奇数节点）。

> **为什么 worker 放 2/3**：Hive 任务由 worker 提交到 YARN，本身不吃 worker 内存；但 worker 进程 + DataNode + NodeManager 叠加会挤占内存，hadoop1 已经跑了太多东西。

### 1.2 端口清单

| 服务 | 端口 | 用途 |
|---|---|---|
| ZooKeeper | 2181 / 2888 / 3888 | 客户端 / 集群内通信 / 选举 |
| api-server | 12345 | **Web UI 访问端口** |
| master-server | 5678（RPC）/ 5679（HTTP） | 与 worker 通信 / 健康检查 |
| worker-server | 1234（RPC）/ 1235（HTTP） | 接收任务 / 健康检查 |
| alert-server | 50052（RPC）/ 50053（HTTP） | 告警 |

防火墙：集群 `firewalld` 未运行（`systemctl is-active` 返回 unknown），SELinux 已 `Disabled`，无需额外放行。

---

## 2. 前置准备

### 2.1 MySQL 建库建用户

集群 MySQL 5.7.28 已运行，`bind-address=0.0.0.0` 已监听所有地址（从节点可直接连），无需改配置。

```bash
# 登录（用 root，或用集群上已有的 cy 账号——cy 需有 CREATE USER 权限，否则必须用 root）
mysql -uroot -p
```

```sql
CREATE DATABASE dolphinscheduler DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ds'@'%' IDENTIFIED BY 'Ds@123456';
GRANT ALL PRIVILEGES ON dolphinscheduler.* TO 'ds'@'%';
FLUSH PRIVILEGES;

-- 验证（从 hadoop2 上连一次，确认远程可达）
-- mysql -uds -p'Ds@123456' -h hadoop1 -e 'use dolphinscheduler; select 1;'
```

> MySQL 5.7 默认密码策略为 MEDIUM（≥8 位且含大小写、数字、特殊字符），`Ds@123456` 满足。若报密码策略错误，换成更长的组合即可。**生产环境请替换此密码。**

### 2.2 脚本分发到 worker 节点

当前 `/home/cy/scripts` 只在 hadoop1 上。SHELL 任务在哪个 worker 执行，脚本就必须在那台机器上存在——**漏了这步，任务会报 `No such file or directory`**。

```bash
scp -r /home/cy/scripts cy@hadoop2:/home/cy/
scp -r /home/cy/scripts cy@hadoop3:/home/cy/
```

### 2.3 sudo 方案（重要决策）

DolphinScheduler 用 `sudo -u <租户>` 切换执行身份，`sudo.enable=true`（默认）时要求部署用户有**免密 sudo**。当前集群 `cy` 的 sudo 需要密码，任务会卡在等待密码上。

**推荐先跑通、再加固：**

```bash
# 本次部署采用：关闭 sudo，任务直接以部署用户 cy 执行
sudo.enable=false
```

后续要还原生产标准做法时：

```bash
# 1) root 下给 cy 配免密 sudo
echo 'cy ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cy
chmod 440 /etc/sudoers.d/cy

# 2) 把 common.properties 改回
sudo.enable=true
```

> 简历/面试话术：先关闭 sudo 让调度链路跑通，再开启 sudo + 租户隔离实现多用户权限控制，这是循序渐进的加固过程，而不是不知道有这个机制。

---

## 3. 部署 ZooKeeper（三节点都要做）

### 3.1 解压安装

```bash
sudo mkdir -p /opt/zookeeper
sudo chown cy:cy /opt/zookeeper
cd /home/cy/packages
tar -xzf apache-zookeeper-3.8.4-bin.tar.gz -C /opt/zookeeper --strip-components=1
```

### 3.2 配置文件

```bash
mkdir -p /opt/zookeeper/data
cat > /opt/zookeeper/conf/zoo.cfg <<'EOF'
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/opt/zookeeper/data
clientPort=2181
maxClientCnxns=200
admin.enableServer=false
server.1=hadoop1:2888:3888
server.2=hadoop2:2888:3888
server.3=hadoop3:2888:3888
EOF
```

> `admin.enableServer=false` 是 3.6+ 的写法（旧版为 `admin.serverPort`）。ZK 内置 AdminServer 默认占 8080，与集群其他服务易冲突，直接关掉。

**myid 必须每台不同**：

```bash
echo 1 > /opt/zookeeper/data/myid    # hadoop1
echo 2 > /opt/zookeeper/data/myid    # hadoop2
echo 3 > /opt/zookeeper/data/myid    # hadoop3
```

**调小 JVM**（默认 1G，5.7G 内存下没必要）：

```bash
echo 'export JVMFLAGS="-Xms256m -Xmx512m $JVMFLAGS"' > /opt/zookeeper/conf/java.env
```

### 3.3 启动与验证

```bash
/opt/zookeeper/bin/zkServer.sh start
/opt/zookeeper/bin/zkServer.sh status     # 一台 leader，两台 follower
/opt/zookeeper/bin/zkCli.sh -server hadoop1:2181 -cmd ls /
```

常见故障：`status` 报 `Error contacting service`。
排查顺序：① 三台 myid 是否重复或缺失 ② `/opt/zookeeper/logs/` 日志 ③ 2888/3888 端口是否通。

---

## 4. 部署 DolphinScheduler

### 4.1 解压与驱动（三节点都要做）

```bash
sudo mkdir -p /opt/dolphinscheduler
sudo chown cy:cy /opt/dolphinscheduler
cd /home/cy/packages
tar -xzf apache-dolphinscheduler-3.2.2-bin.tar.gz -C /opt/dolphinscheduler --strip-components=1
```

**放 MySQL 驱动——5 个目录缺一不可**（官方二进制包因 License 不含驱动）：

```bash
cd /opt/dolphinscheduler
for d in api-server master-server worker-server alert-server tools; do
  cp /home/cy/packages/mysql-connector-java-8.0.33.jar $d/libs/
done
ls -lh api-server/libs/mysql-connector-java-8.0.33.jar    # 确认拷贝成功
```

### 4.2 环境变量（三节点都要做）

```bash
cat > /opt/dolphinscheduler/bin/env/dolphinscheduler_env.sh <<'EOF'
export JAVA_HOME=/opt/jdk
export DATABASE=mysql
export SPRING_PROFILES_ACTIVE=mysql
export SPRING_JACKSON_TIME_ZONE=Asia/Shanghai
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
export HIVE_HOME=/opt/hive
export SPARK_HOME=/home/cy/spark
export PATH=$JAVA_HOME/bin:$HADOOP_HOME/bin:$HIVE_HOME/bin:$SPARK_HOME/bin:$PATH
EOF
```

> **关键机制**：启动时 `bin/dolphinscheduler-daemon.sh` 会用这个文件**覆盖**各服务的 `<server>/conf/dolphinscheduler_env.sh`。所以：
> - 环境变量只改这一处，改服务级文件会被覆盖，等于白改；
> - 每个任务执行时都会 source 这个文件，所以 `hive`、`hadoop` 命令能否在任务里直接用，全靠这里的 `PATH`；
> - `DATABASE=mysql` 决定数据库初始化脚本用哪个 profile，不能漏。

### 4.3 数据库连接与注册中心（三节点都要做）

```bash
cd /opt/dolphinscheduler
for f in api-server master-server worker-server alert-server; do
  # 切换到 mysql profile
  # 注意：yaml 是多行嵌套，写成 "spring.profiles.active" 匹配不到（中间有换行）
  sed -i 's|^    active: postgresql|    active: mysql|' $f/conf/application.yaml
  # 数据库连接
  sed -i 's|jdbc:mysql://127.0.0.1:3306/dolphinscheduler|jdbc:mysql://hadoop1:3306/dolphinscheduler?useUnicode=true\&characterEncoding=UTF-8\&useSSL=false\&allowPublicKeyRetrieval=true\&serverTimezone=Asia/Shanghai|' $f/conf/application.yaml
  sed -i 's|    username: root|    username: ds|' $f/conf/application.yaml
  sed -i 's|    password: root|    password: Ds@123456|' $f/conf/application.yaml
  # 注册中心
  sed -i 's|connect-string: localhost:2181|connect-string: hadoop1:2181,hadoop2:2181,hadoop3:2181|' $f/conf/application.yaml
done

# 初始化工具也要改（它没有 profiles.active，靠 DATABASE 环境变量驱动）
sed -i 's|jdbc:mysql://127.0.0.1:3306/dolphinscheduler?useUnicode=true&characterEncoding=UTF-8|jdbc:mysql://hadoop1:3306/dolphinscheduler?useUnicode=true\&characterEncoding=UTF-8\&useSSL=false\&allowPublicKeyRetrieval=true\&serverTimezone=Asia/Shanghai|' tools/conf/application.yaml
sed -i 's|    username: root|    username: ds|' tools/conf/application.yaml
sed -i 's|    password: root|    password: Ds@123456|' tools/conf/application.yaml
```

**逐项验证**（5 个文件都要检查，这是最容易漏的一步）：

```bash
cd /opt/dolphinscheduler
# profiles 是多行嵌套，必须用 -A1 看下一行，直接 grep "profiles.active" 永远匹配不到
grep -H -A1 '^  profiles:' api-server/conf/application.yaml master-server/conf/application.yaml \
                            worker-server/conf/application.yaml alert-server/conf/application.yaml
grep -H "jdbc:mysql" api-server/conf/application.yaml master-server/conf/application.yaml \
                     worker-server/conf/application.yaml alert-server/conf/application.yaml tools/conf/application.yaml
grep -H "connect-string" */conf/application.yaml
```

期望输出：`active: mysql`、`jdbc:mysql://hadoop1:3306/...`、`connect-string: hadoop1:2181,hadoop2:2181,hadoop3:2181`。

> **关于 profile 的优先级**：环境变量 `SPRING_PROFILES_ACTIVE` **高于** yaml 里的 `spring.profiles.active`。
> 我们在 `bin/env/dolphinscheduler_env.sh` 里已导出 `SPRING_PROFILES_ACTIVE=mysql`，所以即使 yaml 里还写着 `postgresql`，服务也会用 mysql 正常启动——这也是"配置没改全但服务照样起来"的原因。
> 但不要依赖这个兜底：万一哪次环境变量没加载（例如直接跑 `<server>/bin/start.sh`），就会退回 postgresql 而连不上库。**两处都要改成 mysql。**

### 4.4 资源中心与 sudo（三节点都要做）

```bash
cd /opt/dolphinscheduler
sed -i 's|^resource.storage.type=LOCAL|resource.storage.type=HDFS|' */conf/common.properties
sed -i 's|^resource.hdfs.fs.defaultFS=hdfs://mycluster:8020|resource.hdfs.fs.defaultFS=hdfs://hadoop1:9000|' */conf/common.properties
sed -i 's|^resource.hdfs.root.user=hdfs|resource.hdfs.root.user=cy|' */conf/common.properties
sed -i 's|^sudo.enable=true|sudo.enable=false|' */conf/common.properties
```

> ① `fs.defaultFS` 必须是 `hdfs://hadoop1:9000`——集群 core-site.xml 用的是 9000，不是教程常见的 8020。
> ② `resource.hdfs.root.user` 默认是 `hdfs`，但集群实际操作用户是 `cy`，必须改成 `cy`，否则资源中心建目录会报权限错。
> ③ 资源中心改 HDFS 后，上传的脚本/资源三节点共享，避免"worker1 上传、worker2 找不到"的问题。

### 4.5 调整 JVM（三节点都要做，不调必 OOM）

```bash
cd /opt/dolphinscheduler
sed -i 's/-Xms4g/-Xms512m/; s/-Xmx4g/-Xmx1g/; s/-Xmn2g/-Xmn256m/' master-server/bin/jvm_args_env.sh
sed -i 's/-Xms4g/-Xms512m/; s/-Xmx4g/-Xmx1g/; s/-Xmn2g/-Xmn256m/' worker-server/bin/jvm_args_env.sh
sed -i 's/-Xms1g/-Xms256m/; s/-Xmx1g/-Xmx512m/; s/-Xmn512m/-Xmn128m/' api-server/bin/jvm_args_env.sh
sed -i 's/-Xms1g/-Xms256m/; s/-Xmx1g/-Xmx512m/; s/-Xmn512m/-Xmn128m/' alert-server/bin/jvm_args_env.sh

grep -HE "^-Xm[sxn]" master-server/bin/jvm_args_env.sh worker-server/bin/jvm_args_env.sh \
                     api-server/bin/jvm_args_env.sh alert-server/bin/jvm_args_env.sh
```

> master/worker 默认 4G，在 5.7G 的机器上叠加 Hadoop 进程会直接被 OOM killer 杀掉。调到 1G 后，实测内存占用：hadoop1 约 +1.8G，hadoop2/3 各 +1G。

### 4.6 关闭/放宽 worker 负载保护（**必做，否则任务永远不执行**）

这是本项目集群上最容易卡住的一步：服务全部正常、UI 能看到 worker 在线、工作流也能上线，
但任务实例始终不派发，worker 日志反复刷：

```
OverLoad: the SystemMemoryUsedPercentage: 0.8155 is over then the
maxSystemMemoryUsagePercentageThresholds 0.7
```

**根因**：DolphinScheduler 的 worker 自带过载保护，系统内存使用率超过阈值（默认 0.7）就拒绝接收任务。
虚拟机只有 5.7G，且 Linux 会把 buff/cache 计入已用内存，实测使用率在 0.71~0.82 之间波动，**刚好卡在阈值之上**，
于是 worker 一直处于"在线但拒单"状态。

```bash
cd /opt/dolphinscheduler
# === 所有节点、所有服务都要改（漏一个就是一个隐形杀手）===
# 内存/系统CPU：hadoop2/3 放宽到 0.9；hadoop1 承载服务最多，master/api/alert 单独放到 0.95
sed -i 's|max-system-memory-usage-percentage-thresholds: 0.7|max-system-memory-usage-percentage-thresholds: 0.9|' */conf/application.yaml
sed -i 's|max-system-cpu-usage-percentage-thresholds: 0.7|max-system-cpu-usage-percentage-thresholds: 0.9|' */conf/application.yaml
# JVM CPU：worker 冷启动时 JIT 会让 CPU 瞬间冲到 90%+，放宽到 0.95 避免启动期误拦
sed -i 's|max-jvm-cpu-usage-percentage-thresholds: 0.7|max-jvm-cpu-usage-percentage-thresholds: 0.95|' */conf/application.yaml
# hadoop1 的 master/api/alert 内存阈值再提一档
sed -i 's|max-system-memory-usage-percentage-thresholds: 0.9|max-system-memory-usage-percentage-thresholds: 0.95|' master-server/conf/application.yaml api-server/conf/application.yaml alert-server/conf/application.yaml

grep -hE 'thresholds' */conf/application.yaml | sort -u    # 核对最终值
```

修改后**必须重启对应服务**才生效：

```bash
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh stop worker-server
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh start worker-server
```

**血泪教训（本项目实测）**：只改 worker 不改 master 是不够的——master 也有同样的负载保护，
master 被拦的后果是**整个工作流不触发**（比 worker 拒单更隐蔽，worker 日志什么都看不到）。
本集群 hadoop1 的 master 实测内存读数 0.92+，用 0.9 都会拦，所以 master 侧必须 0.95。

> 若仍被拒绝，可临时 `enabled: false` 彻底关闭保护（生产环境不建议）。
> 但更根本的解法是给虚拟机足够的内存——见第 10 章。

---

## 5. 初始化数据库（**只在 hadoop1 执行一次**）

```bash
cd /opt/dolphinscheduler
bash tools/bin/upgrade-schema.sh
```

成功标志：日志末尾出现 `upgrade DolphinScheduler finished`，且无 `Access denied` / `Communications link failure`。

```bash
# 验证表是否建出来
mysql -uds -p'Ds@123456' -h hadoop1 dolphinscheduler -e 'show tables;' | wc -l    # 应约 60+
```

> 重复执行安全（内部用 Flyway 做版本管理）。

---

## 6. 启动与验证

### 6.1 按角色启动

```bash
# ===== hadoop1 =====
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh start master-server
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh start api-server
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh start alert-server

# ===== hadoop2 / hadoop3 =====
bash /opt/dolphinscheduler/bin/dolphinscheduler-daemon.sh start worker-server
```

停止 / 查状态同理，把 `start` 换成 `stop` / `status`。

### 6.2 验证

```bash
# 进程状态：逐个服务查询（本机上起了哪些就查哪些）
cd /opt/dolphinscheduler
for s in master-server api-server alert-server worker-server; do
  bash bin/dolphinscheduler-daemon.sh status $s
done

jps | grep -iE "ApiApplication|MasterServer|WorkerServer|AlertServer"
```

> **`status-all.sh` / `start-all.sh` 在 3.2.x 上不能用。** 它们是 3.1.x 一键部署时代的遗留脚本，
> 强依赖已被删除的 `bin/env/install_env.sh`，执行会报
> `/opt/dolphinscheduler/bin/env/install_env.sh: 没有那个文件或目录` + `hosts:[    ]` + `Bad port`。
> 手动逐节点部署场景下，一律用 `dolphinscheduler-daemon.sh (start|stop|status) <服务名>`。

**端口检查**：

```bash
ss -lntp | grep -E ':(12345|5678|1234) '
```

**日志（启动慢时看这里）**：

```bash
tail -f /opt/dolphinscheduler/api-server/logs/api-server-hadoop1.out
tail -f /opt/dolphinscheduler/master-server/logs/master-server-hadoop1.out
tail -f /opt/dolphinscheduler/worker-server/logs/worker-server-hadoop2.out
```

浏览器访问（**注意路径末尾的 `/ui/`**）：

```
http://hadoop1:12345/dolphinscheduler/ui/
```

默认账号：`admin` / `dolphinscheduler123`（首次登录会要求改密码）。

---

## 7. 接入数仓任务

### 7.1 创建租户

安全中心 → 租户管理 → 创建租户：租户编码填 `cy`（须是各节点真实存在的 Linux 用户）。

> `sudo.enable=false` 时租户只做标识，实际以部署用户执行；开启 sudo 后租户才真正做身份隔离。

**这一步最容易漏**：租户在 DS 里建好了，但**保存工作流时下拉框默认停在 `default`**，而 `default` 是内置占位租户、不是系统用户，任务会在执行前直接被拒（见 7.6⑤）。每次保存工作流都要确认租户是 `cy`。

### 7.2 创建项目

项目管理 → 创建项目，名称 `ecommerce_dw`。

### 7.3 创建工作流（ODS → DWD → DWS → ADS 串行）

项目管理 → 工作流 → 工作流定义 → 创建工作流。

**全局参数**：点击画布右上角的**保存**按钮，在**弹出的保存对话框里**设置全局参数
（不同版本 UI 位置略有差异，若画布右侧能找到"全局参数"面板，在那里设置效果相同）。

| 参数名 | 值 | 说明 |
|---|---|---|
| `bizdate` | `$[yyyy-MM-dd-1]` | 业务日期，T+1 跑昨天数据 |

> `$[yyyy-MM-dd-1]` 是 DS 的自定义时间格式（支持日期加减）。内置的 `${system.biz.date}` 是 `yyyyMMdd` 无分隔符格式，与本项目的分区格式 `dt=2019-10-01` 不匹配，**不能直接用**。

**拖 4 个 SHELL 节点**串成一条链（从前一节点右侧圆点拖到后一节点）：

| 节点名 | 脚本内容 |
|---|---|
| `ods_load` | `echo "[ODS] bizdate=${bizdate}"`<br>`bash /home/cy/scripts/ods/ods_load.sh ${bizdate}` |
| `dwd_etl` | `echo "[DWD] bizdate=${bizdate}"`<br>`bash /home/cy/scripts/dwd/dwd_load.sh ${bizdate}` |
| `dws_sum` | `echo "[DWS] bizdate=${bizdate}"`<br>`bash /home/cy/scripts/dws/dws_load.sh ${bizdate}` |
| `ads_stat` | `echo "[ADS] bizdate=${bizdate}"`<br>`bash /home/cy/scripts/ads/ads_load.sh ${bizdate}` |

节点配置要点：
- **运行标志**：正常（非"禁止执行"）
- **worker 分组**：`default`
- **失败重试次数**：1~2 次，重试间隔 1 分钟（应对 YARN 瞬时资源不足）

**保存工作流时**选择租户 `cy`，执行策略按下表选：

| 选项 | 含义 | 建议 |
|---|---|---|
| 并行 | 多个实例同时跑 | ✗ 分层链路有依赖，不能用 |
| **串行等待** | 新实例排队等前一实例跑完 | ✓ **推荐**（不丢调度，顺序执行） |
| 串行抛弃 | 前一实例未跑完则丢弃新实例 | 补数场景下可用，避免积压 |
| 串行优先 | 按优先级串行 | 本项目无需 |

> 我们的脚本全是幂等设计（`INSERT OVERWRITE` + 先删后传），所以"串行等待"即使重叠也不会产生脏数据。

**工作流内部的失败策略**在运行/定时时设置：选 **结束**（END）。
含义是：链路上任一节点失败，后续节点不再执行——ODS 失败就不该跑 DWD，这正是分层依赖要的语义。

保存后点**上线**，再点**运行**测试。

### 7.4 定时与补数

- **定时**：工作流定义 → 定时 → 新建，cron 填 `0 10 2 * * ?`（每天 02:10 跑昨天数据）
- **补数**：工作流定义 → 运行 → 补数，选择日期范围一次性回填历史

> **补数填的是「调度日」，不是业务日期**，因为全局参数 `bizdate = $[yyyy-MM-dd-1]` 还要再减一天。
> 想跑业务日期 `2019-10-01`，补数日期要填 **`2019-10-02`**；跑整个 10 月则填 `2019-10-02` ~ `2019-11-01`。
> 实测对照：补数填 2019-10-30 → bizdate 2019-10-29（有数据）；填 2019-10-01 → bizdate 2019-09-30（无此文件，报错退出）。

**定时里的"失败策略"要选"继续"，不要选"结束"** —— 这是两个容易混淆的概念：

| 位置 | 推荐值 | 理由 |
|---|---|---|
| 工作流内部（运行/定时时的失败策略） | **结束** | 上游 ODS 失败则 DWD/DWS/ADS 不再执行，防止脏数据向下游扩散 |
| 定时调度自身的失败策略 | **继续** | 今天的实例失败了，明天的调度仍要触发。若设为"结束"，一次失败会让整个定时永久停摆，必须人工恢复 |

即：**用工作流内部的"结束"保证数据正确，用定时的"继续"保证调度不中断**，再配合告警和补数机制兜底。

> 补数时若历史数据量大，优先用脚本自带的 `all` 模式（批量 SQL 比按天循环快约 19 倍，见 `docs/03_踩坑记录.md`）。

### 7.5 验证任务真的跑起来了

```bash
# 任务实例里看日志，确认 bizdate 传参正确、hive 命令能找到
# 日志路径（worker 节点上）：
ls /opt/dolphinscheduler/worker-server/logs/
```

日志里应能看到：`[ODS] bizdate=2019-10-01` 以及各层校验输出。若报 `hive: command not found`，说明 4.2 的 `PATH` 没配好——检查 `bin/env/dolphinscheduler_env.sh` 是否被正确覆盖到 `<server>/conf/dolphinscheduler_env.sh`。

**如果任务实例一直处于"提交成功/等待中"而从不执行**，先查 worker 日志：

```bash
grep -i "OverLoad" /opt/dolphinscheduler/worker-server/logs/dolphinscheduler-worker.log | tail -3
```

看到 `SystemMemoryUsedPercentage ... is over then ... 0.7` 就是 4.6 的负载保护在拦，按 4.6 处理。

### 7.6 首次运行失败实录：`exitStatusCode:127`

工作流 2 秒内失败、任务实例 `state=6`，看 UI 只能看到"失败"两个字。**真正的报错在 worker 日志里**，最快的定位方式是直接查元数据库：

```bash
mysql -uds -p'Ds@123456' dolphinscheduler -e "
SELECT id,name,state,start_time,end_time,host FROM t_ds_process_instance ORDER BY id DESC LIMIT 5\G"

# 再到 host 指向的那台 worker 上看日志
grep -E "exitStatusCode|rawScript" /opt/dolphinscheduler/worker-server/logs/dolphinscheduler-worker.log | tail -5
```

`exitStatusCode:127` 是 shell 的 **command not found**（126 是无执行权限，1 是脚本内逻辑失败，靠退出码就能先分流）。

本次实测暴露四个叠加问题，按严重度排列：

**① 从节点 Hive 连不上元数据（最隐蔽，会让 DWD/DWS/ADS 全挂）**

hadoop2/3 的 `hive-site.xml` 里写的是 `root/root`，而实际 MySQL 密码是 `123456`。现象是 `Unable to instantiate SessionHiveMetaStoreClient`——看起来像 Metastore 服务没起，其实是账号密码错。

```bash
# hadoop2/3 各执行一次（hadoop2 的 /opt/hive/conf 属 root，需 sudo）
CONF=/opt/hive/conf/hive-site.xml
cp $CONF ${CONF}.bak.$(date +%s)
sed -i "/<name>javax.jdo.option.ConnectionUserName<\/name>/{n;s|<value>[^<]*|<value>cy|}" $CONF
sed -i "/<name>javax.jdo.option.ConnectionPassword<\/name>/{n;s|<value>[^<]*|<value>123456|}" $CONF

# 验证（应返回 188895）
hive -S -e 'SELECT COUNT(1) FROM mydb.dws_user_action_day WHERE dt="2019-10-01";'
```

> 三台都是嵌入式直连 MySQL。生产环境更规范的做法是在 hadoop1 起 `hive --service metastore`（9083），各节点配 `hive.metastore.uris=thrift://hadoop1:9083`——但 hadoop1 内存已吃紧（见第 10 章），当前阶段先保证跑通。

**② 脚本目录是扁平的，而任务里填的是分层路径**

历史遗留：`/home/cy/scripts/` 下所有脚本混在一起，只有 `ads/`、`ops/` 是子目录。按 2.2 重建分层目录，并同步修正脚本内的硬编码路径（这一步容易漏，漏了就会报找不到 SQL 文件）：

```bash
cd /home/cy/scripts
mkdir -p ods dwd dws
mv split_source.sh ods_ddl.sql ods_load.sh ods_add_partition.sql ods/ 2>/dev/null
mv dwd_ddl.sql dwd_etl.sql dwd_load.sh dwd/ 2>/dev/null
mv dws_ddl.sql dws_dim_user.sql dws_etl_day.sql dws_backfill.sql dws_load.sh dws/ 2>/dev/null

# 同步修正脚本内硬编码的绝对路径
sed -i 's|/home/cy/scripts/dwd_etl.sql|/home/cy/scripts/dwd/dwd_etl.sql|' dwd/dwd_load.sh
sed -i 's|/home/cy/scripts/dws_|/home/cy/scripts/dws/dws_|g' dws/dws_load.sh

# 分发到 worker 节点并清理旧的扁平文件
for h in hadoop2 hadoop3; do
  scp -rq ods dwd dws ads ops $h:/home/cy/scripts/
  ssh $h "cd /home/cy/scripts && rm -f split_source.sh ods_*.sql ods_load.sh dwd_*.sql dwd_load.sh dws_*.sql dws_load.sh"
done
```

**③ worker 节点没有源数据**

ODS 层要读本地 CSV 再 `hadoop fs put`，而 `split/` 只在 hadoop1 有。任务被随机派到 hadoop2/3 就会失败：

```bash
for h in hadoop2 hadoop3; do
  ssh $h "mkdir -p /home/cy/project/data"
  scp -rq /home/cy/project/data/split $h:/home/cy/project/data/
done
```

约 1.2G × 2，本机千兆网络约 1~2 分钟。三台各占 1.2G 磁盘，当前剩余 22G+ 无压力。

**④ bizdate 算出来是 2026-10-25，但数据集是 2019 年 10 月**

`$[yyyy-MM-dd-1]` 按**当前系统时间**取昨天，得到的是 2026 年的日期，而源数据只有 2019-10-01~10-31，ODS 会因为找不到 `ecommerce_events_2026-10-25.csv` 而失败。

这不是配置错误，是历史数据集的固有矛盾。处理方式：

- **全局参数继续保留 `$[yyyy-MM-dd-1]`**——T+1 语义是对的，简历上要的就是这个
- **实际验证/演示一律用「补数」**：工作流定义 → 运行 → 补数，日期范围填 `2019-10-01` ~ `2019-10-31`
- 定时可以上线展示能力，但要知道在历史数据集上它每天都会因"无当日源文件"失败，属预期行为

**⑤ 租户选成了 `default`（任务还没开始执行就被拒）**

现象是任务秒失败，worker 日志里：

```
TaskException: TenantCode: default doesn't exist
    at ...TaskExecutionContextUtils.getOrCreateTenant(TaskExecutionContextUtils.java:74)
```

`default` 是 DS **内置的占位租户**（`t_ds_tenant` 里 `id=-1`），但它**不是 Linux 系统用户**。DS 的租户机制要求租户编码必须是各节点真实存在的 OS 用户——`getOrCreateTenant` 会在 worker 上校验并创建执行目录，找不到同名用户就直接抛异常，脚本一行都不会跑。

两种解法：

- **推荐**：工作流定义 → 编辑 → 点保存，在**保存对话框的"租户"下拉框**里选 `cy` → 重新**上线** → 再运行
- 兜底：三台各执行 `sudo useradd -m default`，让占位租户有对应的系统用户。能立刻跑通，但租户语义混乱，不建议长期使用

> 注意别混淆：**worker 分组的 `default` 是正常的默认分组，保持不变**；只有租户的 `default` 有问题。

租户信息**不在工作流定义表里**（`t_ds_process_definition` 没有 tenant 字段），它存在 `t_ds_process_instance` / `t_ds_command` 的 `tenant_code`，运行时才传入。所以这个问题**改数据库没用，只能在 UI 里改**。

**⑥ 补数填 2019-10-01，脚本却收到 `2019-09-30`**

到这一步脚本已经真的跑起来了（日志有 `[ODS] bizdate=...` 和各层输出），只是日期对不上：

```
[ODS] bizdate=2019-09-30
[ERROR] 2019-09-30 本地文件缺失: /home/cy/project/data/split/ecommerce_events_2019-09-30.csv
```

根因是**补数日期与业务日期差一天**。补数对话框里选的日期会成为实例的 `schedule_time`，而全局参数 `bizdate=$[yyyy-MM-dd-1]` 是在 `schedule_time` 基础上再减一天：

| 补数填的日期 | schedule_time | 实际 bizdate |
|---|---|---|
| 2019-10-30 | 2019-10-30 02:10 | 2019-10-29 |
| 2019-10-01 | 2019-10-01 00:00 | 2019-09-30 |

所以**要跑业务日期 D，补数就填 D+1**：跑 10-01 填 10-02，跑整个 10 月填 `2019-10-02` ~ `2019-11-01`。

不要把全局参数改成 `$[yyyy-MM-dd]` 来"对齐"——那样定时调度就会变成跑当天而非 T-1，语义就错了。T+1 语义要保住，补数时自己 +1 即可。

---

## 8. 故障排查

| 现象 | 根因 | 处理 |
|---|---|---|
| `bash: install.sh: No such file` | 3.2.0 起已移除一键部署脚本 | 按本文档逐节点部署 |
| 服务起来几秒后消失 | JVM 默认 4G 被 OOM killer 杀掉 | 按 4.5 调小；`dmesg \| grep -i oom` 确认 |
| `Communications link failure` | 驱动没放 / 库没建 / URL 写错 | 检查 5 个 `libs/` 目录驱动、4.2 的 URL |
| `Access denied for user 'ds'@'hadoop2'` | 用户授权没带 `%` | 重跑 `GRANT ... TO 'ds'@'%'` |
| `hive: command not found` | 环境变量没生效 | 检查 `bin/env/dolphinscheduler_env.sh` 的 PATH |
| worker 在 UI 里看不到 | 服务未注册到 ZK | 查 ZK 状态 + worker 日志 |
| 任务卡住不动 | `sudo.enable=true` 但没配免密 | 改 `sudo.enable=false`，或按 2.3 配 sudo |
| 页面 404 | 访问路径不对 | 必须是 `/dolphinscheduler/ui/` |
| `bash: /home/cy/scripts/...: No such file` | 脚本没同步到 worker 节点 | 按 2.2 分发 |
| 任务一直不执行，日志刷 `OverLoad ... 0.7` | worker 过载保护拦截（内存阈值过高） | 按 4.6 放宽阈值到 0.9 并重启 worker |
| `status-all.sh` 报 `Bad port` / `hosts:[]` | 该脚本依赖已删除的 `install_env.sh` | 改用 `dolphinscheduler-daemon.sh status <服务>` |
| 服务明明正常但连不上库 | profile 未切换 | 见 4.3：环境变量与 yaml 两处都要是 mysql |
| `exitStatusCode:127` | 命令/脚本不存在（126=无权限，1=逻辑失败） | 按 7.6 逐条排查 |
| `Unable to instantiate SessionHiveMetaStoreClient` | 从节点 `hive-site.xml` 的元数据账号密码错 | 按 7.6① 改为 `cy/123456` |
| ODS 报 `ecommerce_events_xxxx.csv 不存在` | worker 节点没有 split 源数据 | 按 7.6③ 分发 |
| bizdate 是当年日期、没有数据 | 数据集是 2019 年的历史数据 | 按 7.6④ 用补数指定 2019-10 范围 |
| `TenantCode: default doesn't exist` | 租户选了内置占位租户 `default`，它不是系统用户 | 按 7.6⑤ 在保存弹窗改租户为 `cy` |
| `本地文件缺失: ecommerce_events_2019-09-30.csv` | 补数日期与业务日期差一天 | 按 7.6⑥ 补数填业务日期+1，跑 10-01 要填 10-02 |

---

## 9. 部署完成后的简历可写点

- **调度架构**：3 节点集群部署（1 master + 1 api + 1 alert + 2 worker），ZooKeeper 做注册中心，MySQL 做元数据库
- **依赖编排**：ODS→DWD→DWS→ADS 四层串行依赖，上游失败自动阻断下游，避免脏数据向下游扩散
- **参数化调度**：全局参数 `bizdate=$[yyyy-MM-dd-1]` 实现 T+1 增量调度，支持按日期范围补数
- **故障自愈**：任务级重试 + 分层校验脚本（每层跑完自动核对行数/金额一致性，不一致即返回非零退出码，由调度系统判定失败）
- **资源适配**：针对 5.7G 内存环境将 master/worker 堆内存从 4G 调优至 1G

---

## 10. 虚拟机资源规划（重要：当前配置已超配）

### 10.1 现状诊断

| 项目 | 数值 |
|---|---|
| 宿主机物理内存 | **15.7 GB** |
| CPU | AMD Ryzen 9 7945HX（16 核 32 线程） |
| 三台 VM 分配内存 | 5.7 GB × 3 = **17.1 GB** |
| 宿主机当前可用内存 | **0.3 GB** |
| 系统已提交内存 | **33.8 GB**（远超物理内存） |

**结论：不能再加资源了——现在已经是超配状态。**

三台 VM 的分配总量（17.1G）已经**超过宿主机物理内存（15.7G）**，系统正在大量使用页面文件做内存交换。
这解释了两个此前被视为偶发的现象：

- hadoop1 曾无故挂起、网卡链路 down；
- worker 触发内存保护（第 4.6 节）——VM 内内存吃紧只是表象，宿主机层面在频繁换页，整体 IO 和响应都被拖慢。

### 10.2 先做这件事：检查 VMware 内存预留

VMware 给 VM 分配的内存默认是"上限"而非"独占"。但若勾选了
**虚拟机设置 → 内存 → "预留所有客户机内存（全部锁定）"**，
VM 会**独占**全部分配值，哪怕内部只用了 2G，宿主机也拿不回来。

**务必取消勾选**（三台都要检查），让 VMware Tools 的内存气球机制能动态回收。这是零成本的改善。

> 修改内存配置需**关机**（挂起状态下不可改）。

### 10.3 三个方案

| 方案 | 配置 | 代价 | 适用 |
|---|---|---|---|
| A. 立即优化（免费） | 取消内存预留；hadoop1 6G / hadoop2 3.5G / hadoop3 3.5G（共 13G）；不用时挂起闲置 VM | 0 元，需 10 分钟 | 现在就做 |
| **B. 加内存条（推荐）** | 16G → **32G**，然后 hadoop1 8G / hadoop2 6G / hadoop3 6G（共 20G） | 约 200~350 元 | 一劳永逸 |
| C. 压缩 VM | hadoop1 5G / hadoop2 3G / hadoop3 3G（共 11G） | 免费但捉襟见肘 | 临时应急 |

**推荐 B**。这台机器的 CPU（Ryzen 9 7945HX，16 核 32 线程）性能严重过剩——三台 VM 各 4 核也只用了 12 核。
瓶颈完全在内存，加到 32G 后整套环境（Hadoop + Hive + DS + 后续 Superset）都能从容运行，
而且你的 CPU 撑得起更多并发。

加内存前先确认机器形态：笔记本用 **DDR5 SO-DIMM**，迷你主机/台式机用 **DDR5 DIMM**，
两条规格不同，买错装不上。

### 10.4 资源变化后需要同步调整的项

若最终调整了 VM 内存，记得同步改：

1. **YARN 容器内存**（`yarn-site.xml`）：`yarn.nodemanager.resource.memory-mb`，
   一般设为 VM 内存的 50%~60%；
2. **DS 各服务 JVM**（第 4.5 节）：内存宽裕后可调回 2G；
3. **worker 负载保护阈值**（第 4.6 节）：内存充足后可改回 0.7，保留保护能力。

---

## 11. 运维脚本与开机自启

### 11.1 一键启停 + 自检脚本

脚本位置：`/home/cy/scripts/ops/dw-cluster.sh`（三节点各一份，已同步）。
**全集群命令只在 hadoop1 上执行**（内部通过 SSH 控制其他节点）。

| 命令 | 作用 |
|---|---|
| `bash dw-cluster.sh start` | 全链路启动：ZK(3台) → HDFS/YARN → 等 safemode 退出 → DS master/api/alert → 等 api 端口 → DS worker，最后自动跑一遍 check |
| `bash dw-cluster.sh stop` | 逆序停止 |
| `bash dw-cluster.sh restart` | 先 stop 再 start |
| `bash dw-cluster.sh status` | 各节点 jps 进程 + DS 服务 RUNNING/STOP 一览 |
| `bash dw-cluster.sh check` | 深度自检，7 个维度（见下） |
| `bash dw-cluster.sh node-start/stop` | 只管本机服务，供 systemd 调用 |

`check` 的 7 个维度：ZK 角色与 quorum、MySQL 3306 可达、HDFS safemode 与 Live datanodes、
YARN NodeManager 数、DS 五个进程、四个端口 + UI HTTP 探活（期望 200）、
**worker/master 最近 10 分钟的 OverLoad 拦截检测**（只看最近 10 分钟，避免历史日志误导）。

### 11.2 开机自启（systemd）

原理：三台 VM 各装一个 `dw-node.service`，VM 开机后自动执行 `dw-cluster.sh node-start`，
按主机名自动判断角色（hadoop1 起 ZK→Hadoop→master/api/alert；hadoop2/3 起 ZK→等 MySQL→worker→补起 DN/NM）。

**worker 节点的 DN/NM 补起逻辑**：如果 hadoop1 比 hadoop2/3 先开机，`start-dfs.sh` 远程 ssh 拉起从节点会失败，
脚本会在 hadoop2/3 上检测本机无 DataNode/NodeManager 后用 `hdfs --daemon start datanode` 兜底补起，幂等可重复执行。

三台都执行（需要 root 密码）：

```bash
sudo tee /etc/systemd/system/dw-node.service > /dev/null <<'EOF'
[Unit]
Description=DW cluster node services (ZooKeeper / Hadoop / DolphinScheduler)
After=network-online.target mysqld.service
Wants=network-online.target

[Service]
Type=oneshot
User=cy
ExecStart=/home/cy/scripts/ops/dw-cluster.sh node-start
ExecStop=/home/cy/scripts/ops/dw-cluster.sh node-stop
RemainAfterExit=yes
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable dw-node.service
```

> - `mysqld` 已是 `enabled`，开机自动拉起，`After=mysqld.service` 保证 DS 起来前元数据库可用；
> - systemd 环境**不加载** `~/.bashrc`，脚本内已显式 `export JAVA_HOME/HADOOP_HOME`，不依赖 shell 配置；
> - 服务已在运行时重复执行 `node-start` 是安全的（各组件自身幂等）。

**验证自启**：重启一台 worker 节点（如 hadoop3），开机后约 2~3 分钟执行：

```bash
systemctl status dw-node          # 应显示 exited (RemainAfterExit)
jps | grep -E "DataNode|NodeManager|WorkerServer"
```

---

## 附录：部署完成检查清单

```bash
echo "=== ZK ===";      /opt/zookeeper/bin/zkServer.sh status
echo "=== DS 进程 ===";  bash /opt/dolphinscheduler/bin/status-all.sh
echo "=== 端口 ===";     ss -lntp | grep -E ':(12345|5678|1234|2181) '
echo "=== 配置核对 ==="; grep -H "jdbc:mysql" /opt/dolphinscheduler/*/conf/application.yaml | wc -l   # 应为 5
echo "=== 驱动核对 ==="; ls /opt/dolphinscheduler/*/libs/mysql-connector* | wc -l                      # 应为 5
echo "=== 脚本同步 ==="; for h in hadoop1 hadoop2 hadoop3; do ssh $h "ls /home/cy/scripts"; done
```
