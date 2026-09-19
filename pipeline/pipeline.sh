#!/usr/bin/env bash
# =============================================================================
# 值班/交接本地流水线（IoT Geofence Monitor）
#
# 把“依赖检查 -> 依赖准备 -> 构建 -> 清理旧进程 -> 启动两端 -> 就绪确认”
# 串成一条流水线，统一环境、统一日志，任一环节失败立即中止并指明环节与原因。
#
# 常用命令：
#   ./pipeline/pipeline.sh up                 # 完整流水线（默认，后台启动两端）
#   ./pipeline/pipeline.sh up --foreground    # 同上，但前台跟随两端日志，Ctrl-C 停止
#   ./pipeline/pipeline.sh stop               # 停止流水线启动的进程
#   ./pipeline/pipeline.sh restart            # 停止后重新执行完整流水线
#   ./pipeline/pipeline.sh status             # 查看两端运行/就绪状态
#   ./pipeline/pipeline.sh logs [backend|frontend]   # 查看服务日志
#   ./pipeline/pipeline.sh check              # 只做依赖检查 + 构建（不启动）
#
# 常用选项：
#   --force-ports   端口被流水线之外的进程占用时，一并终止（默认只提示不擅杀）
#   --force-install 强制重新准备依赖（go mod download / npm ci）
#   --offline       依赖准备阶段禁止联网，只用本机缓存
#
# 退出码：
#   0 成功；10 依赖检查；20 依赖准备；30 构建；40 端口冲突；50 启动；60 就绪确认
# =============================================================================

set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"

PIPELINE_DIR="$ROOT_DIR/.pipeline"
RUN_DIR="$PIPELINE_DIR/run"
LOG_DIR="$PIPELINE_DIR/logs"
BIN_DIR="$PIPELINE_DIR/bin"
BACKEND_BIN="$BIN_DIR/backend-server"
BACKEND_PID_FILE="$RUN_DIR/backend.pid"
FRONTEND_PID_FILE="$RUN_DIR/frontend.pid"
PIPELINE_LOG="$LOG_DIR/pipeline.log"
HANDOFF_FILE="$PIPELINE_DIR/HANDOFF.md"

BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
LISTEN_HOST="${LISTEN_HOST:-127.0.0.1}"
BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-http://${LISTEN_HOST}:${BACKEND_PORT}/api/health}"
FRONTEND_READY_URL="${FRONTEND_READY_URL:-http://${LISTEN_HOST}:${FRONTEND_PORT}/}"
# 通过 vite 代理访问后端，确认“两端确实串通”
E2E_HEALTH_URL="http://127.0.0.1:${FRONTEND_PORT}/api/health"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
READY_INTERVAL=1
# Go 代理：尊重已有 GOPROXY，默认值仅在未设置时生效（国内网络可 export GOPROXY=https://goproxy.cn,direct）
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOFLAGS="${GOFLAGS:-}"

FORCE_PORTS=0
FORCE_INSTALL=0
OFFLINE=0
FOREGROUND=0
STAGE_CURRENT="init"
START_TS=$(date +%s)
RUN_ID=$(date +%Y%m%d-%H%M%S)-$$
SERVICES_STARTED=0
PIPELINE_ACTION="up"

# EXIT 兜底：
# - check：从不启动服务，无需回收；
# - 任一步失败（含 start 中途失败、被 kill、就绪超时）：按 pid 文件回收，不留残留；
# - 前台模式退出：回收；
# - 后台 up/restart 成功交付（code=0）：不回收，服务继续运行。
cleanup_on_exit() {
  local code=$?
  [ "$PIPELINE_ACTION" = "check" ] && return 0
  if [ "$FOREGROUND" -eq 1 ] || [ $code -ne 0 ]; then
    echo "${C_DIM}   [exit] 回收已启动的流水线进程...${C_RESET}"
    stop_services 1
    rm -f "$BACKEND_PID_FILE" "$FRONTEND_PID_FILE"
  fi
}
trap cleanup_on_exit EXIT

# ----------------------------------------------------------------------------
# 输出与阶段记录
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

STAGE_NAMES=(); STAGE_STATUS=()

stage_begin() {
  STAGE_CURRENT="$1"
  echo "${C_BLUE}${C_BOLD}== [$STAGE_CURRENT]${C_RESET} $2"
}

stage_ok() {
  echo "${C_GREEN}   ✓ [$STAGE_CURRENT]${C_RESET} $1"
  local key="${STAGE_DETAIL_KEY:-$STAGE_CURRENT}"
  STAGE_NAMES+=("$key"); STAGE_STATUS+=("OK")
}

stage_skip() {
  echo "${C_DIM}   - [$STAGE_CURRENT] 跳过：$1${C_RESET}"
  local key="${STAGE_DETAIL_KEY:-$STAGE_CURRENT}"
  STAGE_NAMES+=("$key"); STAGE_STATUS+=("SKIP")
}

# 子步骤用于一个阶段内分别记录前后端结果
set_detail() { STAGE_DETAIL_KEY="$STAGE_CURRENT/$1"; }
clear_detail() { unset STAGE_DETAIL_KEY; }

warn() { echo "${C_YELLOW}   ! $*${C_RESET}"; }
die() {
  local code="$1" stage="$2"; shift 2
  echo
  echo "${C_RED}${C_BOLD}✗ 流水线失败${C_RESET}"
  echo "${C_RED}  失败环节：${C_BOLD}${stage}${C_RESET}"
  echo "${C_RED}  原因：${C_RESET}$*"
  echo "${C_DIM}  完整日志：${PIPELINE_LOG}${C_RESET}"
  STAGE_NAMES+=("$stage"); STAGE_STATUS+=("FAIL")
  write_handoff "FAIL" "$stage" "$*"
  exit "$code"
}

print_stage_summary() {
  echo
  echo "${C_BOLD}阶段结果：${C_RESET}"
  local i
  for ((i=0; i<${#STAGE_NAMES[@]}; i++)); do
    local mark color="${C_DIM}"
    case "${STAGE_STATUS[$i]}" in
      OK)   mark="✓"; color="${C_GREEN}" ;;
      SKIP) mark="-"; color="${C_DIM}" ;;
      FAIL) mark="✗"; color="${C_RED}" ;;
    esac
    printf "  %s %-6s %s%s\n" "$color$mark$C_RESET" "${STAGE_STATUS[$i]}" "${STAGE_NAMES[$i]}" "$C_RESET"
  done
}

# ----------------------------------------------------------------------------
# 通用工具
# ----------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 比较 "X.Y" 版本：check_version <实际版本 X.Y.Z> <需要主版本> <需要次版本>
check_version() {
  local actual="$1" need_major="$2" need_minor="$3"
  local major minor
  major=$(echo "$actual" | sed -n 's/^\([0-9]\+\)\..*/\1/p')
  minor=$(echo "$actual" | sed -n 's/^[0-9]\+\.\([0-9]\+\).*/\1/p')
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  [ "$major" -gt "$need_major" ] && return 0
  [ "$major" -eq "$need_major" ] && [ "$minor" -ge "$need_minor" ] && return 0
  return 1
}

# 查找 go：PATH 之外兼容常见本机安装位置（换机器/换用户时常见）
find_go() {
  if need_cmd go; then command -v go; return 0; fi
  local candidate
  for candidate in "$HOME/go/bin/go" "$HOME/goroot/bin/go" /usr/local/go/bin/go /opt/go/bin/go; do
    if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
  done
  return 1
}

# 判断端口是否处于 LISTEN，返回占用者 pid（可能多个，空格分隔）
port_pids() {
  local port="$1" hex
  hex=$(printf '%04X' "$port")
  local inodes=""
  if [ -r /proc/net/tcp ]; then
    inodes=$(awk -v h="$hex" '$2 ~ (":"h"$") && $4=="0A" {print $10}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u)
  fi
  if [ -z "$inodes" ] && need_cmd ss; then
    inodes=$(ss -tlnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $0}' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  fi
  [ -z "$inodes" ] && return 1

  local pids="" pid
  if [ -r /proc/net/tcp ]; then
    for inode in $inodes; do
      for fd in /proc/[0-9]*/fd/*; do
        local link
        link=$(readlink "$fd" 2>/dev/null) || continue
        case "$link" in
          *"socket:[$inode]"*)
            pid=$(echo "$fd" | sed -n 's#^/proc/\([0-9]\+\)/fd/.*#\1#p')
            pids="$pids $pid" ;;
        esac
      done
    done
  else
    pids=" $inodes"
  fi
  pids=$(echo $pids | tr ' ' '\n' | sort -u -n | tr '\n' ' ')
  [ -n "$(echo $pids | tr -d ' ')" ] || return 1
  echo "$pids"
}

is_our_pid() {
  local pid="$1" f
  for f in "$BACKEND_PID_FILE" "$FRONTEND_PID_FILE"; do
    [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$pid" ] && return 0
  done
  return 1
}

# 递归终止进程树：先 TERM 后 KILL
kill_tree() {
  local root="$1"
  [ -d "/proc/$root" ] || return 0
  local children=()
  if need_cmd pgrep; then
    children=($(pgrep -P "$root" 2>/dev/null))
  elif [ -r /proc ]; then
    local p c
    for p in /proc/[0-9]*; do
      c=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null) || continue
      [ "$c" = "$root" ] && children+=("${p#/proc/}")
    done
  fi
  local child
  for child in "${children[@]:-}"; do
    [ -n "$child" ] && kill_tree "$child"
  done
  kill -TERM "$root" 2>/dev/null || true
  local i
  for ((i=0; i<20; i++)); do
    [ -d "/proc/$root" ] || return 0
    sleep 0.1
  done
  kill -KILL "$root" 2>/dev/null || true
}

http_probe() {
  curl -fsS --max-time 5 "$1" -o /dev/null 2>/dev/null
}

# 轮询直到 URL 可访问；参数：名称 URL
wait_ready() {
  local name="$1" url="$2" waited=0
  while ! http_probe "$url"; do
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then return 1; fi
    sleep "$READY_INTERVAL"; waited=$((waited + READY_INTERVAL))
  done
  return 0
}

# ----------------------------------------------------------------------------
# 交接记录
# ----------------------------------------------------------------------------
write_handoff() {
  local result="$1" failed_stage="${2:-}" reason="${3:-}"
  local elapsed=$(( $(date +%s) - START_TS ))
  local now host gitref
  now=$(date '+%Y-%m-%d %H:%M:%S')
  host=$(hostname 2>/dev/null || echo unknown)
  gitref=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "非 git 环境")

  {
    echo "# 值班交接记录（流水线）"
    echo
    echo "- 运行时间：$now"
    echo "- 运行编号：$RUN_ID"
    echo "- 机器：$host"
    echo "- 代码版本：$gitref"
    echo "- 结果：$result"
    [ -n "$failed_stage" ] && echo "- 失败环节：$failed_stage"
    [ -n "$reason" ] && echo "- 失败原因：$reason"
    echo "- 耗时：${elapsed}s"
    echo
    echo "## 阶段结果"
    echo
    local i
    for ((i=0; i<${#STAGE_NAMES[@]}; i++)); do
      echo "- [${STAGE_STATUS[$i]}] ${STAGE_NAMES[$i]}"
    done
    echo
    echo "## 服务入口"
    echo
    echo "- 前端：http://127.0.0.1:${FRONTEND_PORT}/"
    echo "- 后端健康检查：${BACKEND_HEALTH_URL}"
    echo
    echo "## 日志位置"
    echo
    echo "- 流水线：$PIPELINE_LOG"
    echo "- 后端：$LOG_DIR/backend.log"
    echo "- 前端：$LOG_DIR/frontend.log"
    echo
    echo "> 历史记录见 git/备份；当前记录文件每次运行覆盖。手动启动方式见 README。"
  } > "$HANDOFF_FILE"
}

# ----------------------------------------------------------------------------
# 停止 / 状态
# ----------------------------------------------------------------------------
read_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null || true; }

stop_services() {
  local quiet="${1:-0}"
  local stopped=0 name pid pidfile
  for pair in "backend:$BACKEND_PID_FILE" "frontend:$FRONTEND_PID_FILE"; do
    name="${pair%%:*}"; pidfile="${pair#*:}"
    pid=$(read_pid "$pidfile")
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      [ "$quiet" -eq 0 ] && echo "   停止 $name (pid $pid)"
      kill_tree "$pid"
      stopped=1
    fi
    rm -f "$pidfile"
  done
  [ "$quiet" -eq 0 ] && [ "$stopped" -eq 0 ] && echo "   没有流水线启动的进程"
}

show_status() {
  local name pidfile pid port url
  for pair in "backend:$BACKEND_PID_FILE:$BACKEND_PORT:$BACKEND_HEALTH_URL" "frontend:$FRONTEND_PID_FILE:$FRONTEND_PORT:$FRONTEND_READY_URL"; do
    name="${pair%%:*}"; rest="${pair#*:}"
    pidfile="${rest%%:*}"; rest="${rest#*:}"
    port="${rest%%:*}"; url="${rest#*:}"
    pid=$(read_pid "$pidfile")
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      if http_probe "$url"; then
        echo "  ${C_GREEN}●${C_RESET} $name  运行中 pid=$pid port=$port 就绪"
      else
        echo "  ${C_YELLOW}●${C_RESET} $name  运行中 pid=$pid port=$port ${C_YELLOW}但尚未就绪${C_RESET}"
      fi
    else
      echo "  ${C_DIM}○${C_RESET} $name  未运行 (port=$port)"
    fi
  done
  echo
  if [ -f "$HANDOFF_FILE" ]; then
    echo "交接记录：$HANDOFF_FILE"
  fi
}

show_logs() {
  local target="${1:-}"
  local file
  case "$target" in
    backend)  file="$LOG_DIR/backend.log" ;;
    frontend) file="$LOG_DIR/frontend.log" ;;
    "")       file="" ;;
    *) echo "未知日志目标：$target（可选 backend|frontend）" >&2; exit 2 ;;
  esac
  if [ -n "$file" ]; then
    [ -f "$file" ] || { echo "日志文件不存在：$file（先运行 $0 up）"; exit 1; }
    tail -n 100 -f "$file"
  else
    local missing=0
    [ -f "$LOG_DIR/backend.log" ] || missing=1
    [ -f "$LOG_DIR/frontend.log" ] || missing=1
    [ "$missing" -eq 1 ] && { echo "尚未发现服务日志（先运行 $0 up）"; exit 1; }
    echo "${C_DIM}（合并最近 40 行，Ctrl-C 仅退出查看，不影响服务）${C_RESET}"
    tail -n 40 -f "$LOG_DIR/backend.log" "$LOG_DIR/frontend.log"
  fi
}

# ----------------------------------------------------------------------------
# 阶段 1：依赖检查
# ----------------------------------------------------------------------------
stage_check_deps() {
  stage_begin "deps-check" "检查运行环境与基础依赖"
  local go_bin node_bin
  go_bin=$(find_go) || die 10 "$STAGE_CURRENT" \
    "未找到 go（>=1.22）。请安装 Go 并加入 PATH（也支持 \$HOME/go/bin、/usr/local/go/bin）。"
  GO_BIN="$go_bin"
  local gover; gover=$("$GO_BIN" version | awk '{print $3}' | sed 's/^go//')
  if ! check_version "$gover" 1 22; then
    die 10 "$STAGE_CURRENT" "Go 版本过低（实际：$("$GO_BIN" version)），需要 >= 1.22。"
  fi

  node_bin=$(need_cmd node && command -v node)
  if [ -z "${node_bin:-}" ]; then
    die 10 "$STAGE_CURRENT" "未找到 node（>=18）。请安装 Node.js 并加入 PATH。"
  fi
  NODE_BIN="$node_bin"
  local nodever; nodever=$("$NODE_BIN" --version | sed 's/^v//')
  if ! check_version "$nodever" 18 0; then
    die 10 "$STAGE_CURRENT" "Node 版本过低（实际：$("$NODE_BIN" --version)），需要 >= 18。"
  fi

  need_cmd curl || die 10 "$STAGE_CURRENT" "未找到 curl，就绪确认依赖它探测 HTTP 端口。"
  need_cmd npm  || die 10 "$STAGE_CURRENT" "未找到 npm，前端依赖准备需要它（随 Node.js 安装）。"

  [ -f "$BACKEND_DIR/go.mod" ]       || die 10 "$STAGE_CURRENT" "缺少 $BACKEND_DIR/go.mod"
  [ -f "$FRONTEND_DIR/package.json" ] || die 10 "$STAGE_CURRENT" "缺少 $FRONTEND_DIR/package.json"

  stage_ok "go $("$GO_BIN" version | awk '{print $3}') | node $("$NODE_BIN" --version) | npm $(npm --version)"
}

# ----------------------------------------------------------------------------
# 阶段 2：依赖准备
# ----------------------------------------------------------------------------
stage_prepare_deps() {
  stage_begin "deps-install" "准备两端依赖"

  # --- 后端模块 ---
  set_detail "go"
  local need_go_install=0
  if [ "$FORCE_INSTALL" -eq 1 ]; then
    need_go_install=1
  elif ! (cd "$BACKEND_DIR" && GOPROXY=off "$GO_BIN" mod download >/dev/null 2>&1); then
    need_go_install=1
  fi
  if [ "$need_go_install" -eq 1 ]; then
    echo "   准备 Go 模块..."
    local go_proxy="$GOPROXY"
    [ "$OFFLINE" -eq 1 ] && go_proxy="off"
    if ! (cd "$BACKEND_DIR" && GOPROXY="$go_proxy" "$GO_BIN" mod download); then
      die 20 "$STAGE_CURRENT" "go mod download 失败（网络或模块缓存问题）。可检查 GOPROXY，或联网后重试。"
    fi
    stage_ok "Go 模块已就绪"
  else
    stage_skip "Go 模块缓存完整，无需下载"
  fi

  # --- 前端依赖 ---
  clear_detail
  set_detail "npm"
  local rollup_pkg
  rollup_pkg=$(node -e '
    try {
      const p = require("path");
      const base = process.argv[1];
      const rl = require(p.join(base, "node_modules", "rollup", "package.json")).version;
      const plat = process.platform + "-" + process.arch + "-gnu";
      require.resolve("@rollup/rollup-" + plat, { paths: [base] });
      console.log("ok");
    } catch (e) { console.log("missing"); }
  ' "$FRONTEND_DIR" 2>/dev/null)

  local need_npm_install=0
  if [ "$FORCE_INSTALL" -eq 1 ]; then
    need_npm_install=1
  elif [ ! -x "$FRONTEND_DIR/node_modules/.bin/vite" ]; then
    need_npm_install=1
  elif [ "$rollup_pkg" != "ok" ]; then
    need_npm_install=1
    warn "检测到 node_modules 与当前平台不匹配（常见于换机器拷贝），将重新安装"
  fi

  if [ "$need_npm_install" -eq 1 ]; then
    echo "   安装前端依赖 (npm ci)..."
    if [ "$OFFLINE" -eq 1 ]; then
      npm_ok=$(cd "$FRONTEND_DIR" && npm ci --offline 2>&1) || true
    else
      npm_ok=$(cd "$FRONTEND_DIR" && npm ci 2>&1) || true
    fi
    if [ ! -x "$FRONTEND_DIR/node_modules/.bin/vite" ]; then
      echo "$npm_ok" | tail -20
      die 20 "$STAGE_CURRENT" "npm ci 失败。请检查 registry/网络（离线场景需先在本机执行过 npm install）。"
    fi
    stage_ok "前端依赖已就绪"
  else
    stage_skip "node_modules 与当前平台匹配，无需安装"
  fi
  clear_detail
}

# ----------------------------------------------------------------------------
# 阶段 3：构建
# ----------------------------------------------------------------------------
stage_build() {
  stage_begin "build" "构建前后端（编译期门禁）"

  echo "   编译后端 -> $BACKEND_BIN"
  # -buildvcs=false：换机器/拷贝目录时 VCS 元信息常不可靠，避免 stamping 报错
  if ! (cd "$BACKEND_DIR" && CGO_ENABLED=0 "$GO_BIN" build -buildvcs=false -o "$BACKEND_BIN" .); then
    die 30 "$STAGE_CURRENT" "后端 go build 失败，详见上方编译错误。"
  fi

  echo "   构建前端 (vue-tsc 类型检查 + vite build)"
  if ! (cd "$FRONTEND_DIR" && npm run build); then
    die 30 "$STAGE_CURRENT" "前端构建失败（类型错误或打包错误），详见上方输出。"
  fi

  stage_ok "后端二进制 + 前端 dist 均已产出"
}

# ----------------------------------------------------------------------------
# 阶段 4：端口与旧进程清理
# ----------------------------------------------------------------------------
free_port() {
  local port="$1" label="$2" pids pid external
  pids=$(port_pids "$port") || pids=""
  for pid in $pids; do
    if is_our_pid "$pid"; then
      warn "发现 $label 旧进程 pid=$pid（流水线管理），终止"
      kill_tree "$pid"
    else
      external=1
      if [ "$FORCE_PORTS" -eq 1 ]; then
        warn "端口 $port 被外部进程 pid=$pid 占用，--force-ports 已指定，终止"
        kill_tree "$pid"
      fi
    fi
  done
  if [ "${external:-0}" = "1" ] && [ "$FORCE_PORTS" -ne 1 ]; then
    die 40 "$STAGE_CURRENT" \
      "端口 $port 已被流水线之外的进程占用（pid: $(echo $pids)）。
        流水线不会擅自杀掉非自己启动的进程；请先停止它，或使用 --force-ports 重试。
        （手动启动的前后端如需保留，请先执行手工方式的停止。）"
  fi
  rm -f "$BACKEND_PID_FILE" "$FRONTEND_PID_FILE"
  # 等待端口真正释放
  local waited=0
  while pids=$(port_pids "$port") && [ -n "$(echo $pids | tr -d ' ')" ]; do
    if [ "$waited" -ge 10 ]; then
      die 40 "$STAGE_CURRENT" "端口 $port 在终止旧进程后仍被占用（pid: $pids），请手动检查。"
    fi
    sleep 0.5; waited=$((waited+1))
  done
}

stage_ports() {
  stage_begin "cleanup" "清理旧进程并确认端口空闲"
  # 先清理本流水线记录的残留（重试/异常退出场景）
  stop_services 1
  free_port "$BACKEND_PORT" "backend"
  free_port "$FRONTEND_PORT" "frontend"
  stage_ok "端口 $BACKEND_PORT、$FRONTEND_PORT 均空闲，无旧进程残留"
}

# ----------------------------------------------------------------------------
# 阶段 5：启动
# ----------------------------------------------------------------------------
rotate_log() {
  [ -f "$1" ] && mv -f "$1" "$1.prev" 2>/dev/null || true
  : > "$1"
}

start_services() {
  stage_begin "start" "在统一环境中启动两端"

  rotate_log "$LOG_DIR/backend.log"
  rotate_log "$LOG_DIR/frontend.log"

  (
    cd "$BACKEND_DIR"
    PORT="$BACKEND_PORT" nohup "$BACKEND_BIN" > "$LOG_DIR/backend.log" 2>&1 &
    echo $! > "$BACKEND_PID_FILE"
  )
  local bpid; bpid=$(read_pid "$BACKEND_PID_FILE")
  sleep 1
  if [ ! -d "/proc/$bpid" ]; then
    die 50 "$STAGE_CURRENT" "后端进程启动后立即退出，请查看 $LOG_DIR/backend.log。"
  fi
  echo "   后端已启动 pid=$bpid"

  (
    cd "$FRONTEND_DIR"
    nohup "$FRONTEND_DIR/node_modules/.bin/vite" --host "$LISTEN_HOST" --port "$FRONTEND_PORT" --strictPort \
      > "$LOG_DIR/frontend.log" 2>&1 &
    echo $! > "$FRONTEND_PID_FILE"
  )
  local fpid; fpid=$(read_pid "$FRONTEND_PID_FILE")
  sleep 1
  if [ ! -d "/proc/$fpid" ]; then
    die 50 "$STAGE_CURRENT" "前端进程启动后立即退出，请查看 $LOG_DIR/frontend.log（如端口被占用、依赖缺失）。"
  fi
  echo "   前端已启动 pid=$fpid"

  stage_ok "两端进程均已拉起（dev 模式，改动即时生效）"
  SERVICES_STARTED=1
}

# ----------------------------------------------------------------------------
# 阶段 6：就绪确认
# ----------------------------------------------------------------------------
stage_ready() {
  stage_begin "ready" "确认两端就绪并串通"

  if ! wait_ready "backend" "$BACKEND_HEALTH_URL"; then
    die 60 "$STAGE_CURRENT" "后端在 ${READY_TIMEOUT}s 内未通过健康检查：$BACKEND_HEALTH_URL。日志：$LOG_DIR/backend.log"
  fi
  echo "   后端健康检查通过"

  if ! wait_ready "frontend" "$FRONTEND_READY_URL"; then
    die 60 "$STAGE_CURRENT" "前端在 ${READY_TIMEOUT}s 内未响应：$FRONTEND_READY_URL。日志：$LOG_DIR/frontend.log"
  fi
  echo "   前端页面可访问"

  if ! wait_ready "e2e" "$E2E_HEALTH_URL"; then
    die 60 "$STAGE_CURRENT" "前端已启动但经其代理访问后端失败（$E2E_HEALTH_URL）。请确认后端在 :$BACKEND_PORT 且 vite 代理配置正确。"
  fi
  echo "   前端 -> 后端代理链路打通"

  stage_ok "两端就绪，链路正常"
}

# ----------------------------------------------------------------------------
# 流水线主体
# ----------------------------------------------------------------------------
run_pipeline() {
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$BIN_DIR"
  stage_check_deps
  stage_prepare_deps
  stage_build
  stage_ports
  start_services
  stage_ready
  print_stage_summary
  write_handoff "SUCCESS"

  echo
  echo "${C_GREEN}${C_BOLD}✅ 流水线完成，两端就绪${C_RESET}"
  echo "  前端：${C_BOLD}http://127.0.0.1:${FRONTEND_PORT}/${C_RESET}"
  echo "  后端：$BACKEND_HEALTH_URL"
  echo "  状态：$0 status   日志：$0 logs   停止：$0 stop"
  echo "  交接记录：$HANDOFF_FILE"
}

run_check_only() {
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$BIN_DIR"
  stage_check_deps
  stage_prepare_deps
  stage_build
  print_stage_summary
  write_handoff "SUCCESS(check-only)"
  echo
  echo "${C_GREEN}✅ 依赖与构建检查通过（未启动服务）${C_RESET}"
}

foreground_follow() {
  # 前台模式：跟随日志，Ctrl-C 时一并停掉两端（EXIT 陷阱兜底回收）
  trap 'echo; echo "收到中断信号，停止两端..."; exit 130' INT
  trap 'exit 143' TERM
  echo "${C_DIM}（前台模式：合并输出两端日志，Ctrl-C 停止两端）${C_RESET}"
  tail -n +1 -f "$LOG_DIR/backend.log" "$LOG_DIR/frontend.log" &
  local tail_pid=$!
  wait "$tail_pid" 2>/dev/null || true
}

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ----------------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------------
ACTION="up"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    up|stop|restart|status|logs|check|help|-h|--help) ACTION="$1"; shift ;;
    --force-ports) FORCE_PORTS=1; shift ;;
    --force-install) FORCE_INSTALL=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# 运行类命令把全程输出写入流水线日志（交接排查依据），每次运行先清空
case "$ACTION" in
  up|restart|check)
    mkdir -p "$RUN_DIR" "$LOG_DIR" "$BIN_DIR"
    : > "$PIPELINE_LOG"
    exec > >(tee -a "$PIPELINE_LOG") 2>&1
    ;;
esac

case "$ACTION" in
  up|restart)
    PIPELINE_ACTION="up"
    if [ "$ACTION" = "restart" ]; then
      stop_services 1
      rm -f "$BACKEND_PID_FILE" "$FRONTEND_PID_FILE"
    fi
    run_pipeline
    if [ "$FOREGROUND" -eq 1 ]; then foreground_follow; fi
    ;;
  check)
    PIPELINE_ACTION="check"
    run_check_only
    ;;
  stop)
    stop_services
    rm -f "$BACKEND_PID_FILE" "$FRONTEND_PID_FILE"
    echo "已停止。"
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs "${ARGS[0]:-}"
    ;;
  help|-h|--help)
    usage
    ;;
esac
