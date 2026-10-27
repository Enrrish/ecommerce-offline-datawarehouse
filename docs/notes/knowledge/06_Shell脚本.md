# Shell 脚本知识卡

> 数仓里 Shell 是"胶水"：接参数、调 Hive、判结果、写日志、返回退出码。
> 调度系统不关心你脚本多优雅，只关心三件事：**能不能重复跑、失败能不能发现、日志能不能看懂。**

---

## 1. 一个脚本的职责边界

| 该做 | 不该做 |
|---|---|
| 参数校验、日期计算 | 把复杂 SQL 拼成字符串（放 `.sql` 文件） |
| 调 Hive、捕获输出、判断成败 | 在 Shell 里做大规模数据计算（用 awk 只做小结果校验） |
| 记录日志、清理临时文件 | 交互式等待用户输入（调度环境没人点回车） |
| 用退出码表达结果 | 失败还 `exit 0` |

---

## 2. 最小可用模板

```bash
#!/bin/bash
set -euo pipefail

# 可被环境变量覆盖，便于测试
DB="${DB:-mydb}"
WORK="${WORK:-/tmp/job_$$}"       # $$ = 当前进程号，避免并发冲突
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT        # 无论成功失败都清理

log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

MODE="${1:-all}"

if [ "$MODE" = "all" ]; then
    log "全量模式"
else
    log "单天模式: $MODE"
fi
```

三行严格模式分别做什么：

| 选项 | 作用 | 坑 |
|---|---|---|
| `-e` | 命令失败立即退出 | `grep` 没匹配也返回非 0，会误退出 |
| `-u` | 用未定义变量报错 | 要用 `${VAR:-}` 兜底 |
| `-o pipefail` | 管道中任一环失败即失败 | 不加的话只看最后一个命令 |

---

## 3. 变量与引号

```bash
NAME="value"
echo "$NAME"          # 永远加双引号
echo "${NAME}"        # 明确变量边界
```

| 写法 | 含义 |
|---|---|
| `${VAR:-default}` | 未设置或为空时用默认值 |
| `${VAR:=default}` | 未设置时赋值 |
| `${VAR:?msg}` | 未设置就报错退出 |
| `${#VAR}` | 字符串长度 |
| `${VAR%.*}` | 去掉最后一个 `.` 及之后 |
| `${VAR##*/}` | 取文件名（去掉目录） |
| `${VAR//a/b}` | 全部替换 |

**不加引号的后果**：变量里有空格会被拆成多个参数；为空时参数直接消失。

```bash
rm -rf $DIR/          # DIR 为空 → rm -rf / ，灾难
rm -rf "${DIR:?}/"    # DIR 为空 → 直接报错退出
```

---

## 4. 条件判断

```bash
if [ "$A" = "$B" ]; then ...; fi
if [[ "$A" == *.csv ]]; then ...; fi
if [ "$N" -gt 0 ] && [ "$M" -lt 10 ]; then ...; fi
```

| 判断 | 数值 | 字符串 | 文件 |
|---|---|---|---|
| 相等 | `-eq` | `=` / `==` | |
| 不等 | `-ne` | `!=` | |
| 大于 | `-gt` | `>`（`[[ ]]` 里） | |
| 存在 | | | `-e` |
| 是文件 | | | `-f` |
| 是目录 | | | `-d` |
| 可读/可写/可执行 | | | `-r` / `-w` / `-x` |

`[ ]` 是 POSIX，`[[ ]]` 是 bash 扩展（支持 `&&`、`||`、正则 `=~`、通配）。脚本声明了 `#!/bin/bash` 就优先用 `[[ ]]`。

---

## 5. 循环、数组与 mapfile

```bash
# 数组
DAYS=("2024-01-01" "2024-01-02")
echo "${#DAYS[@]}"        # 元素个数
for d in "${DAYS[@]}"; do echo "$d"; done

# 把命令输出读进数组（推荐）
mapfile -t DAYS < <(hive -e "SHOW PARTITIONS t" | sed 's/^dt=//')

# 按行读文件（保留反斜杠、保留空白）
while IFS=$'\t' read -r dt cnt; do
    echo "$dt $cnt"
done < manifest.txt
```

要点：

- `"${ARGS[@]}"` 要加引号，否则含空格的元素会被拆开；
- `for f in $(ls)` 不要用，文件名有空格就炸；用 `for f in *.csv`；
- `< <(...)` 是进程替换，把命令输出当文件用；
- `read` 一定加 `-r`，否则反斜杠会被转义。

---

## 6. 函数

```bash
run_hive() {
    local sql_file="$1" dt="${2:-}"
    local out
    out=$(hive -f "$sql_file" --hivevar bizdate="$dt" 2>&1) || return 1
    echo "$out"
}
```

- `local` 只在函数内有效，避免污染全局；
- 函数返回用 `return`（0-255），取输出用 `$(...)`；
- 不要把大段逻辑塞进函数，脚本也要可读。

---

## 7. 参数解析

```bash
MODE="${1:-all}"        # 第一个参数，默认 all
shift                   # 消费掉第一个参数
```

多参数/选项用 `getopts`：

```bash
while getopts "d:t:h" opt; do
    case "$opt" in
        d) DATE="$OPTARG" ;;
        t) TABLE="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
```

调度脚本一般很简单：**一个日期参数 + all/check 模式**，不需要复杂解析。

---

## 8. 文本处理：grep / sed / awk

### grep：判断和过滤

```bash
grep -q "pattern" file            # 只判断，不输出
grep -E "FAILED|Exception" log    # 扩展正则
grep -c "pattern" file            # 数行，不是数次！
grep -v "pattern" file            # 排除
```

**项目坑**：`grep -A5 "Live datanodes" | grep -c "hadoop"` 会数错——`-A5` 窗口只覆盖第一个节点，`-c` 数的是行数不是匹配次数。能取现成统计值就别自己拼。

### sed：替换

```bash
sed -i 's/\r$//' file              # 去 CRLF
sed -n '1,10p' file                # 打印前 10 行
sed -i 's/old/new/g' file
```

### awk：按列处理、求和、比较

```bash
awk '{s+=$2} END{print s}' file                 # 求和
awk -F',' '$1=="x"{print $2}' file              # 按分隔符取列
awk -v d="$DT" '$1==d{print $2; exit}' file     # 传变量、匹配
```

三者的分工：

| 工具 | 最适合 |
|---|---|
| grep | 找行、判断存在 |
| sed | 行级替换、删除 |
| awk | 按列取值、聚合、格式化 |

---

## 9. 调 Hive 的固定套路

```bash
# 1. 执行 SQL 文件，传业务日期
OUT=$(hive -f "$SQL" --hivevar bizdate="$DT" 2>&1)

# 2. 判断失败（Hive 不一定返回非 0，必须看输出）
if echo "$OUT" | grep -qiE "FAILED|SemanticException|ParseException|Execution Error"; then
    echo "[FAIL] $DT"
    echo "$OUT" | grep -iE "error|exception" | head -3
    exit 1
fi

# 3. 只要数据、不要日志
hive -S -e "SELECT ..." 2>/dev/null | grep -E '^[0-9]{4}-'

# 4. 批量执行 SQL（避免循环启 JVM）
{ echo "USE $DB;"; echo "SELECT ...;"; } > "$WORK/check.sql"
hive -f "$WORK/check.sql"
```

关键点：

- `2>&1` 把 stderr 合进 stdout，否则报错信息会漏；
- `grep -qi`：`-q` 不输出、`-i` 忽略大小写；
- `-S` 静默模式，适合取数；
- 生成的 SQL 放临时文件，别拼一长串字符串。

---

## 10. 错误处理与退出码

| 退出码 | 含义 | 调度侧怎么处理 |
|---|---|---|
| 0 | 成功 | 继续下游 |
| 1 | 脚本自判失败 | 看日志里的 `[FAIL]` |
| 2 | 用法错误/参数错 | 改调度参数 |
| 126 | 无执行权限 | `chmod +x` |
| 127 | 命令/文件不存在 | 查 PATH、路径 |
| 130 | Ctrl+C | 手动中断 |
| 137 | SIGKILL（128+9） | 通常 OOM |
| 143 | SIGTERM（128+15） | 通常超时被杀 |

脚本结尾必须显式返回：

```bash
if [ "$BAD" -eq 0 ]; then
    echo "[PASS]"
    exit 0
else
    echo "[FAIL] $BAD 项不通过"
    exit 1
fi
```

**不要**在失败后还走到 `exit 0`——调度会以为成功，下游继续跑脏数据。

---

## 11. 日志、临时文件与并发

```bash
WORK="$(mktemp -d /tmp/job.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

LOG="$WORK/run.log"
exec > >(tee -a "$LOG") 2>&1     # 同时输出到屏幕和文件（bash）
```

- 用 `$$` 或 `mktemp` 隔离并发任务的临时文件；
- 日志统一前缀 `[INFO]/[OK]/[FAIL]`，grep 友好；
- 长任务用 `nohup cmd > log 2>&1 &`，再轮询日志，避免 SSH 超时。

---

## 12. 远程执行与后台任务

```bash
ssh -o ConnectTimeout=8 host "source /etc/profile; hadoop version"

nohup bash job.sh > /tmp/job.log 2>&1 &
tail -f /tmp/job.log
```

两个坑：

1. **非交互 SSH 不加载 `.bashrc`**，环境变量要显式 `source /etc/profile` 或在命令里 export；
2. 前台长任务超过 SSH/工具超时会被 SIGTERM，**任务可能还在集群上跑**，重复提交会造成数据混乱。

---

## 13. 常见坑清单

| 坑 | 现象 | 解法 |
|---|---|---|
| CRLF | `bad interpreter: /bin/bash^M` | `sed -i 's/\r$//'`，仓库加 `.gitattributes` |
| 变量不加引号 | 参数被拆开/为空时命令变形 | `"$VAR"`、`"${ARR[@]}"` |
| `set -e` + grep | grep 没匹配，脚本直接退出 | 用 `if grep -q ...; then` 包住，不要裸跑 grep |
| `set -u` + 空变量 | `unbound variable` | `${VAR:-}` |
| `grep -c` | 数的是行不是次数 | 改用 `grep -o` 统计次数，或直接取现成统计值 |
| 任务运行中覆盖脚本 | `$'\204...': 未找到命令` | 等任务结束再改，或写新文件 |
| `rm -rf $DIR` | DIR 为空时删根 | `${DIR:?}` + 引号 |
| `cd` 失败还继续 | 后续命令在错误目录执行 | `cd "$DIR"` 后判断返回值，失败就退出 |
| 算术 `((i++))` | i=0 时返回 1，`set -e` 退出 | `i=$((i+1))` |
| 中文乱码 | 日志里 `???` | 统一 UTF-8，设置 `LANG` |
| 覆盖 `/tmp` 固定文件名 | 并发任务互相踩 | `$$` / `mktemp` |

---

## 14. 练习清单（照着项目改一遍）

1. 写一个 `check_partition.sh`：参数是日期，检查分区是否存在、行数是否大于 0，失败 `exit 1`；
2. 把一段"按天循环跑 Hive"的脚本改成"参数校验 + 失败继续 + 最后汇总失败数"；
3. 用 `awk` 从 `SHOW PARTITIONS` 的输出里提取日期并排序；
4. 给脚本加 `trap`，保证异常退出也清理临时目录；
5. 用 `getopts` 支持 `-d 日期` 和 `-m all|day` 两个参数；
6. 故意制造一次 Hive 报错，确认脚本能捕获并返回非 0。

---

## 15. 自测

1. `set -euo pipefail` 三个选项分别解决什么问题？各有什么坑？
2. `"$@"` 和 `$*` 的区别？为什么数组要加引号？
3. `[ ]` 和 `[[ ]]` 有什么区别？
4. `grep -c` 数的是什么？为什么自检脚本会被它坑？
5. `hive -f` 失败一定会返回非 0 吗？脚本应该怎么判断？
6. `2>&1` 的作用是什么？不加会怎样？
7. 退出码 127、137、143 分别代表什么？
8. 为什么临时文件要用 `$$` 或 `mktemp`？
9. 非交互 SSH 为什么不加载 `.bashrc`？怎么解决？
10. 任务运行中覆盖脚本，为什么会出现乱码命令？
11. `rm -rf $DIR/` 在 `DIR` 为空时会发生什么？怎么防？
12. 长任务为什么要 `nohup`？前台超时后任务真的停了吗？
