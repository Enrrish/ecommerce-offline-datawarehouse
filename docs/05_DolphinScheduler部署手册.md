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
  sed -i 's|spring.profiles.active: postgresql|spring.profiles.active: mysql|' $f/conf/application.yaml
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
grep -H "profiles.active" api-server/conf/application.yaml master-server/conf/application.yaml \
                          worker-server/conf/application.yaml alert-server/conf/application.yaml
grep -H "jdbc:mysql" */conf/application.yaml tools/conf/application.yaml
grep -H "connect-string" */conf/application.yaml
```

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
# 进程状态
bash /opt/dolphinscheduler/bin/status-all.sh
jps | grep -iE "ApiApplication|MasterServer|WorkerServer|AlertServer"

# 端口
ss -lntp | grep -E ':(12345|5678|1234) '

# 日志（启动慢时看这里）
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

### 7.2 创建项目

项目管理 → 创建项目，名称 `ecommerce_dw`。

### 7.3 创建工作流（ODS → DWD → DWS → ADS 串行）

项目管理 → 工作流 → 工作流定义 → 创建工作流。

**全局参数**（页面右侧"全局参数"）：

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
- **失败策略**：默认"结束"（上游失败则不跑下游，符合分层依赖语义）
- **重试次数**：可设 1~2 次，应对 YARN 瞬时资源不足

**保存工作流时**选择租户 `cy`、执行策略"串行执行"。保存后点**上线**，再点**运行**测试。

### 7.4 定时与补数

- **定时**：工作流定义 → 定时 → 新建，cron 填 `0 10 2 * * ?`（每天 02:10 跑昨天数据）
- **补数**：工作流定义 → 运行 → 补数，选择日期范围一次性回填历史

> 补数时若历史数据量大，优先用脚本自带的 `all` 模式（批量 SQL 比按天循环快约 19 倍，见 `docs/03_踩坑记录.md`）。

### 7.5 验证任务真的跑起来了

```bash
# 任务实例里看日志，确认 bizdate 传参正确、hive 命令能找到
# 日志路径（worker 节点上）：
ls /opt/dolphinscheduler/worker-server/logs/
```

日志里应能看到：`[ODS] bizdate=2019-10-01` 以及各层校验输出。若报 `hive: command not found`，说明 4.2 的 `PATH` 没配好——检查 `bin/env/dolphinscheduler_env.sh` 是否被正确覆盖到 `<server>/conf/dolphinscheduler_env.sh`。

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

---

## 9. 部署完成后的简历可写点

- **调度架构**：3 节点集群部署（1 master + 1 api + 1 alert + 2 worker），ZooKeeper 做注册中心，MySQL 做元数据库
- **依赖编排**：ODS→DWD→DWS→ADS 四层串行依赖，上游失败自动阻断下游，避免脏数据向下游扩散
- **参数化调度**：全局参数 `bizdate=$[yyyy-MM-dd-1]` 实现 T+1 增量调度，支持按日期范围补数
- **故障自愈**：任务级重试 + 分层校验脚本（每层跑完自动核对行数/金额一致性，不一致即返回非零退出码，由调度系统判定失败）
- **资源适配**：针对 5.7G 内存环境将 master/worker 堆内存从 4G 调优至 1G

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
