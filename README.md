# solo-6600009 - IoT Geofence Monitor

## Tech
- **Frontend**: Vue 3 + Pinia + Leaflet
- **Backend**: Go + Gin + MQTT
- **Database**: TimescaleDB

## 一键流水线（推荐，值班/交接用）

把「依赖检查 → 依赖准备 → 构建 → 清理旧进程 → 启动两端 → 就绪确认」串成一条本地流水线。
统一环境启动前后端，确认两端都就绪、且经前端代理能访问后端后才算成功；任一步失败都会指出**环节和原因**，修正后直接重跑，不会残留旧进程。

```bash
./pipeline/pipeline.sh up          # 或 make up：跑完整条流水线并后台启动两端
```

成功后：
- 前端 http://127.0.0.1:5173/ ，后端 http://127.0.0.1:8080/api/health
- 值班交接记录：`.pipeline/HANDOFF.md`（运行版本、各阶段结果、日志位置）

常用命令：

| 命令 | 作用 |
| --- | --- |
| `./pipeline/pipeline.sh up` | 完整流水线，后台启动两端 |
| `./pipeline/pipeline.sh up --foreground` | 前台合并输出两端日志，Ctrl-C 同时停两端 |
| `./pipeline/pipeline.sh check` | 只做依赖检查 + 构建（部署前准备，不启动） |
| `./pipeline/pipeline.sh status` | 查看两端运行/就绪状态 |
| `./pipeline/pipeline.sh logs [backend\|frontend]` | 查看服务日志 |
| `./pipeline/pipeline.sh restart` | 停掉旧进程后重跑完整流水线 |
| `./pipeline/pipeline.sh stop` | 停止流水线启动的进程 |

选项：`--force-install`（强制重装依赖）、`--offline`（只用本机缓存）、`--force-ports`（端口被外部进程占用时一并终止）。
可用环境变量：`BACKEND_PORT`、`FRONTEND_PORT`、`LISTEN_HOST`、`READY_TIMEOUT`、`GOPROXY`。

失败时退出码按环节区分，方便排查：`10` 依赖检查、`20` 依赖准备、`30` 构建、`40` 端口冲突、`50` 启动、`60` 就绪确认。

> 流水线只终止**自己通过 pid 文件启动的进程**；端口被流水线之外的进程（例如手工启动的服务）占用时默认只提示、不擅杀，可用 `--force-ports` 显式接管。

## 手工启动（仍然完全可用）

```bash
cd backend && go run main.go
cd frontend && npm install && npm run dev
```

> 注意：手工启动与流水线使用相同端口（8080 / 5173），两者不要同时运行；切换前先停掉另一路。

## 数据与刷新

- 后端设备数据为内存数据（`POST /api/devices` 重启后回到内置样例）。
- 前端值班状态（告警确认、围栏编辑、设备注册、轨迹回放进度等）通过零依赖的 Pinia 持久化插件保存在浏览器 `localStorage`，**刷新页面不丢当前进度**；快照损坏时自动回退到内置初始数据。

## 运行产物

`.pipeline/` 下存放流水线二进制、pid、日志与交接记录，已加入 `.gitignore`：

```
.pipeline/bin/      编译出的后端二进制
.pipeline/run/      两端 pid
.pipeline/logs/     pipeline.log / backend.log / frontend.log
.pipeline/HANDOFF.md 最近一次运行的交接记录
```
