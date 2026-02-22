# 📁 项目结构

```
openai_adapter/
├── Makefile                    # ⭐ 核心：一键命令管理工具
├── main.py                     # ⭐ 核心：适配层主程序
├── requirements.txt            # Python 依赖
│
├── README.md                   # 完整文档
├── QUICKSTART.md              # ⭐ 快速开始（推荐先看这个）
├── SESSION_REUSE.md           # Session 复用文档（已弃用）
│
├── test_openai_sdk.py         # ⭐ OpenAI SDK 测试（推荐使用）
├── example_client.py          # 客户端使用示例
├── test_direct.py             # 直接测试脚本
│
└── get_session.sh             # Session 查询脚本（已弃用）
```

## 📖 文档阅读顺序

1. **QUICKSTART.md** ⭐ - 5分钟快速上手
2. **README.md** - 完整功能说明
3. **Makefile** - 查看所有可用命令

## 🚀 快速使用

```bash
# 1. 查看帮助
make help

# 2. 启动服务
make start

# 3. 快速测试
make test-quick

# 完成！
```

## 📝 核心文件说明

### `Makefile` - 命令中心
一键执行所有操作：启动、测试、调试、日志查看等。

**最常用命令**：
- `make start` - 启动
- `make test-quick` - 测试
- `make status` - 状态
- `make logs` - 日志

### `main.py` - 适配层实现
简单的 HTTP 代理，将 OpenAI 格式转发到 llama-server。

**核心逻辑**：
```python
# 接收 OpenAI 格式
POST /v1/chat/completions

# 转发到 llama-server
POST http://localhost:19060/v1/chat/completions

# 返回 OpenAI 格式
```

### `test_openai_sdk.py` - 标准测试
使用 OpenAI SDK 进行测试，展示正确用法。

**运行方式**：
```bash
make test              # 通过 Makefile
python test_openai_sdk.py  # 直接运行
```

## 🔧 配置说明

### 端口配置

在 `main.py` 中：
```python
LLAMA_SERVER_URL = "http://localhost:19060"  # llama-server 地址
```

在 `Makefile` 中：
```makefile
ADAPTER_PORT := 8080   # 适配层端口
LLAMA_PORT := 19060    # llama-server 端口
```

### Python 路径配置

在 `Makefile` 中：
```makefile
PYTHON := /Users/ftwhmg/v.v/bin/python  # 修改为你的 Python 路径
```

## 🎯 使用场景

### 场景 1：开发测试
```bash
make start && make test-quick
```

### 场景 2：持续运行
```bash
make start   # 后台运行
# ... 使用应用 ...
make stop    # 停止
```

### 场景 3：调试问题
```bash
make status       # 检查状态
make logs-tail    # 查看日志
make debug-llama  # 测试后端
```

### 场景 4：集成到应用
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
```

## 📊 依赖关系

```
你的应用
    ↓
openai_adapter (port 8080)
    ↓
llama-server (port 19060)
    ↓
MiniCPM-o-4.5-Q4_K_M.gguf
```

## 🔄 工作流程

1. **启动 MiniCPM-o**（一次性）
   ```bash
   cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
   PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start
   ```

2. **启动适配层**（每次开发时）
   ```bash
   cd openai_adapter
   make start
   ```

3. **使用应用**
   - 通过 OpenAI SDK 连接 `http://localhost:8080/v1`
   - 完全兼容 OpenAI API

4. **停止服务**（完成工作后）
   ```bash
   make stop
   ```

## 🎓 学习路径

### 初学者
1. 运行 `make doc` 查看快速开始
2. 运行 `make test-quick` 看效果
3. 查看 `test_openai_sdk.py` 学习用法

### 开发者
1. 阅读 `main.py` 了解实现
2. 查看 `Makefile` 学习命令
3. 运行 `make e2e` 完整测试

### 高级用户
1. 自定义 `main.py` 添加功能
2. 修改 `Makefile` 添加命令
3. 扩展多模态支持（图像、音频）

## 💡 最佳实践

1. **始终使用 Makefile**：`make start` 而不是 `python main.py`
2. **开发前先测试**：`make test-quick` 确保服务正常
3. **遇到问题看日志**：`make logs-tail` 查看错误
4. **定期清理**：`make clean` 清理临时文件

## 🚨 常见错误

### 错误 1：端口被占用
```bash
# 解决：
make stop && make start
```

### 错误 2：llama-server 未运行
```bash
# 检查：
make minicpm-status

# 启动：
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start
```

### 错误 3：依赖缺失
```bash
# 解决：
make install
```

## 📞 获取帮助

```bash
make help          # 查看所有命令
make doc           # 快速开始文档
cat README.md      # 完整文档
cat QUICKSTART.md  # 快速指南
```

---

**更新时间**: 2026-02-22
