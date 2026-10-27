# MySQL 知识卡

> 这个项目里 MySQL 不是"业务库"，而是**两块元数据的落脚点**：Hive 的元数据库、DolphinScheduler 的元数据库。
> 所以重点不是写复杂业务 SQL，而是：建库授权、连得上、查得动、出事能定位。

---

## 1. 两个身份

| 身份 | 存什么 | 谁在用 |
|---|---|---|
| Hive Metastore | 库、表、字段、分区、存储路径等元数据 | Hive CLI / 各节点 |
| DolphinScheduler 元数据库 | 项目、工作流定义、实例、任务、调度、租户 | DS 的 api/master/worker |

共同点：**存"描述数据的数据"，不存明细数据**。

一个反直觉但重要的结论：Hive 表里几百亿行，MySQL 里可能只有几万行元数据。**MySQL 挂了，Hive 一行都查不了**——因为连"表在哪"都不知道。

---

## 2. 库、表与字符集

```sql
CREATE DATABASE IF NOT EXISTS demo
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_general_ci;
```

| 概念 | 要点 |
|---|---|
| `utf8` vs `utf8mb4` | MySQL 的 `utf8` 最多 3 字节，存不了 emoji；统一用 `utf8mb4` |
| 排序规则 | `_ci` 不区分大小写，`_bin` 区分 |
| 存储引擎 | 默认 InnoDB：支持事务、行锁、崩溃恢复 |
| 主键 | InnoDB 按主键组织数据（聚簇索引），**主键尽量短、自增** |

---

## 3. 用户、权限与远程访问

```sql
CREATE USER 'app'@'%' IDENTIFIED BY '强密码';
GRANT ALL PRIVILEGES ON demo.* TO 'app'@'%';
FLUSH PRIVILEGES;

-- 只读账号
CREATE USER 'ro'@'%' IDENTIFIED BY '强密码';
GRANT SELECT ON demo.* TO 'ro'@'%';
```

三个容易踩的点：

1. **`'app'@'localhost'` 和 `'app'@'%'` 是两个用户**，远程连不上先看 host；
2. MySQL 5.7 默认启用 `validate_password`（MEDIUM：长度、大小写、数字、特殊字符），密码太简单会直接建用户失败；
3. 远程访问要确认 `bind-address` 不是 `127.0.0.1`，以及防火墙/安全组。

查看现有账号：

```sql
SELECT user, host FROM mysql.user;
SHOW GRANTS FOR 'app'@'%';
```

---

## 4. SQL 基本功

### 四类语句

| 类别 | 语句 | 备注 |
|---|---|---|
| DDL | `CREATE/ALTER/DROP/TRUNCATE` | 隐式提交，不能回滚 |
| DML | `INSERT/UPDATE/DELETE` | 可事务 |
| DQL | `SELECT` | 最常查元数据 |
| DCL | `GRANT/REVOKE` | 权限 |

### JOIN 与聚合

和 Hive 语法基本一致，差异在于：

- MySQL 5.7 **没有窗口函数**（8.0 才有），排名要自己用变量或自关联；
- MySQL 对 `GROUP BY` 较宽松（依赖 `sql_mode`），Hive 也宽松，但**别依赖这个特性**；
- MySQL 有真正的索引，`WHERE` 条件写法直接影响性能。

### 子查询与 EXISTS

```sql
-- 查没有分区信息的表（元数据库排障常用）
SELECT t.TBL_NAME
FROM TBLS t
LEFT JOIN PARTITIONS p ON t.TBL_ID = p.TBL_ID
WHERE p.PART_ID IS NULL;
```

---

## 5. 索引：面试重灾区

### B+ 树与两种索引

| 类型 | 说明 |
|---|---|
| 聚簇索引 | InnoDB 按主键组织整行数据，一张表只有一个 |
| 二级索引 | 叶子节点存"索引列 + 主键"，查非索引列要**回表** |

### 三个关键概念

1. **最左前缀**：联合索引 `(a,b,c)` 能命中 `a`、`a,b`、`a,b,c`，不能命中 `b`、`b,c`；
2. **覆盖索引**：查询的列全在索引里，不用回表，`EXPLAIN` 的 `Extra` 显示 `Using index`；
3. **索引失效**：
   - 索引列上套函数：`WHERE DATE(create_time)='...'`；
   - 隐式类型转换：字符串列用数字查；
   - `LIKE '%x'` 前导通配；
   - `OR` 两边有一边没索引；
   - 优化器判断全表扫描更便宜（数据量小/区分度低）。

### EXPLAIN 看什么

```sql
EXPLAIN SELECT ...;
```

| 列 | 重点 |
|---|---|
| `type` | `const > eq_ref > ref > range > index > ALL`，出现 `ALL` 要警惕 |
| `key` | 实际用了哪个索引，`NULL` 表示没走索引 |
| `rows` | 预估扫描行数 |
| `Extra` | `Using index`（覆盖）、`Using filesort`（额外排序）、`Using temporary`（临时表） |

---

## 6. 事务与隔离级别

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|---|---|---|---|
| READ UNCOMMITTED | 可能 | 可能 | 可能 |
| READ COMMITTED | 否 | 可能 | 可能 |
| **REPEATABLE READ（MySQL 默认）** | 否 | 否 | InnoDB 用间隙锁基本避免 |
| SERIALIZABLE | 否 | 否 | 否 |

- InnoDB 用 **MVCC** 实现一致性读（快照），用**间隙锁/临键锁**处理当前读；
- `SELECT` 是快照读，`SELECT ... FOR UPDATE` 是当前读；
- 长事务会撑大 undo log、阻塞 DDL，生产上要避免。

数仓场景一般不在 MySQL 里跑长事务，但**元数据库**（Hive/DS）自身会用事务，别手动去改它的表。

---

## 7. 运维与排障

### 常用命令

```bash
mysql -h host -P 3306 -u user -p
mysql -N -e "SELECT ..."        # -N 去掉表头，适合脚本
mysql -e "SHOW PROCESSLIST;"
mysql -e "SHOW ENGINE INNODB STATUS\G"
mysqldump -u user -p db > db.sql
```

| 场景 | 命令/表 |
|---|---|
| 连接数打满 | `SHOW VARIABLES LIKE 'max_connections';`、`SHOW PROCESSLIST;` |
| 慢查询 | 开 `slow_query_log`，看 `long_query_time` |
| 锁等待 | `SHOW ENGINE INNODB STATUS` 的 `LATEST DETECTED DEADLOCK` |
| 表空间/容量 | `information_schema.TABLES` 的 `data_length/index_length` |
| binlog | `SHOW BINARY LOGS;`（恢复/主从用） |

### 元数据库表速查

**Hive Metastore**

| 表 | 存什么 |
|---|---|
| `DBS` | 数据库 |
| `TBLS` | 表 |
| `COLUMNS_V2` | 字段 |
| `PARTITIONS` / `PARTITION_KEYS` | 分区 |
| `SDS` | 存储位置、格式、SerDe |

**DolphinScheduler**

| 表 | 存什么 |
|---|---|
| `t_ds_process_definition` | 工作流定义（名称、版本、上线状态） |
| `t_ds_process_instance` | 每次运行/补数 |
| `t_ds_task_instance` | 每个节点的执行状态、起止时间 |
| `t_ds_command` | 待分发命令 |
| `t_ds_schedules` | 定时配置 |
| `t_ds_tenant` | 租户 |

查最近几次运行：

```sql
SELECT id, name, state, start_time, end_time
FROM t_ds_process_instance
ORDER BY id DESC LIMIT 5;
```

> 状态码别死记，直接看 UI；脚本里判断状态时，先确认当前版本的枚举定义。

---

## 8. 为什么明细数据不放 MySQL

| 维度 | MySQL | Hive |
|---|---|---|
| 存储 | 单机行存 | HDFS 分布式列存 |
| 扩展 | 垂直为主 | 水平加节点 |
| 扫描 | 走索引，适合点查 | 全表/分区扫描，适合聚合 |
| 成本 | 高 | 低 |
| 更新 | 行级更新强 | 以覆盖写为主 |

一句话：**MySQL 擅长"找一行"，Hive 擅长"扫一片"**。把亿级明细塞进 MySQL，索引维护和存储成本都会失控。

---

## 9. 项目落点

| 场景 | 用到什么 |
|---|---|
| Hive 元数据 | 建库/建表后元数据落 MySQL，各节点通过 `hive-site.xml` 的 JDBC 连接 |
| DS 元数据 | 工作流、实例、任务状态都在 MySQL，排障时直接查表比翻 UI 快 |
| 建库授权 | 给 Hive/DS 各建独立库和账号，不用 root 跑业务 |
| 连接串 | JDBC 要带 `useSSL=false&serverTimezone=Asia/Shanghai`（否则时区/SSL 报错） |

---

## 10. 自测

1. `utf8` 和 `utf8mb4` 差在哪？为什么统一用后者？
2. `'app'@'localhost'` 和 `'app'@'%'` 有什么区别？远程连不上先查什么？
3. 聚簇索引和二级索引的叶子节点分别存什么？什么是回表？
4. 联合索引 `(a,b,c)` 哪些查询能命中？`WHERE b=1` 为什么不行？
5. `EXPLAIN` 里 `type=ALL`、`Extra=Using filesort` 分别说明什么？
6. MySQL 默认隔离级别是什么？MVCC 解决什么问题？
7. Hive 元数据库里，表名和分区信息分别在哪张表？
8. 为什么不能用 MySQL 存亿级明细？
9. `mysql -N -e` 里的 `-N` 有什么用？为什么脚本里常用？
10. 长事务会带来什么后果？
