# 主观能动性（Proactive Agency）— 设计文档

> 状态：v1（2026-07-22）· 面向猴毛「主观能动性」MVP 的落地设计
> 代码落点：`Core/Agent/`（模型 + 协议 + 决策 + 护栏 + 存储 + watcher）、`AgentDaemon.swift`、`AgentViewModel.swift`、`AgentInboxView.swift`（含 header 内的 `AgentSettingsView`/`AgentHelpView` popover）；接线见 `houmaoApp.swift` / `GlobalHotKeyManager.swift` / `PanelSidebar.swift` / `MainViewModel.swift`（agent 配置不经 `SettingsView`，只在 agent 窗 header 的 ⚙️ popover 维护）
> 相关：[product-architecture-roadmap.md](product-architecture-roadmap.md) §3.13 / ADR-13

## 0. 定位：从「被动问答」到「主动感知」的最小闭环

猴毛此前是**纯被动**的：所有 AI 调用都由用户敲命令触发（`/pr`、`/mail`、`/worklog`…），完成即停。本期引入**主观能动性**——一个后台常驻的 **感知(Sense) → 决策(Decide) → 建议(Suggest)** 闭环：无需用户唤醒，猴毛主动监听外部环境（首刀＝GitHub），发现「值得你处理的事」就主动推成**系统通知 + 收件箱面板**，你一键即可触发已有的分析动作。

**核心约束（与既有哲学对齐）**：

- **只『感知 + 建议』，绝不自主执行写/删动作**——所有动作都是「等你一键确认」的建议（严守 ADR-8「删除等破坏性操作必须人工复核」）。
- **极简优先**——复用现有 `GitHubCLI` / `IssueProvider` / `PullRequestProvider` 取数、复用 `notifyTaskDone` 通知链路、复用面板窗口壳（ADR-11/12）。不引入 tool-calling / MCP / 重型编排（ADR-1）。

## 1. 控制论框架 → 猴毛落地映射

主动控制的本质是**感知-决策-行动闭环**。本期把它落成猴毛可承载的最小形态：

| 理论机制 | 猴毛 MVP 落地 | 状态 |
| --- | --- | --- |
| **异步事件驱动后台常驻循环** | `AgentDaemon`：`Timer` 轮询循环（复用 `SelectToCopyManager` 的 Timer 范式）+ `Watcher.poll()` 异步感知 | ✅ |
| **分层双环控制** | 宏观外环＝调度节奏 / 启用哪些 watcher / 静默时段（`AgentPolicy` + 设置）；微观内环＝单 watcher `poll → diff → 建议`。**不做正式状态机**（极简） | ✅（简化） |
| **树搜索 + 主动反思（MCTS / Reflexion）** | **本期降级为未来展望**。MVP 决策＝确定性 diff（当前项 vs 已见集合，只留新项）。未来可选加「LLM 排序/摘要」层 | ⬜ 未来 |
| **确定性护栏（Policy Guardrails）** | 所有 event 均为**建议**；唯一「动作」＝①本地通知 ②收件箱条目 ③一键 `post` 已有 `/pr` `/issue` 命令供用户执行。护栏＝主开关 / 静默时段 / 单轮上限 / URL 去重。**无任何自主写/删** | ✅ |

## 2. 架构分层

严格遵循 Core / Shell 分层（ADR-4）：决策/护栏/存储/取数映射全在纯 Foundation 的 `Core/Agent/`，可单测；后台循环与 UI 在 macOS Shell。

```
Core/Agent/（纯 Foundation，跨平台，可单测）
  AgentEvent.swift    一条主动发现的事项（id=URL / kind / title / subtitle / url / detectedAt / suggestedCommand）
  Watcher.swift       感知源协议：poll() async -> [AgentEvent]
  AgentDiff.swift      决策层（纯函数）：newEvents(current, seen) → 只留未见过的新项（按 id 去重）
  AgentPolicy.swift    护栏（纯值类型）：主开关 / 轮询间隔 / 静默时段 / 单轮上限；allowsPoll(at:)
  AgentStore.swift     持久化：inbox 事件 + 已见 id 集合 → ~/Documents/houmao/agent/inbox.json（纯 codec 可测）
  GitHubWatcher.swift  首刀 watcher：指派给我的 issue + 请求我 review 的 PR（复用 gh providers）

macOS Shell
  AgentDaemon.swift    后台常驻循环（@MainActor @Observable）：Timer → policy 允许则并发 poll → diff → 通知 + 入收件箱 + persist
  AgentViewModel.swift 收件箱面板 VM（分组 / 搜索过滤 / 刷新 / 移除）
  AgentInboxView.swift 收件箱面板视图（ADR-11 壳；header 三按钮：刷新 / ⚙️设置 popover / ?说明 popover；双击=触发建议命令，右键菜单，行内移除）
```

### 2.1 感知（Sense）— Watcher

`Watcher` 协议只做「感知」：`poll()` 返回**当前**所有相关项（不判断新旧）。首刀 `GitHubWatcher` 复用现有 `gh` 封装：

- **指派给我的 issue** → `IssueProvider.fetchAssigned()` → `suggestedCommand = "/issue <url>"`
- **请求我 review 的 PR** → `PullRequestProvider.fetchReviewRequested()`（新增，`gh search prs --review-requested=@me --state=open`）→ `suggestedCommand = "/pr <url>"`

Watcher 协议留有插拔位：未来加 `GmailWatcher`（重要未读邮件）、`TodoWatcher`（逾期待办）只需新增实现，daemon 不改。

### 2.2 决策（Decide）— AgentDiff

MVP 的决策是**确定性**的：`AgentDiff.newEvents(current:seen:)` 用「已见 id 集合」过滤出真正的新项（按 URL 去重，URL 全局唯一）。这保证同一 issue/PR **只提醒一次**，重启后不重复打扰。树搜索 / 多路推演 / LLM 排序留待未来。

### 2.3 建议（Suggest）— 护栏内的动作

护栏 `AgentPolicy` 界定「何时可以主动」：

- **主开关** `isEnabled`：默认**关闭**，用户在 agent 窗口 header 的 ⚙️ 设置里显式开启（不默默后台跑）。
- **轮询间隔** `intervalMinutes`：默认 15 分钟。
- **静默时段** `quietStartHour / quietEndHour`：本地时钟小时窗口（支持跨午夜，如 22→8）；`start == end` 表示不启用。
- **单轮上限** `maxPerPoll`：首次面对大量积压时，一轮最多推送 N 条通知（默认 5），避免刷屏。

护栏内，猴毛能自主做的**仅限三件无破坏性的事**：弹本地通知、往收件箱追加条目、把 `suggestedCommand` 一键 `post` 给 `handleToolCommand` 让**用户**去执行分析。任何写库/删邮件/改文件都不在此列。

## 3. 后台循环（AgentDaemon）

```
每次 Timer tick：
  if !AgentPolicy.allowsPoll(now)  → 跳过（未启用 / 静默时段）
  并发 poll 所有【启用的】watcher → current: [AgentEvent]
  fresh = AgentDiff.newEvents(current, seen)
  seen ∪= fresh.ids;  events = fresh + events（新的在前）;  persist()
  若 fresh 非空 → onNewEvents(fresh.prefix(maxPerPoll)) → 本地通知
```

- 启用 / 改间隔 / 改静默时段后调 `applyPolicy()` 重建 Timer；启用后**立即先 poll 一次**，用户不必等满一个周期。
- `refreshNow()` 供收件箱「刷新」按钮手动触发。
- 单例，由 `AppDelegate` 在启动时创建并注入 `onNewEvents`（通知逻辑属 Shell，不进 Core）。

## 4. 呈现（收件箱面板 + 通知）

- **系统本地通知**：复用 `AppDelegate.notifyTaskDone` 同款链路（`UNUserNotificationCenter`）。多条新项时推一条汇总（「猴毛发现 N 项新动态」）。通知 `userInfo` 打标 `houmao.kind = "agent"`，点击 → 打开收件箱面板（不影响既有「任务完成」通知）。
- **收件箱面板**（窗口标题 `agent`，rail 图标 `bell.badge`「动态」）：照 ADR-11 壳，**功能自包含在这一个独立窗口**。header（图标按钮靠左）三按钮：**刷新**（`arrow.clockwise`，手动强制检查一次）/ **设置**（`gearshape` → popover：主开关 / GitHub watcher / 轮询间隔 / 静默时段，改动即 `AgentDaemon.applyPolicy()`）/ **使用说明**（`questionmark.circle` → popover：是什么 / 开启 / 交互 / 提醒 的使用手册）。主体两分区——「请求我 review」（PR）/「指派给我」（issue）。行＝图标 + 标题 + 仓库 + 时间；**双击 = 触发建议命令**（`post` `/pr`/`/issue` 走聊天分析）；右键菜单＝分析 / 在浏览器打开 / 复制链接 / 移除；行内 `xmark` = 移除（仅从收件箱移除，仍留在 `seen` 不再重复提醒）。空态提示 + 最近轮询时间。
- **设置单一来源**：agent 的配置只在本窗口的 ⚙️ popover 维护（`AgentSettingsView` 直接绑定 `AppSettings`），**不再放进全局 ⌘, 设置**，避免两处重复维护——契合「功能独立窗口自维护」。

## 5. 存储格式

`~/Documents/houmao/agent/inbox.json`（单文件 JSON，ISO-8601 日期）：

```json
{
  "events": [ { "id": "<url>", "kind": "reviewRequestedPR", "title": "…", "subtitle": "owner/repo", "url": "…", "detectedAt": "2026-07-22T09:00:00Z", "suggestedCommand": "/pr <url>" } ],
  "seen": [ "<url>", "…" ]
}
```

- `events`：当前收件箱（未移除项）。
- `seen`：所有曾提醒过的 id（含已移除），用于去重、防重启重复打扰。
- `AgentStore.encode/decode` 为纯静态方法，脱离文件系统单测。

## 6. 范围边界

**本期含**：GitHub watcher（指派 issue + review-requested PR）、后台轮询循环、本地通知、收件箱面板（header 自带 ⚙️设置 popover + ?说明 popover）、设置项（主开关 / 间隔 / 静默时段 / GitHub watcher 开关，只在 agent 窗维护）、纯建议护栏、三组纯函数单测、本设计文档。

**本期不含（未来展望）**：

- Gmail / Todo / Goal watcher（`Watcher` 协议已预留插拔位）。
- tool-calling / MCP / 让 LLM 自主选工具收发。
- MCTS 树搜索 / 多路推演 / Reflexion 自我批评。
- 任何自主写 / 删 / 改动作（始终「建议 + 人工一键」）。
- LLM 对收件箱的智能排序 / 摘要 / 优先级打分。

## 7. 验证

- **单测**（Swift Testing）：`AgentDiffTests`（新旧过滤 / URL 去重 / 空集合）、`AgentStoreTests`（events + seen round-trip / 缺文件返空 / 多项）、`AgentPolicyTests`（静默时段边界含跨午夜 / 未启用 / 固定 now）。
- **构建**：新增 `.swift` 后 `cd mac/houmao && xcodegen generate` → `make build` → `make test`。
- **手动**（需 `gh auth login`）：agent 窗 header ⚙️ 开启主观能动性 → header ⟳ 刷新 → 指派 issue / review PR 进收件箱并弹通知 → 双击一键 `post /pr` → ghia 分析进聊天 → 移除某项 → **重启 app** 后收件箱持久化、已提醒项不重复通知。GUI 无头环境只保证编译 + 纯逻辑单测，真实 gh 联调需本地 `gh auth`。
