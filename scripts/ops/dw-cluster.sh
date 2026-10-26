#!/bin/bash
# ==============================================================================
# dw-cluster.sh —— 电商离线数仓集群一键启停 / 状态查看 / 深度自检
#
# 用法（全集群命令在 hadoop1 上执行；node-* 供 systemd 在各节点调用）：
#   bash dw-cluster.sh start       # 全链路启动: ZK -> HDFS/YARN -> DS master/api/alert -> DS worker
#   bash dw-cluster.sh stop        # 逆序停止
#   bash dw-cluster.sh restart     # 先 stop 再 start
#   bash dw-cluster.sh status      # 快速状态（进程与端口）
#   bash dw-cluster.sh check       # 深度自检（含 UI 探活、worker 拒单检测、HDFS/YARN 报告）
#   bash dw-cluster.sh node-start  # 只启动本机服务（systemd 开机自启用）
#   bash dw-cluster.sh node-stop   # 只停止本机服务
#
# 依赖：hadoop1 -> hadoop2/3 SSH 免密；环境变量在脚本内显式 export
#      （systemd 环境不加载 ~/.bashrc，不能依赖它）
# ==============================================================================
set -u

# ---------- 集群定义 ----------
HOSTS=(hadoop1 hadoop2 hadoop3)
MASTER_HOST=hadoop1
WORKER_HOSTS=(hadoop2 hadoop3)
DS_HOME=/opt/dolphinscheduler
ZK_HOME=/opt/zookeeper
HADOOP_HOME=/opt/hadoop
DS_SERVICES_MASTER="master-server api-server alert-server"

export JAVA_HOME=/opt/jdk
export HADOOP_HOME
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"

# ---------- 输出 ----------
C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_O='\033[0m'
ok()   { echo -e "  [ ${C_G}OK${C_O}   ] $*"; }
fail() { echo -e "  [ ${C_R}FAIL${C_O} ] $*"; }
warn() { echo -e "  [ ${C_Y}WARN${C_O} ] $*"; }
hr()   { echo "----------------------------------------------------------------"; }

CHECK_FAILS=0
record_fail() { CHECK_FAILS=$((CHECK_FAILS+1)); }

# ---------- 工具 ----------
# 等待 TCP 端口就绪: wait_port <host> <port> [超时秒]
wait_port() {
  local host=$1 port=$2 timeout=${3:-60} i=0
  until (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; do
    sleep 2; i=$((i+2))
    [ "$i" -ge "$timeout" ] && return 1
  done
  return 0
}

# 远程执行（保证 JAVA_HOME，避免 ssh 环境差异）
rssh() { ssh -o ConnectTimeout=8 "$1" "export JAVA_HOME=/opt/jdk; $2"; }

ds_daemon() { # <host> <start|stop|status> <service>
  rssh "$1" "$DS_HOME/bin/dolphinscheduler-daemon.sh $2 $3" >/dev/null 2>&1
}

# ==============================================================================
# 全集群启动（在 hadoop1 执行）
# ==============================================================================
cmd_start() {
  echo "== [1/5] ZooKeeper（3 节点）=="
  for h in "${HOSTS[@]}"; do
    rssh "$h" "$ZK_HOME/bin/zkServer.sh start" >/dev/null 2>&1 \
      && ok "$h zookeeper 启动指令已发" || fail "$h zookeeper 启动失败"
  done
  local ready=0 i
  for i in $(seq 1 15); do
    ready=0
    for h in "${HOSTS[@]}"; do
      rssh "$h" "$ZK_HOME/bin/zkServer.sh status" >/dev/null 2>&1 && ready=$((ready+1))
    done
    [ "$ready" -ge 2 ] && break
    sleep 2
  done
  if [ "$ready" -ge 2 ]; then ok "ZooKeeper quorum 就绪（$ready/3 节点在线）"
  else fail "ZooKeeper 未达 quorum（$ready/3），后续启动可能异常"; fi

  echo "== [2/5] HDFS / YARN =="
  rssh "$MASTER_HOST" "$HADOOP_HOME/sbin/start-dfs.sh"  >/dev/null 2>&1 && ok "start-dfs.sh"  || fail "start-dfs.sh"
  rssh "$MASTER_HOST" "$HADOOP_HOME/sbin/start-yarn.sh" >/dev/null 2>&1 && ok "start-yarn.sh" || fail "start-yarn.sh"

  echo "== [3/5] 等待 HDFS 退出 safemode =="
  local safe=""
  for i in $(seq 1 30); do
    safe=$(hdfs dfsadmin -safemode get 2>/dev/null | grep -o 'ON\|OFF')
    [ "$safe" = "OFF" ] && break
    sleep 2
  done
  [ "$safe" = "OFF" ] && ok "safemode OFF" || warn "safemode 仍未退出（60s），请手动 hdfs dfsadmin -safemode leave"

  echo "== [4/5] DolphinScheduler master / api / alert（$MASTER_HOST）=="
  local s
  for s in $DS_SERVICES_MASTER; do
    ds_daemon "$MASTER_HOST" start "$s" && ok "$s" || fail "$s"
  done
  if wait_port "$MASTER_HOST" 12345 90; then ok "api-server 端口 12345 就绪"
  else warn "api-server 90s 未监听 12345，查 $DS_HOME/api-server/logs/"; fi

  echo "== [5/5] DolphinScheduler worker =="
  for h in "${WORKER_HOSTS[@]}"; do
    ds_daemon "$h" start worker-server && ok "$h worker-server" || fail "$h worker-server"
  done

  echo; hr; cmd_check
}

# ==============================================================================
# 全集群停止（在 hadoop1 执行，逆序）
# ==============================================================================
cmd_stop() {
  echo "== [1/4] 停止 DS worker =="
  local h s
  for h in "${WORKER_HOSTS[@]}"; do
    ds_daemon "$h" stop worker-server && ok "$h worker-server 已停" || fail "$h worker-server"
  done
  echo "== [2/4] 停止 DS master / api / alert =="
  for s in $DS_SERVICES_MASTER; do
    ds_daemon "$MASTER_HOST" stop "$s" && ok "$s 已停" || fail "$s"
  done
  echo "== [3/4] 停止 YARN / HDFS =="
  rssh "$MASTER_HOST" "$HADOOP_HOME/sbin/stop-yarn.sh" >/dev/null 2>&1 && ok "stop-yarn.sh" || fail "stop-yarn.sh"
  rssh "$MASTER_HOST" "$HADOOP_HOME/sbin/stop-dfs.sh"  >/dev/null 2>&1 && ok "stop-dfs.sh"  || fail "stop-dfs.sh"
  echo "== [4/4] 停止 ZooKeeper =="
  for h in "${HOSTS[@]}"; do
    rssh "$h" "$ZK_HOME/bin/zkServer.sh stop" >/dev/null 2>&1 && ok "$h zookeeper 已停" || fail "$h zookeeper"
  done
}

# ==============================================================================
# 深度自检（在 hadoop1 执行）
# ==============================================================================
cmd_check() {
  CHECK_FAILS=0
  local h s line

  echo "---------- 1. ZooKeeper ----------"
  for h in "${HOSTS[@]}"; do
    line=$(rssh "$h" "$ZK_HOME/bin/zkServer.sh status" 2>/dev/null | grep -o 'Mode: .*')
    if [ -n "$line" ]; then ok "$h $line"
    else fail "$h zookeeper 无响应"; record_fail; fi
  done

  echo "---------- 2. MySQL（元数据库）----------"
  if (exec 3<>"/dev/tcp/$MASTER_HOST/3306") 2>/dev/null; then
    ok "hadoop1:3306 可达"
  else fail "hadoop1:3306 不可达（DS 全部服务会受影响）"; record_fail; fi

  echo "---------- 3. HDFS ----------"
  local safe live
  safe=$(hdfs dfsadmin -safemode get 2>/dev/null | grep -o 'ON\|OFF')
  live=$(hdfs dfsadmin -report 2>/dev/null | grep -A5 "Live datanodes" | grep -cE "hadoop[0-9]")
  if [ "$safe" = "OFF" ] && [ "$live" -ge 2 ]; then
    ok "safemode OFF，Live datanodes = $live/3"
  else
    fail "safemode=$safe，Live datanodes=$live/3"; record_fail
  fi

  echo "---------- 4. YARN ----------"
  local nm
  nm=$(yarn node -list -all 2>/dev/null | grep -cE "hadoop[0-9]:")
  if [ "$nm" -ge 2 ]; then ok "NodeManager 在线 $nm/3"
  else fail "NodeManager 在线 $nm/3"; record_fail; fi

  echo "---------- 5. DolphinScheduler 进程 ----------"
  for s in $DS_SERVICES_MASTER; do
    line=$(rssh "$MASTER_HOST" "$DS_HOME/bin/dolphinscheduler-daemon.sh status $s" 2>/dev/null | grep -c RUNNING)
    if [ "$line" -ge 1 ]; then ok "$MASTER_HOST $s RUNNING"
    else fail "$MASTER_HOST $s 未运行"; record_fail; fi
  done
  for h in "${WORKER_HOSTS[@]}"; do
    line=$(rssh "$h" "$DS_HOME/bin/dolphinscheduler-daemon.sh status worker-server" 2>/dev/null | grep -c RUNNING)
    if [ "$line" -ge 1 ]; then ok "$h worker-server RUNNING"
    else fail "$h worker-server 未运行"; record_fail; fi
  done

  echo "---------- 6. DS 端口与 UI ----------"
  for spec in "$MASTER_HOST:12345" "$MASTER_HOST:5678" "${WORKER_HOSTS[0]}:1234" "${WORKER_HOSTS[1]}:1234"; do
    local hp=${spec#*:} hh=${spec%%:*}
    if (exec 3<>"/dev/tcp/$hh/$hp") 2>/dev/null; then ok "$hh:$hp 监听中"
    else fail "$hh:$hp 未监听"; record_fail; fi
  done
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://$MASTER_HOST:12345/dolphinscheduler/ui/")
  if [ "$code" = "200" ]; then ok "UI http://$MASTER_HOST:12345/dolphinscheduler/ui/ -> 200"
  else fail "UI 返回 $code"; record_fail; fi

  echo "---------- 7. worker 过载保护（任务不执行的隐形杀手）----------"
  # 只统计最近 10 分钟的 OverLoad，避免改阈值前的历史日志一直报 WARN
  local cutoff
  cutoff=$(date -d '10 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '1970-01-01 00:00:00')
  for h in "${WORKER_HOSTS[@]}"; do
    local n
    n=$(rssh "$h" "awk -v cut='$cutoff' '{ts=\$4\" \"substr(\$5,1,8)} ts>=cut && /OverLoad/{c++} END{print c+0}' $DS_HOME/worker-server/logs/dolphinscheduler-worker.log 2>/dev/null")
    if [ "${n:-0}" -eq 0 ]; then ok "$h 最近10分钟无 OverLoad"
    else warn "$h 最近10分钟出现 $n 次 OverLoad（内存阈值拦截，见部署手册 4.6 节）"; record_fail; fi
  done

  echo; hr
  if [ "$CHECK_FAILS" -eq 0 ]; then
    echo -e "自检结果：${C_G}全部通过${C_O}（$CHECK_FAILS 项失败）"
  else
    echo -e "自检结果：${C_R}$CHECK_FAILS 项异常${C_O}，见上方 FAIL/WARN"
  fi
  return 0
}

# ==============================================================================
# 本机服务启停（systemd 调用入口，按主机名自动判断角色）
# ==============================================================================
cmd_node_start() {
  local host; host=$(hostname)
  echo "[node-start] $host"

  # 1) ZooKeeper（所有节点）
  "$ZK_HOME/bin/zkServer.sh" start >/dev/null 2>&1
  if wait_port localhost 2181 60; then echo "[node-start] zookeeper 就绪"
  else echo "[node-start] zookeeper 60s 未就绪，继续尝试后续服务"; fi

  if [ "$host" = "$MASTER_HOST" ]; then
    # 2) Hadoop（start-dfs/start-yarn 会自动 ssh 拉起从节点 DN/NM）
    "$HADOOP_HOME/sbin/start-dfs.sh"  >/dev/null 2>&1
    "$HADOOP_HOME/sbin/start-yarn.sh" >/dev/null 2>&1
    local i safe=""
    for i in $(seq 1 30); do
      safe=$(hdfs dfsadmin -safemode get 2>/dev/null | grep -o 'ON\|OFF')
      [ "$safe" = "OFF" ] && break; sleep 2
    done
    # 3) DS master 侧（MySQL 由 systemd 的 After=mysqld 保证已就绪）
    local s
    for s in $DS_SERVICES_MASTER; do
      "$DS_HOME/bin/dolphinscheduler-daemon.sh" start "$s" >/dev/null 2>&1
    done
    wait_port localhost 12345 120 && echo "[node-start] api-server 就绪" \
      || echo "[node-start] api-server 未在 120s 内就绪"
  else
    # worker：等 MySQL（hadoop1:3306）就绪再起，避免连库失败
    if wait_port "$MASTER_HOST" 3306 120; then echo "[node-start] MySQL 可达"
    else echo "[node-start] MySQL 120s 不可达，仍尝试启动 worker"; fi
    "$DS_HOME/bin/dolphinscheduler-daemon.sh" start worker-server >/dev/null 2>&1

    # 补起 DN/NM：若 hadoop1 的 start-dfs.sh 先于本机开机执行，ssh 会失败，
    # 本机 DataNode/NodeManager 会缺席，这里兜底补起（Hadoop 3.1.3，幂等）
    if wait_port "$MASTER_HOST" 22 120; then
      sleep 15   # 给 hadoop1 的 start-dfs 留出 ssh 拉起时间，避免重复起
      jps | grep -q DataNode     || "$HADOOP_HOME/bin/hdfs"  --daemon start datanode     2>/dev/null
      jps | grep -q NodeManager  || "$HADOOP_HOME/bin/yarn"  --daemon start nodemanager  2>/dev/null
      echo "[node-start] DN/NM 已确认"
    fi
  fi
  echo "[node-start] 完成"
}

cmd_node_stop() {
  local host; host=$(hostname)
  echo "[node-stop] $host"
  if [ "$host" = "$MASTER_HOST" ]; then
    local s
    for s in $DS_SERVICES_MASTER; do
      "$DS_HOME/bin/dolphinscheduler-daemon.sh" stop "$s" >/dev/null 2>&1
    done
    "$HADOOP_HOME/sbin/stop-yarn.sh" >/dev/null 2>&1
    "$HADOOP_HOME/sbin/stop-dfs.sh"  >/dev/null 2>&1
  else
    "$DS_HOME/bin/dolphinscheduler-daemon.sh" stop worker-server >/dev/null 2>&1
  fi
  "$ZK_HOME/bin/zkServer.sh" stop >/dev/null 2>&1
  echo "[node-stop] 完成"
}

# ==============================================================================
# 快速状态
# ==============================================================================
cmd_status() {
  echo "===== 各节点 Java 进程 ====="
  for h in "${HOSTS[@]}"; do
    echo "--- $h ---"
    rssh "$h" "jps 2>/dev/null | grep -viE '^[0-9]+ Jps'" | sed 's/^/    /'
  done
  echo "===== DS 服务状态 ====="
  for s in $DS_SERVICES_MASTER; do
    printf "    %-14s " "$MASTER_HOST $s:"
    rssh "$MASTER_HOST" "$DS_HOME/bin/dolphinscheduler-daemon.sh status $s" 2>/dev/null | grep -o 'RUNNING\|STOP' | head -1
  done
  for h in "${WORKER_HOSTS[@]}"; do
    printf "    %-14s " "$h worker-server:"
    rssh "$h" "$DS_HOME/bin/dolphinscheduler-daemon.sh status worker-server" 2>/dev/null | grep -o 'RUNNING\|STOP' | head -1
  done
}

# ==============================================================================
# 入口
# ==============================================================================
case "${1:-}" in
  start)     [ "$(hostname)" = "$MASTER_HOST" ] || { echo "start/stop/status/check 请在 $MASTER_HOST 上执行"; exit 1; }; cmd_start ;;
  stop)      [ "$(hostname)" = "$MASTER_HOST" ] || { echo "start/stop/status/check 请在 $MASTER_HOST 上执行"; exit 1; }; cmd_stop ;;
  restart)   [ "$(hostname)" = "$MASTER_HOST" ] || { echo "start/stop/status/check 请在 $MASTER_HOST 上执行"; exit 1; }; cmd_stop; sleep 5; cmd_start ;;
  status)    [ "$(hostname)" = "$MASTER_HOST" ] || { echo "start/stop/status/check 请在 $MASTER_HOST 上执行"; exit 1; }; cmd_status ;;
  check)     [ "$(hostname)" = "$MASTER_HOST" ] || { echo "start/stop/status/check 请在 $MASTER_HOST 上执行"; exit 1; }; cmd_check ;;
  node-start) cmd_node_start ;;
  node-stop)  cmd_node_stop ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
