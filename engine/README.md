# houmao-engine

houmao 的无头 LLM/agent 引擎（Rust）。UI 与引擎解耦的引擎侧——见 [`docs/engine-decoupling.md`](../docs/engine-decoupling.md)。

## 现状

已实现：

- 协议线类型（`src/protocol.rs`）：`hello` / `request(Command)` / `response` / `event`，内部标签 CBOR，便于 Swift `Codable` 对接。含 `configure`/`attach`/`tool_result` 命令与 `tool_invocation` 事件。
- 帧读写（`src/framing.rs`）：`[u32-be 长度][CBOR]`，16 MiB 上限。
- Unix socket server（`src/server.rs` + `src/main.rs`）：hello 握手 + 命令分发。
- provider 调用（`src/ai.rs`）：非流式 tool-calling `complete`（阻塞 ureq，`<think>` 剥离）。
- **agent 多步 tool-calling 循环**：每轮 worker 线程跑（最多 8 步）；engine 侧工具 `get_time`（`src/tools.rs`）；UI 侧工具经 `tool_invocation`/`tool_result` 回调。连接线程把 `tool_result`/`abort` 经 mpsc 路由给 worker（避免死锁）。

**未做**：会话持久化、`set_model` 切换、真 token 流式（现分片伪流式）、更多工具（ghia/gh/Gmail）。

## 配置（provider 经协议 `configure` 下发，不读环境变量）

Swift 侧握手后经 `configure { base_url, model, api_key }` 下发（从 `AppSettings.resolveModel` 取）。引擎只在内存持有、不落盘不日志。独立运行时用 socket 客户端自行 `configure`。

## 构建 / 测试 / 运行

```bash
cd engine
cargo test                     # 9 单测 + 3 端到端集成测试（mock provider：plain / engine 工具 / UI 工具往返）
cargo build --release          # 产物：target/release/houmao-engine（已开体积优化）
./target/release/houmao-engine # 默认监听 $TMPDIR/houmao-engine.sock
./target/release/houmao-engine /tmp/houmao.sock   # 或指定路径
```

## 设计要点

- 不引 async runtime（无 tokio），std 阻塞 socket + 线程/连接，二进制体积优先（`opt-level="z"` + LTO + strip + panic=abort）。
- 会话 snapshot 是权威态；progress 事件是瞬态 UI 提示，丢失可靠重连拉 snapshot 恢复。
- 传输鉴权靠 socket 文件权限（0600）。

参考实现：`pi`（`~/f/pi`），其 `protocol` / `server` / `client` / `agent` / `ai` 包边界即目标形态。
