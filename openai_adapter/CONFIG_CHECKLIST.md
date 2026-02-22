# ✅ 配置检查清单

在开始使用前，请确认以下配置：

## 1️⃣ Makefile 配置检查

打开 `Makefile`，确认以下配置是否正确：

```bash
# 查看当前配置
head -20 Makefile | grep -E "PYTHON|MINICPM_DIR"
```

### 必须配置项

- [ ] **PYTHON** - Python 解释器路径
  ```makefile
  PYTHON := /Users/ftwhmg/v.v/bin/python  # 改为你的路径
  ```
  验证：`$(PYTHON) --version` 应该能运行

- [ ] **MINICPM_DIR** - MiniCPM-o 安装目录
  ```makefile
  MINICPM_DIR := /Users/ftwhmg/houmao/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo
  ```
  验证：该目录下应该有 `oneclick.sh` 文件

### 可选配置项

- [ ] **ADAPTER_PORT** - 适配层端口（默认 8080）
- [ ] **LLAMA_PORT** - llama-server 端口（默认 19060）
- [ ] **LOG_FILE** - 日志文件路径

## 2️⃣ 路径验证

运行以下命令验证配置：

```bash
# 验证 Python
make -n minicpm-start | head -1

# 验证 MiniCPM-o 路径
make minicpm-status
```

如果看到 "not running" 但实际服务在运行，说明路径配置错误。

## 3️⃣ 快速修复

### 修复 Python 路径

```bash
# 1. 找到你的 Python 路径
which python
# 或
/Users/ftwhmg/v.v/bin/python --version

# 2. 编辑 Makefile
# 修改第 8 行：PYTHON := 你的路径
```

### 修复 MiniCPM-o 路径

```bash
# 1. 找到实际路径
cd /Users/ftwhmg/houmao/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo
pwd

# 2. 编辑 Makefile
# 修改第 12 行：MINICPM_DIR := 你复制的路径
```

## 4️⃣ 配置验证测试

运行完整验证：

```bash
# 检查 MiniCPM-o
make minicpm-status

# 检查适配层
make status

# 运行快速测试
make test-quick
```

全部通过说明配置正确！✅

## 5️⃣ 常见配置问题

### 问题 1：make minicpm-status 显示 "not running"

**原因**：`MINICPM_DIR` 路径错误

**解决**：
```bash
# 找到正确路径
cd 你的MiniCPM-o目录
pwd
# 复制输出，更新 Makefile 中的 MINICPM_DIR
```

### 问题 2：make minicpm-start 失败

**原因**：`PYTHON` 路径错误

**解决**：
```bash
# 找到正确的 Python
which python
# 或者如果使用 virtualenv/conda：
which python3
# 复制输出，更新 Makefile 中的 PYTHON
```

### 问题 3：端口冲突

**原因**：`ADAPTER_PORT` 被占用

**解决**：
```makefile
# 修改 Makefile
ADAPTER_PORT := 8888  # 改为其他端口
```

## 6️⃣ 配置模板

根据你的环境选择：

### macOS + virtualenv
```makefile
PYTHON := /Users/你的用户名/.virtualenvs/你的环境/bin/python
MINICPM_DIR := /Users/你的用户名/路径/WebRTC_Demo
```

### macOS + conda
```makefile
PYTHON := /Users/你的用户名/miniconda3/envs/你的环境/bin/python
MINICPM_DIR := /Users/你的用户名/路径/WebRTC_Demo
```

### Linux
```makefile
PYTHON := /home/你的用户名/.virtualenvs/你的环境/bin/python
MINICPM_DIR := /home/你的用户名/路径/WebRTC_Demo
```

## 7️⃣ 验证清单

完成配置后，运行以下检查：

```bash
# ✅ 检查 1：Makefile 语法
make -n help

# ✅ 检查 2：MiniCPM-o 状态
make minicpm-status

# ✅ 检查 3：适配层启动
make start

# ✅ 检查 4：健康检查
make health

# ✅ 检查 5：快速测试
make test-quick
```

全部通过 = 配置完成！🎉

## 8️⃣ 获取帮助

```bash
# 查看所有命令
make help

# 查看配置文档
cat MAKEFILE_CONFIG.md

# 查看快速开始
cat QUICKSTART.md
```

---

**提示**：配置正确后，你可以用 `make minicpm-start && make start && make test-quick` 一键启动所有服务并测试！
