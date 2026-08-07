# AI 原生 Agent 工具层 — 设计文档

> 本文件记录猴毛「AI 原生 tool-calling agent」的工具层设计，以及**邮件方向工具**的能力与摘要缓存 key 设计，方便后续参考与扩展。
>
> 关联文档：底层邮件摘要/去噪/缓存内部机制见 [proactive-agency.md §8](proactive-agency.md#8-邮件三句话摘要v3)；总架构见 [product-architecture-roadmap.md](product-architecture-roadmap.md)。

---

## 0. 背景与定位（一次有意的架构反转）

猴毛早期的第一架构原则（赫尔佐格 / ADR-1 / ADR-13 / ADR-14）是「不做 tool-calling 大脑，LLM 仅作文本层」。本工具层是对该方向的**有意反转**：让模型自己决定调用哪些工具、并把多个工具串起来完成一个更高层意图。

落地策略 = **混合、可回退**：

- 新增一个独立 **`/ai` 窗口**承载 tool-calling agent；
- 现有确定性面板（`/mail` `/pr` `/do` …）**全部保留**不动；
- 能力逐个包成工具，随时可停可退。

**底线不放弃（ADR-8）**：**变更类工具（删邮件、写文件…）绝不自主执行**——`AgentLoop` 遇到变更类工具会暂停、等人工确认后才执行。AI 原生 ≠ 放任模型改数据。

---

## 1. 分层与文件

纯 Foundation、可单测的原语放 `Core/Tools/`；窗口外壳放根目录（Shell）。

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Core | [JSONValue.swift](../mac/houmao/houmao/Core/Tools/JSONValue.swift) | 递归 JSON 值（工具参数 schema + 模型回传 args），Codable |
| Core | [AgentTool.swift](../mac/houmao/houmao/Core/Tools/AgentTool.swift) | `AgentTool` 协议 + `ToolCall` + `AssistantTurn` |
| Core | [ToolRegistry.swift](../mac/houmao/houmao/Core/Tools/ToolRegistry.swift) | 工具注册表；`specs()` 产 OpenAI 风格 `tools` 数组 |
| Core | [AgentLoop.swift](../mac/houmao/houmao/Core/Tools/AgentLoop.swift) | 工具使用循环 + 变更类确认中断（`AgentMessage`/`AgentActivity`/`AgentOutcome`） |
| Core | [AgentModelClient.swift](../mac/houmao/houmao/Core/Tools/AgentModelClient.swift) | tool-calling 的 OpenAI wire 层（`requestBody`/`parseTurn`/`complete`/`modelCall`） |
| Shell | [AgentChatViewModel.swift](../mac/houmao/houmao/AgentChatViewModel.swift) | 驱动 `AgentLoop`，管理对话/工具活动/确认状态 |
| Shell | [AgentChatView.swift](../mac/houmao/houmao/AgentChatView.swift) | `/ai` 对话 UI + 变更类确认条 |

> 目录取名 `Core/Tools/` 而非 `Core/Agent/`——后者已被「主观能动性」被动收件箱子系统（`AgentEvent`/`Watcher`/`AgentDaemon`）占用，两者概念不同（那个是被动感知/通知，这个是主动工具使用）。

**刻意不改 `AiTxtClient`**：tool-calling 的线格式（`arguments` 编成 JSON 字符串、`tool` 角色带 `tool_call_id`、`content` 可为 null）与既有聊天 client 差异大，单独放 `AgentModelClient`，现有 chat/mail/pipeline 路径零风险。

---

## 2. AgentLoop：循环与确认机制

```mermaid
flowchart TD
    U[用户意图] --> L{AgentLoop.run}
    L -->|transcript + tools schema| C[AgentModelClient.complete]
    C -->|无 tool_calls| A[终答 finished → 渲染]
    C -->|有 tool_calls| D{工具 isMutating?}
    D -->|只读| E[ToolRegistry 执行 → 结果回喂 transcript]
    D -->|变更类| P[awaitingConfirmation 暂停]
    P -->|用户点「批准执行」| R[AgentLoop.resume 执行]
    E --> L
    R --> L
```

- **单步 vs 多步**：单工具只是循环跑一圈的退化情形；多步串联（如 `list → read → 分析`）由同一循环自然得到，不设「只准一个工具」的天花板。
- **护栏**：`maxSteps`（默认 8）防止模型无限循环；`AgentOutcome.maxStepsReached` 兜底。
- **确认链路**：变更类工具 → `run` 返回 `.awaitingConfirmation(call, transcript)` → UI 显示确认条 → 用户批准 → `resume(afterApproving:)` 执行该工具并续跑；拒绝 → 回喂一条「user declined」让模型收尾。

---

## 3. 工具契约（新增工具照此写）

`AgentTool` 协议：

| 成员 | 说明 |
| --- | --- |
| `name` | 暴露给模型的函数名，snake_case、稳定 |
| `description` | 一句话，模型据此决定何时调用 |
| `parametersSchema` | JSON Schema（`.object`），描述参数 |
| `isMutating` | 是否修改用户数据；变更类**绝不自动执行**（默认 `false`） |
| `invoke(arguments:)` | 用解码后的参数执行，返回喂回模型的**文本**结果 |

约定：

1. **tool = 现有 view 的确定性取数 + 动作**——复用既有 `Provider`（`GmailProvider` / `PullRequestProvider` / `GitHubCLI` …），只是把「人点按钮」换成「模型决定调用」。
2. **确定性逻辑该封装进工具**（去噪、聚类、取数、格式化）；**依赖用户意图、且外层 agent 自己能做的智力工作，不要塞进工具**（见 §5 的嵌套 LLM 取舍）。
3. 依赖注入 `Provider`（协议）→ 工具**可 mock、可单测**。
4. 新增工具流程：① `Core/Tools/XxxTool.swift` 实现协议；② 在 [AgentChatViewModel](../mac/houmao/houmao/AgentChatViewModel.swift) 的 `registry` 注册；③ 变更类设 `isMutating=true`；④ 加单测（注入假 Provider）；⑤ 新文件需 `xcodegen generate`。

---

## 4. 邮件方向工具能力

首批邮件工具（均复用 `GmailProvider`，token 走现成的 `GoogleAccount.accessToken()`）：

| 工具 | 类型 | 参数 | 复用 | 作用 |
| --- | --- | --- | --- | --- |
| `list_recent_mail` | 只读 | `query`(默认 `is:unread`)、`limit`(默认 20，上限 50) | `listMessages`+`fetchMetadata` | 列最近邮件：id / 发件人 / 主题 / snippet |
| `read_mail` | 只读 | `id`(必填) | `fetchFull` | 读某封全文（供深入分析） |
| `triage_inbox` | 只读 | `query`(默认 `is:unread in:inbox newer_than:30d`)、`limit`(默认 100，上限 200) | `MailGrouping`+`MailImportance`+`MailWatcher.summarize`（带缓存，见 §5） | 挑重点：去噪 + 聚类 + 逐重点簇三句话摘要 |
| `trash_mail` | **变更类** | `ids`(数组) | `trashMessages` | 移到废纸篓（可恢复）；**需人工确认** |

对应实现：[ListRecentMailTool](../mac/houmao/houmao/Core/Tools/ListRecentMailTool.swift)、[ReadMailTool](../mac/houmao/houmao/Core/Tools/ReadMailTool.swift)、[TriageInboxTool](../mac/houmao/houmao/Core/Tools/TriageInboxTool.swift)、[TrashMailTool](../mac/houmao/houmao/Core/Tools/TrashMailTool.swift)。单测：[MailToolsTests](../mac/houmao/houmaoTests/MailToolsTests.swift)。

### 典型 agent 用法（多步）

- **「今天有哪些重要邮件，先处理哪些？」** → `triage_inbox` 拿到去噪后的重点簇 + 摘要 → agent 在其上**排序**（先看哪些、后看哪些）。
- **「XX 那封讲了什么？」** → `list_recent_mail` 找到 id → `read_mail` 读全文 → agent 分析。
- **「把这些促销邮件删了」** → agent 提出 `trash_mail(ids)` → **暂停等用户点「批准执行」** → 执行。

`AgentChatViewModel` 的 `systemPrompt` 引导模型：想快速了解重点用 `triage_inbox`；看具体某封先 `list_recent_mail` 再 `read_mail`；删邮件用 `trash_mail`（会先请用户确认）；需要数据时调工具、不臆造。

---

## 5. 邮件摘要 key 与缓存设计（核心）

`triage_inbox` 的逐重点簇三句话摘要复用 `MailWatcher.summarize`——这意味着**在工具内部再嵌套一次 LLM 调用（每个重点簇一次）**。为让这层可接受，加了**幂等缓存**。

### 5.1 复用现成缓存，不另建 tmp

摘要缓存**直接复用现有的 `MailMemoryStore`**（[Core/Mail/MailMemoryStore.swift](../mac/houmao/houmao/Core/Mail/MailMemoryStore.swift)），**不新建 tmp 目录缓存**：

- 现有 `MailMemoryStore` 落盘 `~/Documents/houmao/mail/memory.json`，且被 **watcher + `/mail` + 本工具三者共享**——同一份缓存，永不重复付费、不漂移。
- 另起 tmp 缓存会：被系统定期清理（更易失效）、与另两条路径**各存一份 → 三份漂移**。

### 5.2 缓存 key = 簇签名（排序 message-id 的 SHA256）

key 用现成的 `MailSignature.cluster(cluster)` = 簇内 Gmail **message-id 排序后 join → SHA256 hex**。

这个 key **优于**「title hash + 最近邮件时间」：

| 方案 | 加/删邮件失效？ | 检测得到删除？ | 同标题不同线程碰撞？ |
| --- | --- | --- | --- |
| **排序 message-id 哈希（采用）** | ✅ 集合一变即变 | ✅ | ❌ 不碰撞 |
| title hash + 最近时间 | 部分 | ❌ 删除检测不到 | ✅ 会碰撞 |

即：**簇内只要没有新增/删除邮件，key 不变 → 命中缓存**；一旦有变化 → key 变 → 重新摘要。这正是「无新邮件只付一次」的幂等性。

### 5.3 只对 cache miss 花预算

`triage_inbox.invoke` 内：`load()` 一次 → 逐重点簇按 `sig` 查 `state.summaries`：

- **命中** → 直接用，**免费、无上限**；
- **未命中** 且 `generated < summaryBudget`(8) → 调一次 `summarize`，写回缓存、计入预算。

`summaryBudget=8` 只约束**新摘要**（对齐 watcher 的预算语义），防止一次调用对超大收件箱无界 fan-out。**无新邮件 → `generated==0` → 零 LLM 开销**（单测 `triageCachesSummariesAcrossCalls` 证明第二次调用摘要器只跑一次）。

### 5.4 两层职责分离

- **工具层（`triage_inbox`）**：确定性去噪 + 聚类 + **带缓存**的逐簇摘要 → 产出「重点 digest」。
- **agent 层**：在 digest 之上做**依赖意图**的判断——先看哪些、后看哪些、是否需要 `read_mail` 深入、是否建议 `trash_mail`。

### 5.5 嵌套 LLM 的取舍（一般原则）

工具内部再调 LLM（compound tool / sub-agent）**并非天然反模式**，判据：

- **适合**：map-reduce 压缩超长语料（外层上下文塞不下）、异构能力子代理（代码执行 / OCR 视觉 / 检索重排）、与外层对话意图无关的自包含子任务。
- **不适合的信号**：内外层同一模型做重叠智力工作、数据本就很小（无压缩收益）、把摘要格式/意图**写死**、工具因此变非确定性。

`triage_inbox` 的**确定性部分（去噪 + 聚类）该留**——那是 agent 自己做不到、值得封装的价值；**逐簇摘要属于弱点**（数据小、写死了「背景/目的/处理」格式），靠 §5.1–5.3 的**幂等缓存**把成本摊薄成「每簇仅在有新邮件时付一次」来抵消。若日后要更贴合用户意图，可把摘要拆成独立的、agent 可自主选择调用的 `summarize_mail_cluster` 工具。

---

## 6. 现状与后续

**已落地工具**：`list_pull_requests`（GitHub）、`list_recent_mail`、`read_mail`、`triage_inbox`、`trash_mail`。

**UI**：失败（出错 / 达最大步数 / 空回复）时 header 显示「重试」按钮，重放上次请求、不用重打字；变更类工具确认条显示 `工具名 + 参数 JSON`，批准前能看清将要操作什么。

**已定不做（避免过度工程）**：

- **终答流式**：会反转刻意的非流式健壮性选择，且流式 `tool_calls` 分片累积 + `<think>` 过滤复杂易碎（本地模型格式不一）；而 `AgentLoop` 已把每步「调用工具 / 工具结果」逐步流式反馈 + 输入栏有转圈指示器。改为上面的**手动重试**。
- **摘要缓存淘汰**：每簇摘要约 150 字节、增长极慢（万簇 ≈ 1.5MB），多年都非问题；正确的 LRU 需改 `State` schema 记录访问时间、或随机丢弃、或让工具耦合当前 sig 集——为不会发生的增长加这些属过度工程。

**未做 / 待办**：

- 按 §7 的统一协议把 `/pr`、`/issue` 的 ghia 深度分析包成工具（让 agent 串「列 PR → 深度分析某个」）；
- 补一条 ADR 正式记录本次方向反转（ADR-1/13/14）；
- `/ai` 窗口 GUI 无法无头验证，真机联调需配好 provider（支持 function calling）+ 已连 Gmail / `gh auth`。

---

## 7. 基于文件交互的工具协议（后续开发规范）

> **本节是后续所有 agent 工具的交互标准。**
>
> 演进记录：2026-08-06 曾拍板「全部工具都走结果文档（B）」；2026-08-07 讨论后**收敛为下面这条更精确的原则**——文件中介只用于「跨进程/长任务/大产物」的 LLM 子代理，同进程确定性工具直接内联。理由见 §7.1。

### 7.1 何时走文档、何时内联（核心判据）

决定要不要经由结果文档的，**不是「产出型 vs 查询型」，而是这次调用是否跨了一个「大产物的异步/进程边界」**。三个真正的触发条件：

1. **长时 / 异步**（不该阻塞或逐字流过父 loop）；
2. **产物大**（不适合直接塞进工具返回通道）；
3. **值得留存**（可复用、可回看）。

三条同时满足才走文档；否则内联。常见形态＝**该工具委托给一个独立进程的 LLM 子代理**（LLM↔LLM 跨进程），此时**共享文件系统就是天然的 IPC 媒介**。同进程内部无论是否调用模型，都在内存里传字符串即可，套文件纯属多余开销。

| 情形 | 传递方式 | 例 |
| --- | --- | --- |
| 同进程、确定性、结果小 | **内存内联**（`invoke` 返回文本） | `list_pull_requests` / `list_recent_mail` / `read_mail` / `trash_mail` |
| 同进程调模型但产物小 | **内存内联** | `triage_inbox`（内部 `MailWatcher.summarize` 是同进程 HTTP 调用，digest 小） |
| **跨进程 LLM 子代理、产物大、值得留存** | **结果文档 + 异步 Job** | `analyze_pr` / `analyze_issue`（spawn `ghia` 进程，多阶段 LLM，1200s，大报告） |

### 7.2 三个真实收益（诚实记录，别夸大）

对 ghia 这类场景，文件中介的收益是：

1. **IPC**：跨进程传大产物，落文件比把长时 stdout 全缓冲回来干净。
2. **异步解耦**：长任务发出去 → 落盘 → 完成再 resume，不阻塞、不逐字流过父 loop。
3. **持久化 / 可复用**：报告留档，符合猴毛「文档落地是目的」。

**不是**「省上下文」——`read_document` 读回来时整份报告照样进上下文。别用这个理由。

### 7.3 结果文档存储约定

- 路径：`~/Documents/houmao/agent/results/<kind>/<id>.md`（`AgentResults.documentURL`）。
  - `kind`：pr / issue / …
  - `id`：由输入**确定性**派生（pr/issue=`<owner>-<repo>-<number>`）→ 同输入同文件，天然幂等 / 可覆盖。
- 内容：Markdown。与既有 `~/Documents/houmao/<view>/` 同源。

### 7.4 异步 Job 机制（完成信号 + 自动续跑）

跨进程产出工具实现 `AgentTool.dispatch(arguments) -> AgentJob?`（同进程内联工具返回 `nil`，走 `invoke`）：

- `dispatch`：从参数派生 `AgentJob{id,kind,title,documentPath,status}`，起一个**后台 `Task`**（`JobStore.start` → 跑活 → `AgentResults.write` 写文档 → `JobStore.finish`），立即返回 job。
- `AgentLoop` **复用 pause/resume 机制**：命中 dispatch 工具即返回 **`.awaitingJob(jobID, transcript)`**（与 `.awaitingConfirmation` 同构），暂停但保持运行态。
- `JobStore`（`@MainActor @Observable`）是**「是否结束」单一来源**；`finish` 发 `.houmaoAgentJobFinished`（userInfo `jobID`）。
- agent VM 持久订阅该事件：到达时注入 `.user(「结果文档已就绪：<path>，请 read_document 读取并分析」)` 并 **resume** loop → 模型调 `read_document` → 二次分析 → 终答。（VM 收到 `.awaitingJob` 时若 job 已终态则立即 resume，防快任务竞态。）

### 7.5 `read_document` 原语（文档→模型的桥）

必须有一个把文档内容送进模型上下文的内联原语，否则文档内容永远进不了模型。`read_document(path)` 内联返回文档全文（沙箱限 `~/Documents/houmao`）。写/改由 `write_document` 等原语承担。这些 I/O 原语本身不走「产出文档」规则。

### 7.6 护栏：大文本入文件、不入内存缓存

大段 LLM 产物（如 ghia 报告）应落**文件**，不要堆进内存/缓存。现有 `MailMemoryStore` 缓存的是三句话摘要（每条 ~150B，小，尚可）；**不得**拿它或类似内存缓存去存大段正文——那是文件的活。

### 7.7 现状（已实现，即符合本原则）

- **走文档**：`analyze_pr` / `analyze_issue`（ghia 子进程 → `~/Documents/houmao/agent/results/pr|issue/<slug>.md`）。
- **内联**：`list_pull_requests` / `list_recent_mail` / `read_mail` / `triage_inbox` / `trash_mail`（`trash_mail` 变更类，走 `.awaitingConfirmation` 确认，与 Job 协议互斥、天然不走文档）。
- 机制：`AgentJob` / `AgentResults` / `JobStore` / `AgentTool.dispatch` / `AgentLoop.awaitingJob` / `ReadDocumentTool` 均已落地并单测。
