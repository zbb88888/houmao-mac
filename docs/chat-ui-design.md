# 猴毛 聊天界面 UI / 交互设计

> 最近更新：2026-06-30（新增"极简框一次性问答 → 第 3 次自动升级标准聊天窗口"与"标准办公型可缩放/全屏聊天窗口"交互）
> 单一事实来源：本文件描述 `/chat` 聊天界面的 UI 规范与默认交互；架构进度见 [product-architecture-roadmap.md](product-architecture-roadmap.md)。

---

## 1. 两种对话形态的定位

猴毛有**两个层次**的对话界面，定位与窗口属性完全不同：

| | 极简输入框（Spotlight 式） | 标准聊天窗口（办公式） |
|---|---|---|
| 载体 | `FloatingPanel`（NSPanel，透明悬浮、无标题栏、置顶） | 独立标准 `NSWindow`（titled / closable / miniaturizable / **resizable** / 原生全屏） |
| 唤起 | 双击 Option / 快捷键 | 由极简框自动升级，或输入 `/chat` |
| 定位 | **一次性单轮问答**：问一句答一句，随手即用即走 | **完整办公界面**：多轮上下文、可手动缩放、可全屏、长时间停留 |
| 尺寸 | 跟随内容（`preferredContentSize`），不可拖拽缩放 | 用户可拖拽边缘缩放、可进入 macOS 原生全屏 |
| 上下文 | 无（每次独立） | 多轮历史（`ChatStore`，JSON 持久化，可跨会话） |
| 装饰 | 毛玻璃 + 圆角 + 投影 + 40pt 外边距 | 标准窗口外观（系统标题栏 + 红绿灯按钮） |

**设计意图**：极简框服务"打断式快问快答"；当用户连续多次使用（说明进入了"持续对话"心智），系统自动把它升级成一个真正适合办公的标准聊天窗口，承载多轮上下文，并允许缩放/全屏。

---

## 2. 默认交互：一次性问答 → 自动升级

### 2.1 触发规则

```
极简框第 1 次提交  → 单轮问答（极简框内展示 Q/A）        oneShotTurns = 1
极简框第 2 次提交  → 单轮问答（极简框内展示 Q/A）        oneShotTurns = 2
极简框第 3 次提交  → 自动升级到「标准聊天窗口」          ← 触发点
                     · 隐藏极简框
                     · 打开标准聊天窗口
                     · 把前 2 轮 Q/A 迁移进聊天历史
                     · 第 3 次提交作为聊天首轮（带上下文）
```

- 阈值常量 `autoChatThreshold = 3`：**第 3 次提交即升级**（前两轮完成并缓存后）。
- 计数基准是**已完成的单轮**（`oneShotTurns` 缓存），保证迁移时每轮都有完整回复。
- 用户也可随时手动输入 `/chat` 立即升级（不依赖计数）。

### 2.2 历史迁移

升级时把极简框已发生的前几轮 `(用户问题, 模型回复, 模型名)` 按序灌入 `ChatStore`，保持上下文连贯：

```
oneShotTurns:[(Q1,A1),(Q2,A2)]  ──迁移──▶  ChatStore:[user Q1, assistant A1, user Q2, assistant A2]
                                            然后 appendUser(Q3) + 流式 assistant 回复（history 含 Q1/A1/Q2/A2）
```

迁移后 `oneShotTurns` 清空。

### 2.3 计数重置时机

| 时机 | `oneShotTurns` | 说明 |
|---|---|---|
| 快捷键重新唤起极简框（`resetInput`） | 清空 | 每次唤起是全新一次性会话 |
| 自动/手动升级进入聊天窗口 | 清空（已迁移） | 计数生命周期结束 |
| 退出聊天窗口（`exitChatMode`） | 清空 | 回到待命态 |

---

## 3. 参考对比：微信 vs Chatbox

| 维度 | 微信 | Chatbox | 猴毛标准聊天窗口取舍 |
|---|---|---|---|
| 整体 | 左会话列表 + 右消息流 | 左会话列表 + 右消息流 + 顶部模型条 | **已实现**：左侧会话列表（多会话切换/删除）+ 顶部模型条 |
| 气泡 | 左右分栏、对方左/自己右 | 同左右分栏 | 助手左 + 头像，用户右 + 头像 |
| 头像 | 有 | 有 | 有（助手 `sparkles`，用户 `person.fill`） |
| 输入 | 多行、⏎ 发送、⇧⏎ 换行 | 多行、⏎ 发送、⇧⏎ 换行 | 同（`ChatInputField`，IME 安全） |
| 流式 | 无（IM） | 有"正在输入/逐字" | 有 `TypingIndicator` + 逐 token |
| 发送键 | 圆形发送 | 箭头发送键 | 箭头圆形发送键，loading 变停止键 |
| 窗口 | 可缩放/全屏 | 可缩放/全屏 | **可缩放 + 原生全屏**（标准 NSWindow） |

结论：聊天窗口对齐 Chatbox 的"消息流 + 顶部模型条 + 多行输入 + 流式"，并具备微信/Chatbox 一致的**可缩放、可全屏**桌面办公体验；左侧会话列表留待多会话阶段。

---

## 4. 整体布局

```
┌──────────────────────────────────────────────┐  ← 标准 NSWindow 标题栏（红绿灯 + 可缩放 + 全屏）
│  Chat   [model-badge]                    [✕]  │  chatHeader
├──────────────────────────────────────────────┤  Divider
│                                                │
│   ◎  你好，帮我…                                │  助手气泡（左 + 头像）
│                                                │
│                       帮我总结这段…  ◎          │  用户气泡（右 + 头像）
│                                                │
│   ◎  ●●●（typing）                              │  流式占位
│                                       ▼ 自动滚动 │
├──────────────────────────────────────────────┤  Divider
│  ┌────────────────────────────────┐   ◯↑      │  chatInputBar（多行 + 发送键）
│  │ Message...  (⏎ send · ⇧⏎ nl)   │            │
│  └────────────────────────────────┘            │
└──────────────────────────────────────────────┘
```

- 初始尺寸：宽 `min(900, screen*0.55)`，高 `min(720, screen*0.78)`；用户可自由拖拽缩放，可进入原生全屏。
- 三段式：`chatHeader` / `chatMessageList`（撑满中部、可滚动）/ `chatInputBar`。

---

## 5. 消息气泡规范

| 元素 | 规范 |
|---|---|
| 头像 | 30×30 圆形；助手 `sparkles`（accent 底 + 白）/ 用户 `person.fill`（secondary 25% 底） |
| 气泡圆角 | 16pt continuous |
| 气泡底色 | 用户 accentColor + 白字；助手 暗 `white 10%` / 亮 `black 6%` + 主色字 |
| 内边距 | 水平 12 / 垂直 9 |
| 行间距 | 消息间 16pt |
| 富文本 | 助手：`MarkdownView` 块级渲染（标题/列表/围栏代码块+复制/引用/表格/分隔线，内联委托 `MarkdownParser.inlineAttributed`）；用户：纯文本。均 `textSelection` 可选中 |
| 流式占位 | `TypingIndicator`：三点 6×6，0.32s 轮播，激活 1.0 / 其余 0.3 透明度 |
| 自动滚动 | `ScrollViewReader` 锚底部 `houmao-chat-bottom`；消息数或末条文本变化时 `easeOut(0.15)` 滚到底 |

---

## 6. 底部输入栏

- `ChatInputField`（NSTextView 封装）：多行自增高，单行 ~34pt → 最高 120pt。
- 按键：`⏎` 发送；`⇧⏎` 换行；输入法候选（marked text）时 `⏎` 不误发。
- 占位：`Message...  ( ⏎ send · ⇧⏎ newline )`。
- 发送键：`arrow.up.circle.fill`（28pt）；可发送时 accent，否则 secondary 40%；loading 时变 `stop.circle.fill` 可中止。

---

## 7. 空状态

居中提示：`bubble.left.and.bubble.right`（34pt，secondary 45%）+ "Start a conversation" + "⏎ send · ⇧⏎ newline · /chat to exit"。

---

## 8. 进入 / 退出

| 路径 | 行为 |
|---|---|
| 进入（自动） | 极简框第 3 次提交：隐藏极简框 → 打开标准聊天窗口 → 迁移前 2 轮 → 执行首轮 |
| 进入（手动） | 任意时刻输入 `/chat`：隐藏极简框 → 打开标准聊天窗口（空会话） |
| 聚焦 | 打开聊天窗口时 `NSApp.activate` 使其获得键盘焦点并置前 |
| 退出（标题栏 ✕） | 关闭标准窗口 → `exitChatMode()` |
| 退出（header ✕ / 再输 `/chat`） | `exitChatMode()` → 关闭聊天窗口，回到待命（不自动弹极简框，按快捷键再唤起） |
| 缩放 / 全屏 | 标准窗口原生支持，状态由系统维护 |

---

## 9. 实现映射

| 规范 | 代码 |
|---|---|
| 极简框（一次性） | [MainView.swift](../mac/houmao/houmao/MainView.swift) `compactLayout` |
| 标准聊天 UI | [ChatView.swift](../mac/houmao/houmao/ChatView.swift) |
| 多行输入 | [IMETextField.swift](../mac/houmao/houmao/IMETextField.swift) `ChatInputField` |
| 计数 / 自动升级 / 迁移 | [MainViewModel.swift](../mac/houmao/houmao/MainViewModel.swift) `oneShotTurns` / `autoUpgradeToChat` / `executeChatTurn` |
| 多轮会话容器 | [ChatStore.swift](../mac/houmao/houmao/Core/Chat/ChatStore.swift) + [Conversation.swift](../mac/houmao/houmao/Core/Chat/Conversation.swift) + [ConversationStore.swift](../mac/houmao/houmao/Core/Chat/ConversationStore.swift) |
| 独立可缩放/全屏窗口 | [houmaoApp.swift](../mac/houmao/houmao/houmaoApp.swift) `chatWindow` |

---

## 10. 待精修项

- 多会话左侧列表（多 `Conversation` 管理，已实现）。
- 消息多选 + 右键菜单（收藏 / 分享 / 提醒，见路线图 Phase 3）。
- 代码块高亮、消息时间戳、消息级重试/复制。
- iOS Shell 复用 `ChatView`（Core 与 UI 已分层）。
