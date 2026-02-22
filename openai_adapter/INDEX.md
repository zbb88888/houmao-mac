# 📚 OpenAI Adapter 文档索引

欢迎使用 OpenAI Adapter for MiniCPM-o 4.5！

## 🚀 快速开始（5分钟）

```bash
# 1. 查看帮助
make help

# 2. 启动服务
make start

# 3. 快速测试
make test-quick
```

完成！现在你可以使用 OpenAI SDK 连接到 `http://localhost:8080/v1`

---

## 📖 文档导航

### 🎯 按使用场景

| 场景 | 文档 | 说明 |
|------|------|------|
| **第一次使用** | [QUICKSTART.md](./QUICKSTART.md) ⭐ | 5分钟快速上手 |
| **日常开发** | [Makefile](#makefile-命令) | 一键命令参考 |
| **了解项目** | [PROJECT.md](./PROJECT.md) | 项目结构和架构 |
| **完整功能** | [README.md](./README.md) | 详细功能说明 |
| **项目总结** | [SUMMARY.md](./SUMMARY.md) | 完成状态和亮点 |

### 📂 按文件类型

#### 核心文件
- **main.py** - 适配层主程序（HTTP 代理）
- **Makefile** ⭐ - 命令管理工具（最常用）
- **requirements.txt** - Python 依赖

#### 测试文件
- **test_openai_sdk.py** ⭐ - OpenAI SDK 标准测试（推荐）
- **test_direct.py** - 直接测试脚本
- **example_client.py** - 客户端使用示例

#### 文档文件
- **QUICKSTART.md** ⭐ - 快速开始（推荐先看）
- **README.md** - 完整文档
- **PROJECT.md** - 项目结构
- **SUMMARY.md** - 项目总结
- **CONFIG_CHECKLIST.md** ⭐ - 配置检查清单
- **MAKEFILE_CONFIG.md** - Makefile 配置说明
- **SESSION_REUSE.md** - Session 复用（已弃用）

#### 工具脚本
- **get_session.sh** - Session 查询（已弃用）

---

## 🎯 Makefile 命令

### 最常用（Top 5）
```bash
make help          # 查看所有命令
make start         # 启动服务
make test-quick    # 快速测试
make status        # 查看状态
make logs          # 查看日志
```

### 完整列表
```bash
# 服务管理
make start         # 启动适配层
make stop          # 停止适配层
make restart       # 重启适配层
make status        # 查看服务状态

# MiniCPM-o 管理 ⭐ 新增
make minicpm-status   # 检查 MiniCPM-o 状态
make minicpm-start    # 启动 MiniCPM-o
make minicpm-stop     # 停止 MiniCPM-o
make minicpm-restart  # 重启 MiniCPM-o
make minicpm-logs     # 查看 MiniCPM-o 日志

# 测试命令
make health        # 健康检查
make test-quick    # 快速测试（单次对话）
make test-stream   # 测试流式响应
make test          # 完整测试套件
make e2e           # 端到端测试

# 调试工具
make logs          # 实时查看日志
make logs-tail     # 查看最近30行
make debug-llama   # 直接测试 llama-server
make debug-ports   # 显示端口占用

# 开发工具
make install       # 安装依赖
make clean         # 清理临时文件
make example       # 运行示例
make benchmark     # 性能测试
```

---

## 💡 使用建议

### 新手路径
1. ✅ 阅读 [QUICKSTART.md](./QUICKSTART.md)
2. ✅ 运行 `make start && make test-quick`
3. ✅ 查看 [test_openai_sdk.py](./test_openai_sdk.py) 学习用法

### 开发者路径
1. ✅ 阅读 [PROJECT.md](./PROJECT.md) 了解架构
2. ✅ 查看 [main.py](./main.py) 了解实现
3. ✅ 运行 `make test` 完整测试

### 集成路径
1. ✅ 阅读 [README.md](./README.md) 了解 API
2. ✅ 参考 [example_client.py](./example_client.py)
3. ✅ 在你的应用中使用 OpenAI SDK

---

## 🔍 快速查找

### 我想...

| 需求 | 命令/文档 |
|------|----------|
| 启动服务 | `make start` |
| 测试是否正常 | `make test-quick` |
| 查看所有命令 | `make help` |
| 查看日志 | `make logs` |
| 了解如何使用 | [QUICKSTART.md](./QUICKSTART.md) |
| 了解项目结构 | [PROJECT.md](./PROJECT.md) |
| 查看 API 文档 | [README.md](./README.md) |
| 集成到代码 | [example_client.py](./example_client.py) |
| 解决问题 | [QUICKSTART.md#故障排除](./QUICKSTART.md#故障排除) |

---

## 📊 架构概览

```
你的应用 (OpenAI SDK)
    ↓
适配层 (port 8080) [main.py]
    ↓
llama-server (port 19060)
    ↓
MiniCPM-o-4.5 模型
```

---

## ✅ 验证清单

在使用前，确保：

- [ ] MiniCPM-o 服务已启动（`make minicpm-status`）
- [ ] 适配层已启动（`make start`）
- [ ] 健康检查通过（`make health`）
- [ ] 快速测试成功（`make test-quick`）

---

## 🆘 获取帮助

```bash
# 命令帮助
make help

# 查看文档
cat QUICKSTART.md    # 快速开始
cat README.md        # 完整文档
cat PROJECT.md       # 项目结构

# 调试问题
make status          # 检查状态
make logs-tail       # 查看日志
make debug-ports     # 端口占用
```

---

## 📞 问题排查

| 问题 | 解决方法 |
|------|---------|
| 端口被占用 | `make stop && make start` |
| 测试失败 | `make status` 然后 `make logs-tail` |
| llama-server 未运行 | `make minicpm-status` |
| 不知道怎么用 | 阅读 [QUICKSTART.md](./QUICKSTART.md) |

---

## 🎓 学习资源

- [MiniCPM-o 官方](https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf)
- [OpenAI API 文档](https://platform.openai.com/docs/api-reference)
- [llama.cpp 项目](https://github.com/ggerganov/llama.cpp)

---

**最后更新**: 2026-02-22
**状态**: ✅ 生产就绪
**版本**: 1.0.0

---

## 🎉 开始使用

```bash
# 一键启动并测试（推荐）⭐
make minicpm-start && make start && make test-quick

# 或者分步执行
make minicpm-start    # 启动 MiniCPM-o
make start            # 启动适配层
make test-quick       # 快速测试
```

享受 MiniCPM-o 4.5 的强大能力！🚀
