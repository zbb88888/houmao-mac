# 🎯 Makefile 配置说明

## 📝 可配置项

在 `Makefile` 开头，你可以修改以下配置：

```makefile
# Python 路径（改为你的 Python 环境）
PYTHON := /Users/ftwhmg/v.v/bin/python

# 端口配置
ADAPTER_PORT := 8080        # 适配层端口
LLAMA_PORT := 19060         # llama-server 端口

# MiniCPM-o 安装路径（改为你的实际路径）
MINICPM_DIR := /Users/ftwhmg/houmao/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo

# 日志文件路径
LOG_FILE := /tmp/adapter_final.log
```

## 🔧 常见修改

### 修改 Python 路径

如果你使用不同的 Python 环境：

```makefile
# 使用 conda 环境
PYTHON := /Users/你的用户名/miniconda3/envs/你的环境/bin/python

# 使用系统 Python
PYTHON := /usr/local/bin/python3

# 使用 pyenv
PYTHON := ~/.pyenv/versions/3.10.0/bin/python
```

### 修改端口

如果端口冲突：

```makefile
ADAPTER_PORT := 8888        # 改为其他端口
LLAMA_PORT := 29060         # 如果你修改了 llama-server 端口
```

### 修改 MiniCPM-o 路径

如果你的 MiniCPM-o 安装在其他位置：

```makefile
MINICPM_DIR := /你的路径/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo
```

## 🚀 新增的 MiniCPM-o 管理命令

### 检查状态
```bash
make minicpm-status
```

### 启动服务
```bash
make minicpm-start
```

### 停止服务
```bash
make minicpm-stop
```

### 重启服务
```bash
make minicpm-restart
```

### 查看日志
```bash
make minicpm-logs
```

## 💡 一键启动工作流

```bash
# 从零开始，一键启动所有服务并测试
make minicpm-start && make start && make test-quick
```

## 🎓 完整工作流示例

```bash
# 1. 启动 MiniCPM-o
make minicpm-start

# 2. 检查状态
make minicpm-status

# 3. 启动适配层
make start

# 4. 测试
make test-quick

# 5. 查看日志（如果需要）
make logs

# 6. 停止所有服务
make stop
make minicpm-stop
```

## 🔍 故障排除

### 问题：路径配置错误

**症状**：`make minicpm-status` 显示"not running"但实际服务在运行

**解决**：修改 Makefile 中的 `MINICPM_DIR` 为你的实际路径

```bash
# 找到你的实际路径
pwd  # 在 WebRTC_Demo 目录执行

# 更新 Makefile
MINICPM_DIR := /你的实际路径
```

### 问题：Python 路径错误

**症状**：`make minicpm-start` 失败

**解决**：修改 `PYTHON` 变量

```bash
# 找到你的 Python 路径
which python

# 更新 Makefile
PYTHON := /你的python路径
```

## 📚 更多信息

- 查看所有命令：`make help`
- 查看快速开始：`make doc`
- 完整文档：`cat INDEX.md`

---

**提示**：修改 Makefile 后，不需要重启服务，下次运行命令时就会使用新配置。
