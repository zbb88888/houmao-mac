# 复用 Frontend Session 的使用方法

适配层现在支持三种 session 管理方式：

## 方式 1：复用 Frontend 的 Session（推荐）⭐

当 OneClick.sh 启动了完整服务（包括 Frontend）时，你可以从浏览器复制 session 信息，然后配置给适配层。

### 步骤：

#### 1. 启动 MiniCPM-o 完整服务
```bash
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start
```

#### 2. 在浏览器打开 Frontend
```
https://localhost:8088
```

#### 3. 从浏览器控制台获取 session 信息

**方法 A：从 Network 面板获取（最简单）**

1. 打开浏览器开发者工具 (F12)
2. 切换到 "Network" 标签
3. 在 Frontend 点击登录/开始对话
4. 找到 `/api/login` 请求
5. 查看响应，复制以下信息：
   - `userId`
   - `sessionId`
   - `token`（可选）

**方法 B：从 Console 执行脚本**

在浏览器控制台执行：
```javascript
// 如果应用有存储 session
console.log(localStorage)
// 或查看网络请求
```

#### 4. 配置环境变量并启动适配层

```bash
cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter

# 设置环境变量
export MINICPM_USER_ID="你的userId"
export MINICPM_SESSION_ID="你的sessionId"
export MINICPM_TOKEN="你的token"  # 可选

# 启动适配层
/Users/ftwhmg/v.v/bin/python main.py
```

示例：
```bash
export MINICPM_USER_ID="d600c7db-855b-4cff-9539-7853a31af188"
export MINICPM_SESSION_ID="d600c7db-855b-4cff-9539-7853a31af18820"
/Users/ftwhmg/v.v/bin/python main.py
```

#### 5. 测试
```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "minicpm-o-4.5",
    "messages": [{"role": "user", "content": "你好"}]
  }'
```

### 优点
- ✅ Frontend 和适配层可以同时使用
- ✅ 共享同一个推理服务
- ✅ 浏览器可以正常测试
- ✅ Houmao 也能通过 API 访问

### 注意事项
- ⚠️ Session 有效期是 10 分钟，过期后需要重新获取
- ⚠️ 如果 Frontend 长时间不活动，session 可能被释放
- ⚠️ Frontend 和 API 会共享同一个对话上下文

---

## 方式 2：只启动 Backend（不启动 Frontend）

如果你不需要 Frontend，可以只启动 Backend 和 C++ Server。

### 步骤：

#### 1. 手动启动服务（跳过 Frontend）

```bash
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/

# 启动 LiveKit
bash oneclick.sh start

# 然后手动停止 Frontend
kill $(cat .pids/frontend.pid)
```

#### 2. 直接启动适配层
```bash
cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter
/Users/ftwhmg/v.v/bin/python main.py
```

适配层会自动创建 session。

### 优点
- ✅ 推理服务完全留给适配层
- ✅ 无需手动配置 session
- ✅ 简单直接

### 缺点
- ❌ 无法使用浏览器测试
- ❌ 需要额外步骤停止 Frontend

---

## 方式 3：自动创建 Session（默认）

如果没有配置环境变量，且没有 busy 的服务，适配层会自动创建新 session。

```bash
cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter
/Users/ftwhmg/v.v/bin/python main.py
```

这是默认行为，适用于独占使用的场景。

---

## 故障排除

### 问题：显示 "没有可用的推理服务"

**原因**：推理服务被占用（Frontend 正在使用）

**解决**：
1. 使用方式 1（配置环境变量复用 session）
2. 或者停止 Frontend 释放服务

### 问题：Session 过期

**现象**：10 分钟后请求失败

**解决**：
1. 重新从浏览器获取 session
2. 重新启动适配层
3. 或实现自动刷新机制（TODO）

### 问题：Frontend 和 API 响应混乱

**原因**：共享同一个对话上下文

**解决**：
- 使用不同的 API key 区分会话
- 或者使用方式 2（不启动 Frontend）

---

## 快速开始（推荐流程）

```bash
# 1. 启动 MiniCPM-o 服务
cd /Users/ftwhmg/g/MiniCPM-V-CookBook/demo/web_demo/WebRTC_Demo/
PYTHON_CMD=/Users/ftwhmg/v.v/bin/python bash oneclick.sh start

# 2. 打开浏览器访问 https://localhost:8088
# 3. 登录后，从 Network 面板复制 userId 和 sessionId

# 4. 启动适配层（使用复用的 session）
cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter
export MINICPM_USER_ID="你的userId"
export MINICPM_SESSION_ID="你的sessionId"
/Users/ftwhmg/v.v/bin/python main.py

# 5. 测试
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "minicpm-o-4.5", "messages": [{"role": "user", "content": "你好"}]}'
```

完成！现在 Frontend 和 API 可以同时工作了。
