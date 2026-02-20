## Houmao Mac 客户端（桌面 UI）

本目录存放基于 SwiftUI 开发的 Houmao Mac 客户端源码，用于：

- 提供一个主窗口：输入框 + LLM 回复区。
- 支持特殊命令 `history` 打开历史“使用情况”记录窗口。

### 结构概览（计划）

- `HoumaoApp.swift`：App 入口（`@main`），负责创建主窗口。
- `MainView.swift`：主窗口 UI（输入框 + 回复）。
- `MainViewModel.swift`：主窗口状态和 LLM 调用逻辑。
- `HistoryView.swift`：历史记录窗口 UI。
- `HistoryViewModel.swift`：历史记录加载与清空逻辑。
- `HistoryStore.swift`：本地历史“使用情况”读写封装。
- `LLMClient.swift`：LLM 调用接口与一个本地 mock 实现。

> 提示：你可以在 Xcode 中创建一个 macOS App 工程，并将这些 Swift 源文件添加到工程中进行编译运行。

### 如何在 Xcode 中运行（示例流程）

1. 打开 Xcode，选择 `File` → `Open...`，选中本仓库根目录或 `mac/` 目录。
2. 新建一个 macOS App 目标（如果还没有）：
   - `File` → `New` → `Project...` → 选择 `App`（macOS）。
   - 将生成的 `App` 入口替换为本目录中的 `HoumaoApp.swift`，或在现有目标中添加这些 Swift 文件。
3. 确认目标平台为 macOS 14+（或你的本机版本及以上），语言选择 `Swift`，Interface 选择 `SwiftUI`。
4. Build & Run（`Cmd + R`）：
   - 主窗口中可以：
     - 在输入框中输入任意文本并回车，看到 mock LLM 的回复。
     - 输入 `history` 并回车，弹出带有 “Clear All History” 按钮的历史记录视图（当前历史数据为本地文件，初始为空）。


