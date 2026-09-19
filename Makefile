# 值班/交接环境本地流水线
# 用法: make help

PIPELINE := ./scripts/pipeline.sh

.PHONY: help up deps build prepare stop restart status logs logs-be logs-fe

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## 依赖检查 -> 构建 -> 部署前准备 -> 启动 -> 就绪确认
	@$(PIPELINE) up

deps: ## 仅检查/修复依赖（跨机器 node_modules 失效会自动重装）
	@$(PIPELINE) deps

build: ## 依赖检查后构建两端
	@$(PIPELINE) build

prepare: ## 部署前准备（清理旧进程、确认端口）
	@$(PIPELINE) prepare

stop: ## 停止流水线启动的全部进程，不残留
	@$(PIPELINE) stop

restart: ## 停止后重新执行完整流水线
	@$(PIPELINE) restart

status: ## 查看两端运行状态
	@$(PIPELINE) status

logs: ## 跟踪两端日志（Ctrl-C 只退出查看）
	@$(PIPELINE) logs all

logs-be: ## 仅后端日志
	@$(PIPELINE) logs be

logs-fe: ## 仅前端日志
	@$(PIPELINE) logs fe
