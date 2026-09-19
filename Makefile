# 值班/交接本地流水线便捷入口（详见 ./pipeline/pipeline.sh help）
.PHONY: up check stop restart status logs logs-backend logs-frontend foreground

up:
	./pipeline/pipeline.sh up

foreground:
	./pipeline/pipeline.sh up --foreground

check:
	./pipeline/pipeline.sh check

stop:
	./pipeline/pipeline.sh stop

restart:
	./pipeline/pipeline.sh restart

status:
	./pipeline/pipeline.sh status

logs:
	./pipeline/pipeline.sh logs

logs-backend:
	./pipeline/pipeline.sh logs backend

logs-frontend:
	./pipeline/pipeline.sh logs frontend
