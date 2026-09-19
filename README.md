# solo-6600009 - IoT Geofence Monitor

值班与交接环境的本地一体化流水线：依赖检查 → 构建 → 部署前准备 → 统一启动 →
就绪确认，任一环节失败都会标出阶段与原因，修正后可直接重试，且不会残留旧进程。

## Tech
- **Frontend**: Vue 3 + Pinia + Leaflet
- **Backend**: Go + Gin
- **Database**: TimescaleDB

## 一键流水线（推荐）

```bash
make up          # 等价于 ./scripts/pipeline.sh up
```

流水线顺序执行 5 个阶段，前一步成功才会进入下一步：

| 阶段 | 做什么 | 失败时 |
|---|---|---|
| `deps` | 检查 go/node/npm/curl；`node_modules` 缺失或跨机器/跨架构失效（如 rollup 原生包）时自动 `npm ci` 修复；Go 不在 PATH 时会探测 `/usr/local/go` 等常见位置，也可用 `GO_BIN` 指定 | 退出码 1，打印缺失项 |
| `build` | 后端 `go build`；前端 `vue-tsc && vite build` | 退出码 2，打印编译错误 |
| `prepare` | 停止上一次流水线的遗留进程、确认两端口可用、准备日志/PID 目录；手动启动占用端口会被识别并保护，不擅自杀 | 退出码 3 |
| `start` | 统一启动后端与前端，进程启动即退出或端口未监听都会立即判失败 | 退出码 4，打印对应日志 |
| `ready` | 依次确认后端 `/api/health`、前端页面、以及经前端代理的端到端 `/api/health`（任一侧没接上都会暴露），默认 60s 超时 | 退出码 5，自动清理已启动进程 |

成功后：
- 前端 http://localhost:5173/ ，后端 http://localhost:8080/api/health
- 值班数据（设备/围栏/分组）与交接记录（告警及确认状态）保存在浏览器
  localStorage（键 `iot-duty-state-v1`），**刷新页面或重启流水线后自动恢复**；
  轨迹播放位置等临时状态不持久化。

### 常用命令

```bash
make status      # 查看两端运行状态（自动对齐上次使用的端口）
make logs        # 跟踪两端日志（Ctrl-C 只退出查看，不停服务）
make stop        # 停止流水线启动的全部进程，不残留
make restart     # 修正问题后：停止并重新执行完整流水线
make deps        # 只检查/修复依赖
make build       # 依赖检查后只构建
```

也可直接用脚本：`./scripts/pipeline.sh up|deps|build|prepare|stop|restart|status|logs [be|fe]`。

### 可配置项

```bash
BACKEND_PORT=9090 FRONTEND_PORT=5174 ./scripts/pipeline.sh up
READY_TIMEOUT=90 ./scripts/pipeline.sh up     # 就绪检查超时秒数
GO_BIN=/path/to/go ./scripts/pipeline.sh up   # 显式指定 go
```

运行时产物（PID、日志、编译后的二进制、端口登记）都在 `.run/` 下，已加入
`.gitignore`；stop 会清理进程，日志与二进制保留以便排查。

## 手动启动（继续可用，与流水线互不影响）

```bash
cd backend && go run main.go                 # 默认 :8080，可用 PORT 覆盖
cd frontend && npm install && npm run dev    # 默认 :5173，代理 /api -> :8080
```

> 流水线发现端口被手动启动的服务占用时会停止并提示，不会杀掉手动启动的进程；
> 可先手动停止，或用 `BACKEND_PORT`/`FRONTEND_PORT` 让两者使用不同端口。
