# 🚀 快速开始指南

## 一键测试（最简单）

```bash
# 1. 确保 MiniCPM-o 已启动
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start

# 2. 在 openai_adapter 目录
cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter

# 3. 启动并测试（一条命令）
make start && make test-quick
```

完成！🎉

---

## Makefile 常用命令

### 📊 服务管理

```bash
make start          # 启动适配层
make stop           # 停止适配层
make restart        # 重启适配层
make status         # 查看服务状态
```

### ✅ 测试命令

```bash
make health         # 健康检查
make test-quick     # 快速测试（推荐）
make test-stream    # 测试流式响应
make test           # 完整测试套件
make e2e            # 端到端完整测试
```

### 🔍 调试工具

```bash
make logs           # 实时查看日志
make logs-tail      # 查看最近30行日志
make debug-llama    # 直接测试 llama-server
make debug-ports    # 查看端口占用
```

### 🛠 开发工具

```bash
make install        # 安装依赖
make clean          # 清理临时文件
make example        # 运行示例代码
make benchmark      # 性能测试
```

### 📚 帮助文档

```bash
make help           # 显示所有命令
make doc            # 快速开始文档
```

---

## 典型工作流

### 场景 1：日常开发测试

```bash
# 启动服务
make start

# 快速测试
make test-quick

# 查看日志（如果有问题）
make logs-tail
```

### 场景 2：完整验证

```bash
# 端到端测试（自动检查所有组件）
make e2e
```

### 场景 3：调试问题

```bash
# 查看服务状态
make status

# 查看端口占用
make debug-ports

# 直接测试 llama-server
make debug-llama

# 查看详细日志
make logs
```

### 场景 4：性能测试

```bash
# 运行性能基准测试
make benchmark
```

---

## 故障排除

### 问题：端口被占用

```bash
make stop           # 强制停止
make start          # 重新启动
```

### 问题：测试失败

```bash
# 1. 检查状态
make status

# 2. 查看日志
make logs-tail

# 3. 测试 llama-server
make debug-llama

# 4. 重启
make restart
```

### 问题：MiniCPM-o 未运行

```bash
# 检查 MiniCPM-o 状态
make minicpm-status

# 如果未运行，启动它：
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start
```

---

## 示例输出

### `make test-quick` 输出

```
✅ 响应: 你好，我是MiniCPM系列模型，由面壁智能和OpenBMB开源社区开发。
📊 Token 使用: 42
```

### `make status` 输出

```
服务状态检查:

适配层 (port 8080):
  ✅ 运行中 (PID: 12840)

llama-server (port 19060):
  ✅ 运行中 (PID: 10748)
```

### `make health` 输出

```
健康检查...
✅ 适配层健康: healthy
✅ llama-server: healthy
```

---

## 高级用法

### 自定义 Python 路径

编辑 `Makefile` 的开头部分：

```makefile
PYTHON := /your/custom/python/path
```

### 自定义端口

```makefile
ADAPTER_PORT := 8888  # 改为其他端口
```

### 持续集成

```bash
# CI 脚本示例
make install
make start
make e2e
make stop
```

---

## 性能优化建议

1. **首次请求慢**：正常现象，模型加载需要时间
2. **后续请求快**：利用 KV cache，响应速度显著提升
3. **并发测试**：可以多个终端同时运行 `make test-quick`

---

## 下一步

- 查看完整文档：`cat README.md`
- 运行示例代码：`make example`
- 查看所有命令：`make help`

---

**提示**: 所有 make 命令都可以在 `openai_adapter` 目录下执行。
