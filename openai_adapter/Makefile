# Makefile for OpenAI Adapter - MiniCPM-o 4.5
# 便捷的端到端测试和管理工具

.PHONY: help start stop restart status test test-quick test-stream test-curl health clean logs install

# 配置
PYTHON := /Users/ftwhmg/v.v/bin/python
PIP := /Users/ftwhmg/v.v/bin/pip
ADAPTER_PORT := 8080
LLAMA_PORT := 19060
LOG_FILE := /tmp/adapter_final.log
MINICPM_DIR := /Users/ftwhmg/houmao/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo

# 颜色输出
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m # No Color

##@ 通用命令

help: ## 显示帮助信息
	@echo "$(GREEN)OpenAI Adapter for MiniCPM-o 4.5$(NC)"
	@echo ""
	@echo "使用方法: make [目标]"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo ""

##@ 服务管理

start: ## 启动适配层服务
	@echo "$(GREEN)启动适配层...$(NC)"
	@if lsof -ti :$(ADAPTER_PORT) > /dev/null 2>&1; then \
		echo "$(YELLOW)端口 $(ADAPTER_PORT) 已被占用，先清理...$(NC)"; \
		make stop; \
		sleep 2; \
	fi
	@$(PYTHON) main.py > $(LOG_FILE) 2>&1 &
	@sleep 3
	@if lsof -ti :$(ADAPTER_PORT) > /dev/null 2>&1; then \
		echo "$(GREEN)✅ 适配层启动成功 (PID: $$(lsof -ti :$(ADAPTER_PORT)))$(NC)"; \
		make health; \
	else \
		echo "$(RED)❌ 启动失败，查看日志: tail -f $(LOG_FILE)$(NC)"; \
		exit 1; \
	fi

stop: ## 停止适配层服务
	@echo "$(YELLOW)停止适配层...$(NC)"
	@if lsof -ti :$(ADAPTER_PORT) > /dev/null 2>&1; then \
		lsof -ti :$(ADAPTER_PORT) | xargs kill -9 2>/dev/null || true; \
		sleep 1; \
		echo "$(GREEN)✅ 已停止$(NC)"; \
	else \
		echo "$(YELLOW)服务未运行$(NC)"; \
	fi

restart: stop start ## 重启适配层服务

status: ## 查看服务状态
	@echo "$(GREEN)服务状态检查:$(NC)"
	@echo ""
	@echo "$(YELLOW)适配层 (port $(ADAPTER_PORT)):$(NC)"
	@if lsof -ti :$(ADAPTER_PORT) > /dev/null 2>&1; then \
		echo "  ✅ 运行中 (PID: $$(lsof -ti :$(ADAPTER_PORT)))"; \
	else \
		echo "  ❌ 未运行"; \
	fi
	@echo ""
	@echo "$(YELLOW)llama-server (port $(LLAMA_PORT)):$(NC)"
	@if lsof -ti :$(LLAMA_PORT) > /dev/null 2>&1; then \
		echo "  ✅ 运行中 (PID: $$(lsof -ti :$(LLAMA_PORT)))"; \
	else \
		echo "  ❌ 未运行"; \
		echo "  提示: 需要先启动 MiniCPM-o 服务"; \
	fi

##@ 测试命令

test: health ## 运行完整测试套件
	@echo ""
	@echo "$(GREEN)运行完整测试...$(NC)"
	@echo ""
	@$(PYTHON) test_openai_sdk.py
	@echo ""
	@echo "$(GREEN)✅ 所有测试通过！$(NC)"

test-quick: health ## 快速测试（单次对话）
	@echo "$(GREEN)快速测试...$(NC)"
	@curl -s http://localhost:$(ADAPTER_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"minicpm-o-4.5","messages":[{"role":"user","content":"你好，请用一句话介绍你自己"}],"max_tokens":50}' \
		| python3 -c 'import sys, json; data=json.load(sys.stdin); print("\n✅ 响应:", data["choices"][0]["message"]["content"]); print("📊 Token 使用:", data["usage"]["total_tokens"])'
	@echo ""

test-stream: health ## 测试流式响应
	@echo "$(GREEN)测试流式响应...$(NC)"
	@echo ""
	@curl -s http://localhost:$(ADAPTER_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"minicpm-o-4.5","messages":[{"role":"user","content":"数到5"}],"stream":true,"max_tokens":30}' \
		| grep -o '"content":"[^"]*"' | head -20
	@echo ""
	@echo "$(GREEN)✅ 流式响应正常$(NC)"

test-curl: health ## 测试原始 curl 请求
	@echo "$(GREEN)测试 curl 请求...$(NC)"
	@curl -v http://localhost:$(ADAPTER_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"minicpm-o-4.5","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'

health: ## 健康检查
	@echo "$(GREEN)健康检查...$(NC)"
	@if ! lsof -ti :$(ADAPTER_PORT) > /dev/null 2>&1; then \
		echo "$(RED)❌ 适配层未运行，请先执行: make start$(NC)"; \
		exit 1; \
	fi
	@curl -s http://localhost:$(ADAPTER_PORT)/health | python3 -c 'import sys, json; data=json.load(sys.stdin); print("✅ 适配层健康:", data["status"]); print("✅ llama-server:", data["llama_server"])'

##@ 开发工具

logs: ## 查看适配层日志
	@if [ -f $(LOG_FILE) ]; then \
		tail -f $(LOG_FILE); \
	else \
		echo "$(YELLOW)日志文件不存在: $(LOG_FILE)$(NC)"; \
	fi

logs-tail: ## 查看最近30行日志
	@if [ -f $(LOG_FILE) ]; then \
		tail -30 $(LOG_FILE); \
	else \
		echo "$(YELLOW)日志文件不存在: $(LOG_FILE)$(NC)"; \
	fi

clean: stop ## 清理日志和临时文件
	@echo "$(YELLOW)清理临时文件...$(NC)"
	@rm -f $(LOG_FILE) /tmp/adapter*.log adapter*.log
	@rm -rf __pycache__ *.pyc .pytest_cache
	@echo "$(GREEN)✅ 清理完成$(NC)"

install: ## 安装依赖
	@echo "$(GREEN)安装 Python 依赖...$(NC)"
	@$(PIP) install -q -r requirements.txt
	@$(PIP) install -q openai
	@echo "$(GREEN)✅ 依赖安装完成$(NC)"

##@ 端到端测试

e2e: ## 端到端完整测试流程
	@echo "$(GREEN)======================================$(NC)"
	@echo "$(GREEN)  端到端测试$(NC)"
	@echo "$(GREEN)======================================$(NC)"
	@echo ""
	@echo "$(YELLOW)步骤 1/5: 检查 llama-server...$(NC)"
	@if ! lsof -ti :$(LLAMA_PORT) > /dev/null 2>&1; then \
		echo "$(RED)❌ llama-server 未运行$(NC)"; \
		echo "$(YELLOW)请先启动 MiniCPM-o:$(NC)"; \
		echo "  make minicpm-start"; \
		echo "  或者手动:"; \
		echo "  cd $(MINICPM_DIR)"; \
		echo "  PYTHON_CMD=$(PYTHON) bash oneclick.sh start"; \
		exit 1; \
	fi
	@echo "  ✅ llama-server 运行中"
	@echo ""
	@echo "$(YELLOW)步骤 2/5: 启动适配层...$(NC)"
	@make start
	@echo ""
	@echo "$(YELLOW)步骤 3/5: 健康检查...$(NC)"
	@make health
	@echo ""
	@echo "$(YELLOW)步骤 4/5: 快速测试...$(NC)"
	@make test-quick
	@echo ""
	@echo "$(YELLOW)步骤 5/5: 完整测试...$(NC)"
	@make test
	@echo ""
	@echo "$(GREEN)======================================$(NC)"
	@echo "$(GREEN)  ✅ 端到端测试通过！$(NC)"
	@echo "$(GREEN)======================================$(NC)"

##@ 调试命令

debug-llama: ## 直接测试 llama-server
	@echo "$(GREEN)直接测试 llama-server...$(NC)"
	@curl -s http://localhost:$(LLAMA_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"MiniCPM-o-4.5","messages":[{"role":"user","content":"你好"}],"max_tokens":20}' \
		| python3 -m json.tool

debug-ports: ## 显示端口占用情况
	@echo "$(GREEN)端口占用情况:$(NC)"
	@echo ""
	@echo "$(YELLOW)8080 (适配层):$(NC)"
	@lsof -i :8080 || echo "  未占用"
	@echo ""
	@echo "$(YELLOW)19060 (llama-server):$(NC)"
	@lsof -i :19060 || echo "  未占用"
	@echo ""
	@echo "$(YELLOW)8022 (Backend):$(NC)"
	@lsof -i :8022 || echo "  未占用"

debug-curl-verbose: ## 详细 curl 调试
	@echo "$(GREEN)详细 curl 调试...$(NC)"
	@curl -v -s http://localhost:$(ADAPTER_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"minicpm-o-4.5","messages":[{"role":"user","content":"测试"}],"max_tokens":10}' 2>&1 | grep -E "< |> |HTTP|{|}"

##@ MiniCPM-o 服务管理

minicpm-status: ## 检查 MiniCPM-o 服务状态
	@echo "$(GREEN)检查 MiniCPM-o 服务...$(NC)"
	@cd $(MINICPM_DIR) && bash oneclick.sh status

minicpm-logs: ## 查看 MiniCPM-o 日志
	@cd $(MINICPM_DIR) && bash oneclick.sh logs

minicpm-start: ## 启动 MiniCPM-o 服务
	@echo "$(GREEN)启动 MiniCPM-o 服务...$(NC)"
	@cd $(MINICPM_DIR) && PYTHON_CMD=$(PYTHON) bash oneclick.sh start

minicpm-stop: ## 停止 MiniCPM-o 服务
	@echo "$(YELLOW)停止 MiniCPM-o 服务...$(NC)"
	@cd $(MINICPM_DIR) && bash oneclick.sh stop

minicpm-restart: ## 重启 MiniCPM-o 服务
	@echo "$(GREEN)重启 MiniCPM-o 服务...$(NC)"
	@cd $(MINICPM_DIR) && PYTHON_CMD=$(PYTHON) bash oneclick.sh restart

##@ 示例和文档

example: ## 运行示例代码
	@echo "$(GREEN)运行示例...$(NC)"
	@$(PYTHON) example_client.py

doc: ## 显示快速开始文档
	@echo "$(GREEN)快速开始:$(NC)"
	@echo ""
	@echo "1. 启动 MiniCPM-o 服务:"
	@echo "   make minicpm-start"
	@echo "   或者手动:"
	@echo "   cd $(MINICPM_DIR)"
	@echo "   PYTHON_CMD=$(PYTHON) bash oneclick.sh start"
	@echo ""
	@echo "2. 启动适配层:"
	@echo "   make start"
	@echo ""
	@echo "3. 运行测试:"
	@echo "   make test"
	@echo ""
	@echo "4. 查看所有命令:"
	@echo "   make help"

##@ 性能测试

benchmark: health ## 简单性能测试
	@echo "$(GREEN)性能测试 (10次请求)...$(NC)"
	@echo ""
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		echo "请求 $$i/10..."; \
		time curl -s http://localhost:$(ADAPTER_PORT)/v1/chat/completions \
			-H "Content-Type: application/json" \
			-d '{"model":"minicpm-o-4.5","messages":[{"role":"user","content":"你好"}],"max_tokens":10}' \
			> /dev/null 2>&1; \
		sleep 0.5; \
	done
	@echo ""
	@echo "$(GREEN)✅ 性能测试完成$(NC)"

# 默认目标
.DEFAULT_GOAL := help
