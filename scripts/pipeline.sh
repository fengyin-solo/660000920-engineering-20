#!/usr/bin/env bash
#
# pipeline.sh — 值班/交接环境本地一键流水线
#
# 阶段（每一步成功才会进入下一步，失败时打印 STAGE 与原因并清理已启动进程）：
#   deps     依赖检查（go / node / npm / curl；缺失或跨机器失效的 node_modules 自动修复）
#   build    构建（backend: go build；frontend: vue-tsc + vite build）
#   prepare  部署前准备（清理本流水线遗留进程、确认端口可用、准备日志/PID 目录）
#   start    统一启动后端与前端
#   ready    就绪确认（后端 /api/health、前端页面、经 Vite 代理的端到端 /api/health）
#
# 用法:
#   ./scripts/pipeline.sh up        全流程：deps -> build -> prepare -> start -> ready（默认）
#   ./scripts/pipeline.sh deps      仅检查/修复依赖
#   ./scripts/pipeline.sh build     依赖检查后执行构建
#   ./scripts/pipeline.sh stop      停止本流水线启动的全部进程，不残留
#   ./scripts/pipeline.sh restart   stop 后重新 up
#   ./scripts/pipeline.sh status    查看两端运行状态
#   ./scripts/pipeline.sh logs [fe|be]   跟踪日志（默认全部，Ctrl-C 只退出查看）
#
# 可覆盖的环境变量：
#   BACKEND_PORT=8080  FRONTEND_PORT=5173  READY_TIMEOUT=60
#   GO_BIN=/path/to/go   （deps 阶段也会自动探测 PATH 之外的常见安装位置）
#
# 手动启动（README 中的 go run / npm run dev）与本流水线互不影响；
# 前端值班数据与交接记录持久化在浏览器 localStorage，刷新/重启后继续可用。

set -u -o pipefail

# ---------- 路径与配置 ----------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
RUN_DIR="$ROOT_DIR/.run"
BACKEND_BIN="$RUN_DIR/backend-server"
BE_PID_FILE="$RUN_DIR/backend.pid"
FE_PID_FILE="$RUN_DIR/frontend.pid"
BE_LOG="$RUN_DIR/backend.log"
FE_LOG="$RUN_DIR/frontend.log"
READY_FILE="$RUN_DIR/ready"
RUNTIME_ENV="$RUN_DIR/runtime.env"

# 记录调用者是否显式指定了端口（显式环境变量优先于运行登记）
[ -n "${BACKEND_PORT+x}" ]  && BE_PORT_OVERRIDE=1  || BE_PORT_OVERRIDE=0
[ -n "${FRONTEND_PORT+x}" ] && FE_PORT_OVERRIDE=1  || FE_PORT_OVERRIDE=0
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"

# 读取上一次运行登记的端口（stop/status/restart 自动对齐实际运行的实例）
load_runtime() {
  [ -f "$RUNTIME_ENV" ] || return 0
  local v
  if [ "$BE_PORT_OVERRIDE" -eq 0 ]; then
    v=$(sed -n 's/^BACKEND_PORT=//p' "$RUNTIME_ENV" | head -1); [ -n "$v" ] && BACKEND_PORT="$v"
  fi
  if [ "$FE_PORT_OVERRIDE" -eq 0 ]; then
    v=$(sed -n 's/^FRONTEND_PORT=//p' "$RUNTIME_ENV" | head -1); [ -n "$v" ] && FRONTEND_PORT="$v"
  fi
}

# 退出码即失败阶段编号：1 deps 2 build 3 prepare 4 start 5 ready
EXIT_DEPS=1; EXIT_BUILD=2; EXIT_PREPARE=3; EXIT_START=4; EXIT_READY=5

# ---------- 输出工具 ----------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

step()  { printf '%s▶ %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
ok()    { printf '%s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
info()  { printf '%s  · %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()  { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die() {
  local stage="$1" code="$2"; shift 2
  printf '\n%s[%s 失败]%s %s\n' "$C_RED" "$stage" "$C_RESET" "$*" >&2
  printf '%s  日志：%s (backend), %s (frontend)%s\n' "$C_DIM" "$BE_LOG" "$FE_LOG" "$C_RESET" >&2
  stop_services >/dev/null 2>&1 || true
  exit "$code"
}

# ---------- 端口/PID 工具（不依赖 ss/lsof/fuser） ----------
# 输出监听指定 TCP 端口的进程 PID（可能多个）
port_pids() {
  local port="$1" hex
  hex=$(printf '%04X' "$port" 2>/dev/null) || return 0

  # Linux：/proc/net/tcp[6] 找到监听 inode，再在 /proc/*/fd 中匹配 socket
  if [ -r /proc/net/tcp ]; then
    local inodes inode pid fd target i
    # Go/Node 可能监听在 IPv6 双栈，tcp 与 tcp6 都要扫
    inodes=$(awk 'NR>1 && $2 ~ /:'"$hex"'$/ && $4=="0A" {print $10}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    [ -z "$inodes" ] && return 0
    for pid in /proc/[0-9]*; do
      pid="${pid#/proc/}"
      for fd in /proc/$pid/fd/*; do
        [ -r "$fd" ] || continue
        target=$(readlink "$fd" 2>/dev/null) || continue
        case "$target" in socket:\[*\]) inode="${target#socket:[}"; inode="${inode%]}" ;; *) continue ;; esac
        for i in $inodes; do
          if [ "$inode" = "$i" ]; then printf '%s\n' "$pid"; break 2; fi
        done
      done
    done
    return 0
  fi

  # macOS / BSD：退回 lsof
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null
  fi
}

port_in_use() { [ -n "$(port_pids "$1")" ]; }

is_alive() { kill -0 "$1" 2>/dev/null; }

tail_log_hint() {
  local f="$1" n="${2:-15}"
  [ -f "$f" ] && tail -n "$n" "$f" | sed 's/^/    /'
}

# ---------- stop：只杀本流水线登记的进程，并按端口兜底 ----------
stop_services() {
  local killed=0 pid pids

  kill_by_pidfile() {
    local pf="$1" name="$2"
    [ -f "$pf" ] || return 0
    pid=$(cat "$pf" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && is_alive "$pid"; then
      kill "$pid" 2>/dev/null || true
      local i
      for i in $(seq 1 20); do is_alive "$pid" || break; sleep 0.1; done
      if is_alive "$pid"; then kill -9 "$pid" 2>/dev/null || true; fi
      info "$name 已停止 (pid $pid)"
      killed=1
    fi
    rm -f "$pf"
  }

  kill_by_pidfile "$FE_PID_FILE" "前端"
  kill_by_pidfile "$BE_PID_FILE" "后端"

  # 兜底：清理仍占用本流水线端口的进程（vite 子进程等）
  for pair in "$BACKEND_PORT:后端" "$FRONTEND_PORT:前端"; do
    local port="${pair%%:*}" label="${pair##*:}"
    pids=$(port_pids "$port")
    if [ -n "$pids" ]; then
      warn "$label 端口 $port 仍被占用，执行兜底清理: $(echo "$pids" | tr '\n' ' ')"
      for pid in $pids; do kill "$pid" 2>/dev/null || true; done
      sleep 1
      for pid in $(port_pids "$port"); do kill -9 "$pid" 2>/dev/null || true; done
    fi
  done

  rm -f "$READY_FILE"
  [ "$killed" -eq 1 ] && return 0 || return 1
}

# ---------- 阶段 1：deps ----------
GO_BIN=""

find_go() {
  local cand
  if [ -n "${GO_BIN:-}" ] && [ -x "${GO_BIN:-}" ]; then return 0; fi
  if command -v go >/dev/null 2>&1; then GO_BIN="$(command -v go)"; return 0; fi
  # PATH 之外的常见安装位置（换机器时 go 可能未加入 PATH）
  for cand in /usr/local/go/bin/go /opt/go/bin/go /usr/lib/go/bin/go "$HOME/go/bin/go" /tmp/gotc/go/bin/go; do
    if [ -x "$cand" ]; then GO_BIN="$cand"; return 0; fi
  done
  return 1
}

stage_deps() {
  step "阶段 1/5 deps：依赖检查"

  # Go
  if ! find_go; then
    die deps "$EXIT_DEPS" "未找到 go（要求 1.22+）。请安装 Go 或将其加入 PATH，也可用 GO_BIN=/path/to/go 指定。"
  fi
  local gover
  gover="$("$GO_BIN" version 2>&1)" || die deps "$EXIT_DEPS" "无法执行 $GO_BIN：$gover"
  ok "Go：$gover${GO_BIN:+  ($GO_BIN)}"
  [ -f "$BACKEND_DIR/go.mod" ] || die deps "$EXIT_DEPS" "缺少 $BACKEND_DIR/go.mod"

  # Node / npm
  command -v node >/dev/null 2>&1 || die deps "$EXIT_DEPS" "未找到 node（要求 18+）。"
  command -v npm  >/dev/null 2>&1 || die deps "$EXIT_DEPS" "未找到 npm。"
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$node_major" -lt 18 ] 2>/dev/null; then
    die deps "$EXIT_DEPS" "node 版本过低：$(node -v)，要求 18+。"
  fi
  ok "Node：$(node -v) / npm $(npm -v)"
  [ -f "$FRONTEND_DIR/package.json" ] || die deps "$EXIT_DEPS" "缺少 $FRONTEND_DIR/package.json"

  # curl（就绪检查用）
  command -v curl >/dev/null 2>&1 || die deps "$EXIT_DEPS" "未找到 curl，就绪检查需要它。"

  # 后端 Go 依赖（模块缓存/下载）
  info "校验后端 Go 模块..."
  if ! (cd "$BACKEND_DIR" && "$GO_BIN" mod download) 2>"$RUN_DIR/deps-go.log"; then
    warn "go mod download 失败（可能离线），将尝试使用本地模块缓存继续"
    tail_log_hint "$RUN_DIR/deps-go.log" 8
  fi

  # 前端依赖：node_modules 缺失、跨机器/跨架构失效（如 rollup 原生包）时自动修复
  local need_install=0 reason=""
  if [ ! -d "$FRONTEND_DIR/node_modules" ] || [ ! -x "$FRONTEND_DIR/node_modules/.bin/vite" ]; then
    need_install=1; reason="node_modules 缺失或不完整"
  else
    # 用真实 require 验证 vite/rollup 原生绑定，跨机器拷贝时最容易在这里坏
    if ! (cd "$FRONTEND_DIR" && node -e "require.resolve('vite'); require('rollup')" >/dev/null 2>&1); then
      need_install=1; reason="node_modules 与当前机器不匹配（原生依赖缺失/跨架构）"
    fi
  fi

  if [ "$need_install" -eq 1 ]; then
    info "$reason，执行 npm ci 修复..."
    if ! (cd "$FRONTEND_DIR" && npm ci --no-audit --no-fund) >"$RUN_DIR/deps-npm.log" 2>&1; then
      tail_log_hint "$RUN_DIR/deps-npm.log" 12
      die deps "$EXIT_DEPS" "前端依赖安装失败（npm ci），详见 $RUN_DIR/deps-npm.log。可检查网络后重试：./scripts/pipeline.sh deps"
    fi
    tail -n 4 "$RUN_DIR/deps-npm.log" | sed 's/^/    /'
    ok "前端依赖已安装"
  else
    ok "前端依赖就绪 (node_modules)"
  fi
}

# ---------- 阶段 2：build ----------
stage_build() {
  step "阶段 2/5 build：构建两端"
  mkdir -p "$RUN_DIR"

  info "编译后端 -> $BACKEND_BIN"
  if ! (cd "$BACKEND_DIR" && CGO_ENABLED=0 "$GO_BIN" build -buildvcs=false -o "$BACKEND_BIN" .) 2>"$RUN_DIR/build-be.log"; then
    tail_log_hint "$RUN_DIR/build-be.log" 20
    die build "$EXIT_BUILD" "后端构建失败（go build），详见 $RUN_DIR/build-be.log"
  fi
  ok "后端构建通过"

  info "类型检查并构建前端（vue-tsc && vite build）"
  if ! (cd "$FRONTEND_DIR" && npm run build) >"$RUN_DIR/build-fe.log" 2>&1; then
    tail_log_hint "$RUN_DIR/build-fe.log" 20
    die build "$EXIT_BUILD" "前端构建失败（vue-tsc/vite build），详见 $RUN_DIR/build-fe.log"
  fi
  ok "前端构建通过 (dist/)"
}

# ---------- 阶段 3：prepare ----------
stage_prepare() {
  step "阶段 3/5 prepare：部署前准备"
  mkdir -p "$RUN_DIR"

  # 不残留旧进程：先清理本流水线登记的进程
  if [ -f "$BE_PID_FILE" ] || [ -f "$FE_PID_FILE" ]; then
    info "发现上一次流水线运行的登记信息，先停止旧进程..."
    stop_services || true
  fi

  # 端口若仍被占用：区分是不是本流水线的遗留，手动启动的服务不擅自杀
  for pair in "$BACKEND_PORT:后端" "$FRONTEND_PORT:前端"; do
    local port="${pair%%:*}" label="${pair##*:}"
    if port_in_use "$port"; then
      local holders
      holders="$(port_pids "$port" | tr '\n' ' ')"
      die prepare "$EXIT_PREPARE" \
        "$label 端口 $port 已被非本流水线进程占用 (pid: $holders)。若确认是手动启动的旧服务，请先停止（或为流水线指定其他端口：BACKEND_PORT/FRONTEND_PORT）。"
    fi
  done
  ok "端口 $BACKEND_PORT(后端)/$FRONTEND_PORT(前端) 可用"

  : > "$BE_LOG"; : > "$FE_LOG"
  ok "日志与工作目录就绪 ($RUN_DIR)"
}

# ---------- 阶段 4：start ----------
wait_for_listen() {
  local port="$1" wait_seconds="${2:-15}" i
  for (( i = 0; i < wait_seconds * 5; i++ )); do
    if port_in_use "$port"; then return 0; fi
    sleep 0.2
  done
  return 1
}

stage_start() {
  step "阶段 4/5 start：统一启动两端"

  # 登记本次实际端口，供 stop/status/restart 对齐
  printf 'BACKEND_PORT=%s\nFRONTEND_PORT=%s\n' "$BACKEND_PORT" "$FRONTEND_PORT" > "$RUNTIME_ENV"

  info "启动后端 :$BACKEND_PORT"
  (
    cd "$BACKEND_DIR"
    PORT="$BACKEND_PORT" GIN_MODE=release nohup "$BACKEND_BIN" >>"$BE_LOG" 2>&1 &
    echo $! > "$BE_PID_FILE"
  )
  local be_pid
  be_pid="$(cat "$BE_PID_FILE")"
  sleep 0.5
  if ! is_alive "$be_pid"; then
    tail_log_hint "$BE_LOG" 20
    die start "$EXIT_START" "后端进程启动即退出 (pid $be_pid)，详见 $BE_LOG"
  fi
  if ! wait_for_listen "$BACKEND_PORT" 15; then
    tail_log_hint "$BE_LOG" 20
    die start "$EXIT_START" "后端已启动但端口 $BACKEND_PORT 未监听，详见 $BE_LOG"
  fi
  ok "后端已启动 (pid $be_pid)"

  info "启动前端 :$FRONTEND_PORT（/api -> :$BACKEND_PORT）"
  (
    cd "$FRONTEND_DIR"
    FRONTEND_PORT="$FRONTEND_PORT" BACKEND_PORT="$BACKEND_PORT" \
      nohup node node_modules/vite/bin/vite.js --strictPort >>"$FE_LOG" 2>&1 &
    echo $! > "$FE_PID_FILE"
  )
  local fe_pid
  fe_pid="$(cat "$FE_PID_FILE")"
  sleep 0.5
  if ! is_alive "$fe_pid"; then
    tail_log_hint "$FE_LOG" 20
    die start "$EXIT_START" "前端进程启动即退出 (pid $fe_pid)，详见 $FE_LOG"
  fi
  if ! wait_for_listen "$FRONTEND_PORT" 20; then
    tail_log_hint "$FE_LOG" 20
    die start "$EXIT_START" "前端已启动但端口 $FRONTEND_PORT 未监听，详见 $FE_LOG"
  fi
  ok "前端已启动 (pid $fe_pid)"
}

# ---------- 阶段 5：ready ----------
http_ok() {
  curl -fs -m 3 -o /dev/null "$1" 2>/dev/null
}

poll_ready() {
  local url="$1" deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    http_ok "$url" && return 0
    sleep 1
  done
  return 1
}

stage_ready() {
  step "阶段 5/5 ready：就绪确认（最长 ${READY_TIMEOUT}s）"

  if ! poll_ready "http://localhost:$BACKEND_PORT/api/health"; then
    tail_log_hint "$BE_LOG" 20
    die ready "$EXIT_READY" "后端健康检查未通过：GET /api/health 失败"
  fi
  ok "后端就绪：http://localhost:$BACKEND_PORT/api/health"

  if ! poll_ready "http://localhost:$FRONTEND_PORT/"; then
    tail_log_hint "$FE_LOG" 20
    die ready "$EXIT_READY" "前端页面不可访问：http://localhost:$FRONTEND_PORT/"
  fi
  ok "前端就绪：http://localhost:$FRONTEND_PORT/"

  # 端到端：经前端代理打到后端，任一侧没真正接上都会在这里暴露
  if ! poll_ready "http://localhost:$FRONTEND_PORT/api/health"; then
    tail_log_hint "$FE_LOG" 10
    die ready "$EXIT_READY" "端到端检查失败：前端 -> 后端代理 /api/health 不通（一侧未就绪）"
  fi
  ok "端到端就绪：http://localhost:$FRONTEND_PORT/api/health -> 后端"

  date -u +%Y-%m-%dT%H:%M:%SZ > "$READY_FILE"
}

# ---------- 辅助命令 ----------
show_status() {
  local be_pid fe_pid
  printf '%s流水线状态%s\n' "$C_BOLD" "$C_RESET"
  if [ -f "$BE_PID_FILE" ]; then be_pid="$(cat "$BE_PID_FILE")"; else be_pid=""; fi
  if [ -f "$FE_PID_FILE" ]; then fe_pid="$(cat "$FE_PID_FILE")"; else fe_pid=""; fi

  if [ -n "$be_pid" ] && is_alive "$be_pid"; then
    ok "后端运行中 (pid $be_pid) :$BACKEND_PORT"
  else
    warn "后端未运行"
  fi
  if [ -n "$fe_pid" ] && is_alive "$fe_pid"; then
    ok "前端运行中 (pid $fe_pid) :$FRONTEND_PORT"
  else
    warn "前端未运行"
  fi
  if [ -f "$READY_FILE" ]; then
    ok "就绪时间：$(cat "$READY_FILE")"
  fi

  # 端口视角（即使进程不是本流水线启动的也能看到）
  local p
  p="$(port_pids "$BACKEND_PORT" | tr '\n' ' ')"
  info "端口 $BACKEND_PORT 监听进程: ${p:-无}"
  p="$(port_pids "$FRONTEND_PORT" | tr '\n' ' ')"
  info "端口 $FRONTEND_PORT 监听进程: ${p:-无}"
}

show_logs() {
  local which="${1:-all}"
  case "$which" in
    be)  [ -f "$BE_LOG" ] || { info "暂无日志 $BE_LOG"; return; }; exec tail -n 50 -f "$BE_LOG" ;;
    fe)  [ -f "$FE_LOG" ] || { info "暂无日志 $FE_LOG"; return; }; exec tail -n 50 -f "$FE_LOG" ;;
    all)
      [ -f "$BE_LOG" ] || : > "$BE_LOG"
      [ -f "$FE_LOG" ] || : > "$FE_LOG"
      exec tail -n 30 -f "$BE_LOG" "$FE_LOG"
      ;;
    *) die logs 64 "未知日志目标：$which（可选 be|fe）" ;;
  esac
}

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- 入口 ----------
main() {
  local cmd="${1:-up}"
  mkdir -p "$RUN_DIR"
  case "$cmd" in
    up)
      # 已经完整就绪且端口一致则直接提示，避免重复启动；restart 会先 stop
      local rt_be rt_fe
      rt_be=""; rt_fe=""
      if [ -f "$RUNTIME_ENV" ]; then
        rt_be=$(sed -n 's/^BACKEND_PORT=//p' "$RUNTIME_ENV" | head -1)
        rt_fe=$(sed -n 's/^FRONTEND_PORT=//p' "$RUNTIME_ENV" | head -1)
      fi
      if [ -f "$READY_FILE" ] && [ "$rt_be" = "$BACKEND_PORT" ] && [ "$rt_fe" = "$FRONTEND_PORT" ] \
         && [ -f "$BE_PID_FILE" ] && is_alive "$(cat "$BE_PID_FILE")" \
         && [ -f "$FE_PID_FILE" ] && is_alive "$(cat "$FE_PID_FILE")"; then
        info "两端已在运行且已就绪 (:$BACKEND_PORT/:$FRONTEND_PORT)。如需重建请用：./scripts/pipeline.sh restart"
        show_status
        exit 0
      fi
      stage_deps
      stage_build
      stage_prepare
      stage_start
      stage_ready
      printf '\n%s✅ 流水线完成，值班/交接环境已就绪%s\n' "$C_GREEN" "$C_RESET"
      printf '   前端：%shttp://localhost:%s/%s\n' "$C_BOLD" "$FRONTEND_PORT" "$C_RESET"
      printf '   后端：%shttp://localhost:%s/api/health%s\n' "$C_BOLD" "$BACKEND_PORT" "$C_RESET"
      info "查看日志：./scripts/pipeline.sh logs    停止：./scripts/pipeline.sh stop"
      ;;
    deps)    stage_deps; ok "依赖检查通过" ;;
    build)   stage_deps; stage_build; ok "构建通过" ;;
    prepare) stage_prepare; ok "部署前准备完成" ;;
    stop)
      load_runtime
      if stop_services; then ok "已停止全部流水线进程"; else info "没有正在运行的流水线进程"; fi
      ;;
    restart) load_runtime; stop_services || true; exec "$0" up ;;
    status)  load_runtime; show_status ;;
    logs)    show_logs "${2:-all}" ;;
    -h|--help|help) usage ;;
    *) usage; exit 64 ;;
  esac
}

main "$@"
