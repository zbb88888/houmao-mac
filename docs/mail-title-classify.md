# 邮件标题分类策略（mail-title-classify）

> 单一事实来源：本文件描述 `/mail` 邮件列表的**标题分类与聚合**策略。实现见
> [`Core/Mail/MailGrouping.swift`](../mac/houmao/houmao/Core/Mail/MailGrouping.swift)，
> 回归由 [`MailGroupingTests.swift`](../mac/houmao/houmao/houmaoTests/MailGroupingTests.swift) 守护。
> 架构进度见 [product-architecture-roadmap.md](product-architecture-roadmap.md)。

## 目标

一堆未读邮件逐封打开会浪费大量时间。分类的目的：**仅凭标题**把邮件快速归入有意义的
类别（大类 › 小类），相似标题再自动聚合，从而一眼扫完、批量处理，避免逐封阅读。

原则：**有括号就意味着有标签，有标签就按标签分**；分类名必须是「类别」而非某一封邮件
的完整标题。

## 分类维度：括号即标签，按括号类型定级

标题里不同类型的括号定义分类层级，优先级固定：

| 级别 | 括号 | 示例内容 |
|------|------|----------|
| 1 级（大类） | `()` 圆括号 | `(PR #46257)` → `PR` |
| 2 级（小类） | `[]` 方括号 | `[cilium/cilium]` → `cilium/cilium` |
| 3 级及以后 | 其他括号 `{}`、`<>`、`【】`、`（）` | 依此固定顺序继续往后排 |

规则：

1. **有括号就有标签**：取该级括号的单层内容作为标签。匹配方向按 GitHub 通知习惯：
   - `()` 圆括号**从右到左（逆序）取最后一个**——GitHub 的 `(PR #46257)` / `(Issue #9)`
     标签位于标题最右侧；
   - `[]` 方括号及其他括号**从左到右（正序）取第一个**。
2. **缺失的括号不占位**：只有 `[]` 没有 `()` 时，`[]` 直接升为 1 级（「只有一个括号就
   只按那个括号分」）。同理只有 `{}` 时 `{}` 为 1 级。
3. **无任何括号 → 按 Gmail 原生分类作大类**（促销 / 社交 / 更新通知 / 论坛 / 个人 / 主要），
   而不是笼统「未分类」——让没有括号的营销、社交、通知邮件也能自动分开。
4. **标签归一化**：去掉 `#123` 这类编号引用、去首尾空白、小写，避免 `(PR #46257)` 与
   `(PR #5)` 因编号不同而各成一类。归一化后为空（如 `(#123)`）视为无该级标签。

### 语义大类：PR / issue

GitHub 通知邮件的 `()` 内通常是 `PR #num` / `Issue #num`，归一化后自然得到 `pr` / `issue`，
再规范化为展示名 **`PR`** / **`issue`**（`canonicalPrimary`）。

作为补充，当**完全没有括号**但标题中出现 PR/issue 关键词时，仍按关键词归入大类：

- 命中 `pull request`（不区分大小写）或独立的 `PR`（区分大小写，避免误伤 `PRICE` 等）→ `PR`
- 命中独立的 `issue`/`issues`（不区分大小写）→ `issue`
- 两者同现时 `PR` 优先

### Gmail 原生分类（无括号邮件的大类）

Gmail 会给每封邮件打一组 `labelIds`（如 `CATEGORY_PROMOTIONS`、`CATEGORY_SOCIAL`…）。
对**没有任何括号**、也没有 PR/issue 关键词的邮件，用 `MailCategory.from(labelIds:)` 映射出
的语义分类（促销/社交/更新通知/论坛/个人/主要）作为大类。这样即便标题没有括号标签，
收件箱也能按 Gmail 已有的分类拆开，而不是全部堆进一个大桶。

> 注意：分类只作为**大类分组维度**，不会把分类文本混进标题的近邻相似度计算——那会让
> 同类但主题不同的邮件被错误拉近。

### 自定义标签（用户显式）

用户可在设置里配置 `名称: 关键词` 规则。命中（主题包含关键词）的邮件**独占**为该名称的
大类，不再按括号继续细分——因为这是用户「我要把这类单独拎出来」的显式意图。优先级最高。

## 大类的展示与排序

- UI 为**两级**：一级大类作为分区标题（含全选框、色点、计数），二级小类作为缩进子标题。
- 3 级及以后的标签，附加在二级标签后，用 `›` 连接展示（如 `beta › gamma`），不再额外嵌套，
  保持界面简洁。
- 大类排序：**自定义标签（规则顺序）→ PR → issue → 其他括号标签（首次出现顺序）→ Gmail 分类（`MailCategory.allCases` 固定顺序）**。

## 聚合：仅按标题近邻

在同一个 (大类, 小类) 桶内，对**标题**做近邻聚合，把相似标题收成一簇（一行），
减少视觉噪音。

- 算法：字符 n-gram TF-IDF 向量 + 余弦相似度 + Union-Find（见
  [`Core/Clustering/TextClustering.swift`](../mac/houmao/houmao/Core/Clustering/TextClustering.swift)，ADR-9）。
- **只计算标题（subject），不使用邮件正文**——分组阶段只有 `messages.get?format=metadata`
  的元数据，不拉正文，快且省。

## 处理管线（逐级细分）

```
每封邮件 subject + labelIds
  └─ 计算标签路径（自定义标签独占 | 括号路径 | PR/issue 关键词）
      └─ 无任何标签 → 用 Gmail 分类（labelIds）作大类
          └─ 按大类分桶（优先级排序）
              └─ 桶内按小类（含 3 级+ 复合）分子桶（首次出现顺序，无小类置末）
                  └─ 子桶内按标题近邻聚合成簇
```

## 示例

| 标题 | 大类 | 小类 |
|------|------|------|
| `Re: [cilium/cilium] fix leak (PR #46257)` | `PR` | `cilium/cilium` |
| `[owner/repo] Crash (Issue #9)` | `issue` | `owner/repo` |
| `(v2.0) [core] release cut` | `v2.0` | `core` |
| `(alpha) [beta] {gamma} hi` | `alpha` | `beta › gamma` |
| `[GitHub] Alpha release notes` | `github` | （无） |
| `Your pull request was merged` | `PR` | （无） |
| `Big summer sale ends soon`（`CATEGORY_PROMOTIONS`，无括号） | `促销` | （无） |

## 关键实现入口

| 符号 | 作用 |
|------|------|
| `MailGrouping.tags(for:customTags:)` | 计算一封邮件的 `(primary, secondary)` 两级标签 |
| `MailGrouping.bracketPath(_:)` | 按括号优先级返回存在的各级标签内容 |
| `MailGrouping.canonicalPrimary(_:)` | 把 `pr`/`pull request`/`issue` 规范为 `PR`/`issue` |
| `MailGrouping.builtinTag(_:)` | 无括号时按标题关键词识别 PR/issue |
| `MailCategory.from(labelIds:)` | 无任何标签时，把 Gmail `labelIds` 映射为大类 |
| `MailGrouping.group(_:customTags:config:)` | 分桶 + 逐级细分 + 标题近邻聚合 |

## 设计取舍

- **只用标题不用正文**：分组要快且不额外拉取正文；深度理解（摘要 / PR / issue 分析）由
  选中单封后的「AI 分析」按钮触发（见 `MailViewModel.analyzeSelected`），与分类解耦。
- **括号类型而非位置定级**：`(Issue #9)` 即使出现在 `[owner/repo]` 之后，`()` 仍是 1 级。
- **3 级+ 不额外嵌套**：真实邮件极少超过两级，深层用 `›` 复合展示，避免过度工程。
