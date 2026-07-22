# 主观能动性（Proactive Agency）— 设计文档

> 状态：v2（2026-07-22）· MVP（§0–§7，GitHub watcher）+ 邮件 watcher（§8）
> 代码落点：`Core/Agent/`（模型 + 协议 + 决策 + 护栏 + 存储 + watcher）、`Core/Mail/`（§8 新增签名 + 记忆 store）、`AgentDaemon.swift`、`AgentViewModel.swift`、`AgentInboxView.swift`（含 header 内的 `AgentSettingsView`/`AgentHelpView` popover）、`MailWatcher.swift`；接线见 `houmaoApp.swift` / `GlobalHotKeyManager.swift` / `PanelSidebar.swift` / `MainViewModel.swift`（agent 配置不经 `SettingsView`，只在 agent 窗 header 的 ⚙️ popover 维护）
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

## 8. 邮件 watcher：后台预热 + 去重折叠（v2）

**动机**（用户痛点）：现有 `/mail` ①**点击才分析、每次都等 LLM**（`MailViewModel` 无缓存、无定时器、每次重新全量拉取+聚簇）；②**重复邮件每次全量重看**（`MailCluster.id` 是运行时 UUID、不落盘，跨会话无「看过/处理过」的记忆）。用「主观能动性」把这两点变主动。

### 8.1 两个能力 → 复用 agent 基建

| 痛点 | 能力 | 落地 |
| --- | --- | --- |
| 每次点、每次等 | **后台预热摘要缓存** | `MailWatcher` 在 agent 轮询周期里，对**新簇**提前用 `AiTxtClient.ask` 生成一句话摘要（仅用 metadata 的 subject+snippet，不 `fetchFull`，省成本）→ 落盘缓存（键=簇稳定签名）。开 `/mail` 直接读缓存**秒显**。 |
| 重复邮件全量重看 | **去重记忆 + 折叠已看** | 给簇算**跨会话稳定签名**，持久化「已看」集合。`/mail` 打开时**已看簇默认隐藏/折叠**，只留新簇。 |
| （更主动） | **重要新邮件进收件箱** | `MailWatcher.poll()` 对新且非例行的簇返回 `AgentEvent(kind: .newMailCluster, suggestedCommand: "/mail")`，走既有 daemon → 通知 +「动态」收件箱。 |

### 8.2 两种签名（"两者都要"）

- **精确签名** `MailSignature.cluster(_)`：成员 Gmail `message-id` 排序后 join → **SHA256 hex**（`message-id` 全局唯一且不变；用 SHA256 而非 `hashValue`——后者每进程随机化、不可持久化）。命中"同一批邮件"。
- **家族签名** `MailSignature.family(_)`：`归一化(发件人) + "|" + 归一化(代表主题)`（主题小写、去数字/日期、压空白）。命中"反复出现的相似邮件"（周报 / newsletter，每期 message-id 不同但同模板）。
- **折叠判定**：簇 `isSeen` = 精确签名 ∈ `seenClusters` **或** 家族签名 ∈ `seenFamilies` → 两种"重复"都覆盖。

### 8.3 存储 `MailMemoryStore`（`Core/Mail/`，纯 Foundation 可单测）

`~/Documents/houmao/mail/memory.json`：

```json
{ "summaries": { "<clusterSig>": "一句话摘要" },
  "seenClusters": ["<clusterSig>"],
  "seenFamilies": ["<familyKey>"] }
```

- `summaries`：预热/分析过的一句话摘要（`/mail` 行内直接显示，不等 LLM）。
- `seenClusters` / `seenFamilies`：跨会话"看过"记忆，用于折叠。
- 纯静态 `encode/decode` + `load/save`（脱离文件系统单测）。

### 8.4 时序

```
【后台】MailWatcher.poll()（agent 循环，受同一护栏 enable/间隔/静默时段约束）
  未连 Gmail / 未开 mail watcher → 返回 []
  listMessages+fetchMetadata → MailGrouping.group → clusters
  读 MailMemoryStore
  对每个 cluster：sig=精确签名, fam=家族签名
    若 !seen(sig,fam) 且 category 非 促销/社交（省成本）：
      预热：summaries[sig] 缺失 → AiTxtClient.ask(subject+snippet) 一句话 → 缓存
      产出 AgentEvent(id=sig, kind=.newMailCluster, title=代表主题, subtitle="大类 · N 封", suggestedCommand="/mail")
  保存 summaries（不在这里标 seen——"看过"以用户实际在 /mail 展示为准）
  返回 events（单轮上限 maxPerPoll，daemon 按 id=sig 去重 → 通知 + 收件箱）

【打开 /mail】MailViewModel.applyGrouping()
  读 MailMemoryStore：每簇附 summary(sig) + 快照 isSeen(sig,fam)【标记前先快照】
  之后把本次展示的所有簇的 sig+fam 写入 seenClusters/seenFamilies 并 save（下次即折叠）
  UI：hideSeen 默认 true → 隐藏已看簇，顶部横幅「已隐藏 N 个看过的 · 显示」；每簇行显示缓存摘要（有则）
```

### 8.5 护栏与边界（延续 §2.3）

- 仍**只感知 + 建议**：邮件 watcher 只读取 + 生成摘要 + 提醒，**绝不自动删/归档/标记**邮件（严守 ADR-8）。
- **成本控制**：只对"新且非例行"簇预热；跳过 促销/社交；每轮 `maxPerPoll` 上限；摘要只用 metadata（不 `fetchFull`），每簇 1 次轻量 LLM。未连 Gmail 或未开 mail watcher 时 watcher 直接空转。
- **对 §2.1 的偏离（记录）**：`GitHubWatcher.poll()` 是纯感知；`MailWatcher.poll()` 额外有"预热摘要写缓存"的副作用——这是邮件主动性的自然归属，已在此显式记录（非纯感知）。
- 开关：`AppSettings.agentMailWatcherEnabled`（agent 窗 ⚙️ popover 里，与 GitHub watcher 并列），默认开启但仅在总开关 `agentEnabled` 且已连 Gmail 时才实际跑。

### 8.6 范围

**含**：`MailSignature`（精确+家族）、`MailMemoryStore`、`MailWatcher`（预热+感知）、`AgentEvent.Kind.newMailCluster`、收件箱新分区、mail watcher 开关、`MailViewModel`/`MailView` 读缓存显示 + hideSeen 折叠、单测（签名 + 记忆 store）。

**不含（未来）**：自动删/归档/静音例行邮件（仍人工）、正文级摘要（现只 metadata）、跨设备同步这份记忆、把摘要写回 Gmail。

### 8.7 验证（补充）

- 单测：`MailSignatureTests`（精确签名对 id 集合稳定/顺序无关、家族签名归一化）、`MailMemoryStoreTests`（round-trip / 缺文件 / seen 判定）。
- 手动（需已连 Gmail + 配 Provider）：开 mail watcher → 后台轮询后重要新邮件进「动态」+通知 → 开 `/mail` 缓存摘要秒显、已看簇默认折叠 → 下次同一/同族邮件不再当新全量重看。
