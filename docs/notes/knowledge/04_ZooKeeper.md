# ZooKeeper 知识卡

> 项目里 ZK 不是拿来存业务的，而是给 DolphinScheduler 做**注册中心**：
> master/worker 谁活着、任务该发给谁、master 挂了谁接班，都靠它协调。

---

## 1. 一句话定位

ZooKeeper = **高可用的分布式协调服务**，提供"小数据量的强一致存储 + 事件通知 + 分布式锁/选举"。

它适合存：配置、机器列表、锁、选举状态（KB 级）。
它不适合存：业务数据、大文件、需要高吞吐读写的队列。

```
ZK 的数据模型是一棵树，每个节点叫 znode
/
├── dolphinscheduler
│   ├── nodes
│   │   ├── master
│   │   │   └── 192.168.10.129:5678   ← 临时节点，进程挂了自动消失
│   │   └── worker
│   │       ├── 192.168.10.130:1234
│   │       └── 192.168.10.131:1234
│   └── lock
└── zookeeper
    └── quota
```

---

## 2. znode 的四种类型

| 类型 | 生命周期 | 典型用途 |
|---|---|---|
| 持久节点 PERSISTENT | 一直存在，除非显式删除 | 配置、目录结构 |
| 临时节点 EPHEMERAL | 会话结束自动删除 | 服务注册、存活探测 |
| 持久顺序节点 | 持久 + 父节点下自增序号 | 队列、分布式锁排队 |
| 临时顺序节点 | 临时 + 自增序号 | 公平锁、Leader 选举 |

**临时节点是注册中心的核心**：worker 启动时创建临时节点，进程崩溃/断网 → 会话超时 → 节点自动消失 → master 立刻知道这台 worker 不可用。

---

## 3. 集群角色与 ZAB 协议

| 角色 | 职责 |
|---|---|
| Leader | 唯一的写入口，把写请求转成事务提案，广播给 Follower |
| Follower | 参与投票、处理读请求、转发写请求 |
| Observer | 只同步数据、处理读，不参与投票（扩容读能力，不增加选举负担） |

ZAB（ZooKeeper Atomic Broadcast）做两件事：

1. **崩溃恢复**：选主，保证已提交的事务不丢；
2. **消息广播**：Leader 把写请求按顺序广播，超过半数 ACK 才提交。

关键结论：**写是强一致的（线性一致），读默认是本地读**，可能读到稍旧的数据；需要强一致读要先 `sync`。

---

## 4. 为什么节点数要奇数

ZK 的可用性靠"超过半数"（quorum）：

| 节点数 | 容忍挂掉 | 说明 |
|---|---|---|
| 3 | 1 | 剩 2 台仍过半数 |
| 4 | 1 | 和 3 台一样，但多一台成本 |
| 5 | 2 | 剩 3 台仍过半数 |

所以 4 台不比 3 台更可靠，**偶数只会浪费机器**。

反过来：3 台挂 2 台就失去 quorum，集群**只读不可写**（甚至选不出 leader）。这也是为什么三节点集群只剩一台时，DS 会整体不可用。

---

## 5. 会话与 Watch

### 会话（Session）

- 客户端连上集群后建立会话，定期发心跳；
- 会话超时（`sessionTimeout`）内没心跳，ZK 认为客户端死了，删除其临时节点；
- 网络抖动/Full GC 太久都可能触发超时，导致"服务被误判下线"。

### Watch

- 客户端可以在 znode 上注册 Watch（如"子节点变化""数据变化"）；
- 事件触发时 ZK **推送一次**通知；
- **Watch 是一次性的**，想持续监听要在回调里重新注册；
- Watch 只告诉"变了"，不告诉"变成什么"，要自己再读一次。

---

## 6. 在 DolphinScheduler 里的实际作用

| 场景 | ZK 里发生了什么 |
|---|---|
| master 启动 | 注册临时节点，参与选主 |
| worker 启动 | 注册临时节点，master 据此知道有哪些 worker |
| master 宕机 | 临时节点消失，其他 master 抢锁接管 |
| 任务分发 | master 通过注册信息找到可用 worker |
| 故障检测 | 会话超时 → 节点消失 → 触发重新分配 |

所以 DS 的启动顺序是：**ZK 先起 → 再起 master/worker**。ZK 没起来，DS 进程会启动失败或反复重连。

---

## 7. 部署要点

`conf/zoo.cfg`：

```properties
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/home/cy/zookeeper/data
clientPort=2181
server.1=hadoop1:2888:3888
server.2=hadoop2:2888:3888
server.3=hadoop3:2888:3888
```

三个端口各司其职：

| 端口 | 用途 |
|---|---|
| 2181 | 客户端连接 |
| 2888 | 集群内部数据同步（Follower 连 Leader） |
| 3888 | 选举通信 |

每台机器的 `dataDir/myid` 必须写自己的编号（1/2/3），**myid 写错是最常见的起不来原因**。

---

## 8. 运维命令

```bash
zkServer.sh start | stop | status
zkServer.sh status          # 显示 leader / follower
zkCli.sh -server hadoop1:2181
```

`zkCli.sh` 常用：

```bash
ls /dolphinscheduler/nodes/worker
get /path
stat /path
delete /path
```

四字命令（3.5+ 默认只开放部分，`mntr` 等需要在 `4lw.commands.whitelist` 里显式加上）：

```bash
echo ruok | nc hadoop1 2181   # 返回 imok 表示进程活着
echo mntr | nc hadoop1 2181   # 监控指标
echo stat | nc hadoop1 2181   # 角色、连接数
```

---

## 9. 常见故障

| 现象 | 原因 | 排查 |
|---|---|---|
| 三台都起不来 | `myid` 缺失/重复、`dataDir` 权限 | 看 `zookeeper.out` |
| 只有一台是 leader，其他连不上 | 2888/3888 被防火墙拦 | `telnet host 2888` |
| 集群反复选主 | 机器时间不同步、网络抖动 | 校时、看 GC 日志 |
| 客户端频繁 session expired | GC 停顿过长、网络不稳 | 调大 `sessionTimeout`、查 Full GC |
| 磁盘写满 | 快照/事务日志撑爆 | 清 `dataDir/version-2`、加磁盘 |
| `ruok` 无返回 | 进程假死/端口不通 | `jps`、`netstat`、看日志 |

> ZK 的数据目录不要和 Hadoop 数据目录共用一块快满的盘，事务日志写不进去会直接失去 quorum。

---

## 10. 面试问答

**Q：ZK 是 CP 还是 AP？**
CP。失去 quorum 时宁可不可用，也不返回不一致的数据。

**Q：为什么需要奇数台？**
quorum = n/2 + 1；偶数台不增加容错，只增加成本。

**Q：ZK 能当数据库用吗？**
不能。数据全放内存、写要过半 ACK、单 znode 有大小限制，只适合协调类小数据。

**Q：Watch 有什么坑？**
一次性触发；只通知变化不传新值；大量 Watch 同时触发会有"羊群效应"。

**Q：临时节点什么时候消失？**
会话结束（主动 close 或超时）。注意是**会话**，不是 TCP 连接——连接断了但会话没超时，节点还在。

---

## 11. 自测

1. 持久节点、临时节点、顺序节点各适合什么场景？
2. 为什么 3 台挂 1 台还能写，挂 2 台就不能写？
3. ZK 的写请求为什么要经过 Leader？"过半 ACK"解决什么问题？
4. 2888 和 3888 分别做什么？
5. `myid` 写错会出现什么现象？
6. Watch 为什么是一次性的？怎么持续监听？
7. DS 的 worker 宕机后，master 是怎么知道的？
8. 为什么 ZK 不适合存业务数据？
9. 会话超时和 TCP 断开是一回事吗？
10. ZK 只剩一台时，DS 为什么也用不了？
