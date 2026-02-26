# OpenAI Adapter for MiniCPM-o 4.5

简单可靠的 OpenAI 兼容接口，将 OpenAI API 直接代理到 MiniCPM-o 的 llama-server。

## 快速开始

```bash
# 1. 启动 MiniCPM-o（如果未运行）
make minicpm-start

# 2. 启动适配层
make start

# 3. 测试
make test-quick
```

完成！现在可以用 OpenAI SDK 连接 `http://localhost:8080/v1`

## 使用

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    api_key="not-needed",
    base_url="http://localhost:8080/v1"
)

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[{"role": "user", "content": "你好"}]
)

print(response.choices[0].message.content)
```

### curl

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "minicpm-o-4.5",
    "messages": [{"role": "user", "content": "你好"}]
  }'
```

## Makefile 命令

```bash
# 服务管理
make start              # 启动适配层
make stop               # 停止
make restart            # 重启
make status             # 状态

# MiniCPM-o 管理
make minicpm-start      # 启动 MiniCPM-o
make minicpm-stop       # 停止
make minicpm-status     # 状态

# 测试
make test-quick         # 快速测试
make test               # 完整测试
make health             # 健康检查

# 工具
make logs               # 查看日志
make clean              # 清理
make help               # 所有命令
```

## 配置

编辑 `Makefile` 开头的配置：

```makefile
# Python 路径
PYTHON := /Users/你的用户名/v.v/bin/python

# MiniCPM-o 路径
MINICPM_DIR := /Users/你的用户名/路径/WebRTC_Demo
```

编辑 `main.py` 的配置（如需要）：

```python
LLAMA_SERVER_URL = "http://localhost:19060"  # llama-server 地址
TIMEOUT = 300.0  # 请求超时（秒）
```

## 架构

```
你的应用
  ↓
适配层 (8080) [main.py]
  ↓
llama-server (19060)
  ↓
MiniCPM-o-4.5 模型
```

## 功能特性

- ✅ 完全兼容 OpenAI API
- ✅ 支持流式和非流式响应
- ✅ 简单可靠（~100 行透明代理）
- ✅ 自动连接复用
- ✅ 统一错误处理

## 故障排除

### 端口被占用
```bash
make stop && make start
```

### MiniCPM-o 未运行
```bash
make minicpm-status     # 检查状态
make minicpm-start      # 启动
```

### 查看日志
```bash
make logs               # 适配层日志
make minicpm-logs       # MiniCPM-o 日志
```

## 性能

- 响应时间: ~450ms（缓存命中）
- 生成速度: ~52 tokens/s
- 内存占用: 极低（无状态）

## 开发

```bash
# 安装依赖
make install

# 运行测试
python test_openai_sdk.py

# 直接启动（调试用）
python main.py
```

## 依赖

仅 3 个：
- fastapi
- uvicorn
- httpx

## 许可证

MIT
