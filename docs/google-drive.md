# Google Drive 集成设计（google-drive.md）

> 状态：v1 草案（2026-07-15）· 单一事实来源：houmao 数据如何对接 Google Drive
> 关联代码（现状）：`Core/Auth/GoogleAuthProvider.swift`、`Core/Cloud/GoogleDriveClient.swift`、`DriveSyncService.swift`、`GoogleOAuth.swift`、`DoViewModel.swift`
> 关联文档：本地 todo 格式见 [todo.md](todo.md)

本文件确定：**OAuth Client 复用与一次合并授权、Drive 目录/文件模型、文件命名策略、文档格式、权限 UX**。其中 §8 记录相对已合入 Phase 4.1/4.2 的迁移（**授权部分保持现状**，目录 / 格式 / 命名 / 数据模型需迁移）。

---

## 1. 设计原则

1. **复用同一个 Google OAuth Client**：与 Gmail 同一个 Cloud 项目 / 同一个 Desktop-app Client（Client ID/Secret）/ 同一个共享 refresh token（Keychain `google.oauth.refresh`）。
2. **一次授权 + 最小够用的 scope**：首次连接**一次性同意** `gmail.modify` + `drive.file`（`drive.file` 已是最小 Drive 权限，仅本应用创建的文件）；打开浏览器同意前用中文说清要什么、做什么。**省事优先**，不走「用到某功能才追加该 scope」的增量流程。
3. **Drive 只用一个专属根目录 `houmao`**，固定两级深度：`houmao/<视图名>/<文件.txt>`。恰好一层子目录，子目录内只放文件（无更深嵌套）。
4. **文档内容为 Markdown，扩展名 `.txt`**（纯文本口径，跨端可读、不依赖 md 渲染）。

---

## 2. 复用 Gmail 的 Google Client（一次合并授权）

- 一个 Desktop-app OAuth Client + 一个共享 refresh token 覆盖全部 Google 功能（Gmail 清理、Drive 同步）。无需为每个功能单独建 Client 或单独存 token。
- **首次连接一次性同意所需的全部 scope**（`gmail.modify` + `drive.file`），Google 返回覆盖两者的 refresh token，写入同一 Keychain 账户；之后两功能都不再弹授权。
- 取舍：省事优先——不走「用到某功能才追加该 scope」的增量流程（那会在首次用 Drive 时多一次同意）。`drive.file` 本身已是最小 Drive 权限（仅本应用创建的文件）。

| 功能 | scope | 何时申请 |
| --- | --- | --- |
| Gmail 清理 | `gmail.modify` | 首次连接时，与 Drive 一起一次同意 |
| Drive 同步 | `drive.file`（仅本应用创建的文件，最小权限） | 同上 |

---

## 3. 一次合并授权流程

1. **首次连接**（设置里「连接 Google（Gmail + Drive）」，或首次 `/mail` / 首次启用 Drive 同步触发）：
   - 应用内先用中文说清将申请什么、做什么：「将请求 Gmail 整理（gmail.modify）与由本应用在 Drive 创建的文件（drive.file）；不会读取你 Drive 上的其它文件。」
   - 打开浏览器**一次同意**，`scopes = [gmailModify, driveFile]`。
   - 结果：refresh token 覆盖两者，写回共享 Keychain 账户。
2. **之后**：Gmail 与 Drive 均直接用同一 token，不再弹授权。
3. 代码现状即此设计（`Scope.appDefault = [gmailModify, driveFile]`），授权部分**无需改动**。

> 效果：一次同意搞定，最省事；同意屏一次列出两项权限即为显式告知。

---

## 4. Drive 目录与文件模型

```
houmao/                      ← 专属根目录（find-or-create；drive.file 只见自建）
  待办/                      ← 子目录 = Do 视图
    工作.txt                 ← 活动待办：工作 tab（仅未完成项）
    生活.txt                 ← 活动待办：生活 tab
    工作·2026-07·归档.txt    ← 归档：某 tab 某月已完成项（含开始/结束时间）
    生活·2026-07·归档.txt
  聊天/                      ← （后续 4.3）聊天收藏
    <AI 摘要中文名>.txt
  …
```

- **根**：`houmao`，find-or-create。
- **一层子目录**：`houmao/<视图名>`，一个 houmao view 页面对应一个子目录，中文同名。
- **文件**：只出现在子目录内，不再嵌套目录。
- **同步单元 = `(子目录, 文件名)` 固定二元组**；内容更新 = 覆盖该文件（Drive `files.update` media，一次性覆盖，不追加、不下行、不合并）。

### 视图 → 子目录名 映射（初版）

| houmao 视图 | Drive 子目录 | 说明 |
| --- | --- | --- |
| 待办（Do） | `待办` | 本期落地 |
| 聊天收藏 | `聊天` | 后续 4.3（气泡右键保存） |
| （其它视图） | 视图中文名 | 用到再加 |

---

## 5. 文件与命名策略

命名分两类：**结构化数据（待办）用固定结构名**；**内容派生文档（聊天收藏 / 笔记）用 AI 摘要名**。

### 5.1 待办（Do）：按 tab 分活动文档 + 按月归档

- **活动文档，一个 tab 一个**：`工作.txt` / `生活.txt`，只放**未完成**项；持续演进、每次变更覆盖同步。
- **归档文档，按月滚动**：一个待办被标记完成即从活动文档移出，写入其**完成月份**的归档文档；归档条目按**归档格式记录开始与结束时间**。
  - 命名：`<tab>·<yyyy-MM>·归档.txt`（如 `工作·2026-07·归档.txt`）。
  - 归档格式（每条一行）：`- 写周报 · 起 2026-07-02 · 止 2026-07-05`。
  - 当月归档文档只追加当月完成项；月份结束后基本不再变动。
- **不使用** AI 摘要名，也**不受 10–20 汉字约束**——待办是固定语义桶，结构名更稳定、可预期、不随内容漂移。
- **数据模型影响**：`DoItem` 需增加 `createdAt`（起）与 `completedAt`（止）；本地 [todo.md](todo.md) 格式与 Do 面板需同步支持「完成即归档、按月分文档」，本地与 Drive 保持一致（Drive 镜像本地）。

### 5.2 聊天收藏 / 笔记（内容派生、一次成形）

- **AI 摘要中文文件名**，**不少于 10、不多于 20 个汉字**，一旦确定**不再修改**（immutable）。统一中文，扩展名 `.txt`。
- 规范化：剔除非法字符（`/`、换行、控制字符）；长度钳制到 `[10, 20]` 汉字（不足由 AI 补足或加固定后缀，超出截断）。

---

## 6. 文档格式

- **内容 = Markdown**（如待办用任务清单 `- [ ]` / `- [x]`，见 [todo.md](todo.md)）。
- **扩展名 = `.txt`**，MIME = `text/plain`。纯文本口径，任意编辑器/预览可读，不触发 Markdown 渲染。

---

## 7. 权限 UX 与 Keychain（评估 + 建议）

**权限透明性由首次那一次 OAuth 同意屏承担**：同意屏一次列出 Gmail 与 Drive 两个 scope；应用内在打开浏览器前先中文说清要什么、做什么。

**关于「使用时弹 macOS Keychain 密码框」——建议不作为常规权限门**：

- 现状：应用读取自己写入的 Keychain 项**默认不弹密码**。要每次弹，需给该项加 user-presence ACL（Touch ID / 密码）。
- 代价：access token 约 1 小时过期，自动同步频繁 → 每次刷新 / 上传都要读 refresh token → **会频繁弹密码**，严重打断自动同步体验。
- 建议：
  1. 权限门交给那一次 OAuth 同意；
  2. Keychain 令牌保护用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（不 iCloud 同步、仅设备解锁后可读，**无重复弹窗**）；
  3. 若确需二次确认，**仅在「首次连接」**加一次 user-presence，**不**在每次 token 刷新加。
- **已定（你确认）**：仅 OAuth 同意作为权限门；Keychain 用 `WhenUnlockedThisDeviceOnly`，token 刷新**不**弹密码框。

---

## 8. 现状与迁移（相对已合入的 Phase 4.1/4.2）

当前实现（本对话上一步提交 `dea9f79`）与本设计有冲突，需迁移：

| 项 | 现状 | 迁移到 |
| --- | --- | --- |
| scope | `Scope.appDefault = [gmailModify, driveFile]` 首连一次合并同意 | **保持现状**（一次合并，无需回退） |
| 授权 URL | `access_type=offline` + `prompt=consent` | **无需改动**（一次合并不需要 `include_granted_scopes`） |
| Drive 目录 | `houmao/do/{work.md, life.md}` | `houmao/待办/{工作,生活}.txt` + `<tab>·<月>·归档.txt`（一层子目录 = 视图名） |
| 文件格式 | `.md` / `text/markdown` | `.txt` / `text/plain`（内容仍 md） |
| 文件名 | 固定 `work` / `life` | 待办：`工作.txt`/`生活.txt` 活动 + `<tab>·<月>·归档.txt`；内容派生文档用 AI 摘要名（§5） |
| 数据模型 | `DoItem` 无时间戳、完成项原地保留 | `DoItem` 加 `createdAt`/`completedAt`；完成即移入按月归档 |
| Keychain | `WhenUnlocked`（默认，不弹） | 明确用 `WhenUnlockedThisDeviceOnly`；不加每次弹窗 |

---

## 9. 待澄清

1. **授权方式**：✅ 已定 **一次合并同意**（首连一次拿 Gmail + Drive）——代码 scope 保持现状（`Scope.appDefault`），授权部分无需改动。
2. **归档粒度**：✅ 已定 **每 tab 每月一个归档文档**（`工作·2026-07·归档.txt`、`生活·2026-07·归档.txt`）。
3. **其它视图的中文子目录名**：待办=`待办`、聊天收藏=`聊天`，其余用到再定。
