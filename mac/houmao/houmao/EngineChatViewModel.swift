import AppKit
import Foundation
import Observation

/// 引擎聊天的瘦客户端：连引擎（必要时 spawn）、握手、建会话、发 prompt、
/// 订阅 progress 增量渲染。**不含任何 LLM 逻辑**——只发命令、渲染引擎回传的态。
@MainActor
@Observable
final class EngineChatViewModel {
    enum Role { case user, assistant, system }
    struct Line: Identifiable {
        let id: String
        let role: Role
        var text: String
    }

    private(set) var lines: [Line] = []
    var input = ""
    private(set) var status = "未连接"
    private(set) var isConnected = false
    private(set) var isBusy = false

    private var transport = EngineTransport()
    private var engineProcess: Process?
    private var sessionID: String?
    private var streamingLineID: String?
    private var reqCounter = 0
    private var connecting = false
    private var reconnecting = false
    private var attachReqID: String?

    private var socketPath: String { NSTemporaryDirectory() + "houmao-engine.sock" }

    func onAppear() {
        guard !isConnected, !connecting else { return }
        establish()
    }

    // MARK: 连接

    /// （重）建传输：新建 transport、接回调、试连（必要时 spawn+重试）、握手。
    private func establish() {
        connecting = true
        if !isConnected { status = reconnecting ? "重连中…" : "连接引擎…" }
        transport = EngineTransport()
        transport.onFrame = { [weak self] data in Task { @MainActor in self?.receive(data) } }
        transport.onClose = { [weak self] in Task { @MainActor in self?.handleClose() } }
        if tryConnectNow() { return }
        _ = spawnEngine() // 未运行则尽力自启，再重试连接
        scheduleRetry(remaining: 10)
    }

    private func tryConnectNow() -> Bool {
        do {
            try transport.connect(path: socketPath)
            isConnected = true
            connecting = false
            reconnecting = false
            status = "握手中…"
            transport.send(EngineClientMessage.hello(version: engineProtocolVersion, uiTools: Self.uiToolSpecs).framed)
            return true
        } catch {
            return false
        }
    }

    private func scheduleRetry(remaining: Int) {
        guard remaining > 0 else {
            connecting = false
            reconnecting = false
            status = "无法连接引擎（确认已 make install 打包引擎，或设 HOUMAO_ENGINE_BIN）"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isConnected else { return }
            if !self.tryConnectNow() { self.scheduleRetry(remaining: remaining - 1) }
        }
    }

    @discardableResult
    private func spawnEngine() -> Bool {
        guard let binary = resolveEngineBinary() else { return false }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [socketPath]
        do {
            try proc.run()
            engineProcess = proc
            return true
        } catch {
            return false
        }
    }

    private func resolveEngineBinary() -> URL? {
        if let p = ProcessInfo.processInfo.environment["HOUMAO_ENGINE_BIN"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return Bundle.main.url(forResource: "houmao-engine", withExtension: nil)
    }

    /// 经协议下发 provider 配置（密钥仅传本地 socket，引擎不落盘）。
    private func sendConfigure() {
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            status = "未配置 provider：请在设置（⌘,）里添加"
            return
        }
        transport.send(EngineClientMessage.request(
            id: nextReqID(),
            command: .configure(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey)
        ).framed)
    }

    // MARK: 发送

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sid = sessionID, !isBusy else { return }
        appendLine(role: .user, text: text)
        input = ""
        isBusy = true
        streamingLineID = nil
        status = "生成中…"
        transport.send(EngineClientMessage.request(id: nextReqID(), command: .prompt(sessionId: sid, text: text)).framed)
    }

    func clear() {
        lines.removeAll()
        streamingLineID = nil
    }

    // MARK: 接收

    private func receive(_ frame: Data) {
        guard let msg = try? EngineServerMessage.decode(frame: frame) else { return }
        handle(msg)
    }

    private func handle(_ msg: EngineServerMessage) {
        switch msg {
        case let .hello(_, _, snapshot):
            status = "已连接（\(snapshot.models.first?.id ?? "?")）"
            sendConfigure()
            if let sid = sessionID {
                // 重连：先试 attach 恢复旧会话（拉权威 snapshot）。
                let rid = nextReqID()
                attachReqID = rid
                transport.send(EngineClientMessage.request(id: rid, command: .attach(sessionId: sid)).framed)
            } else {
                transport.send(EngineClientMessage.request(id: nextReqID(), command: .create(name: nil, model: nil)).framed)
            }
        case let .response(_, result):
            handleResult(result)
        case let .error(id, err):
            if id == attachReqID {
                // 引擎已重启、旧会话不存→新建一个。
                attachReqID = nil
                sessionID = nil
                transport.send(EngineClientMessage.request(id: nextReqID(), command: .create(name: nil, model: nil)).framed)
                return
            }
            appendLine(role: .system, text: "错误：\(err.message)")
            isBusy = false
            status = "就绪"
        case let .event(event):
            handleEvent(event)
        }
    }

    private func handleResult(_ result: EngineCommandResult) {
        switch result {
        case .configure:
            break
        case let .create(session):
            sessionID = session.id
            status = "就绪"
        case let .attach(session):
            sessionID = session.id
            attachReqID = nil
            restoreLines(from: session)
            status = "已恢复"
        case let .prompt(session):
            // 权威态：用 snapshot 的最后一条助手文本对齐流式结果。
            let lastAssistant = session.transcript.reversed().compactMap { item -> String? in
                if case let .assistant(_, text, _) = item { return text }
                return nil
            }.first
            if let sid = streamingLineID, let text = lastAssistant { updateLine(sid, text: text) }
            streamingLineID = nil
            isBusy = false
            status = "就绪"
        case .list, .abort:
            break
        }
    }

    /// 从会话权威 snapshot 重建可见 transcript（重连恢复）。
    private func restoreLines(from session: EngineSessionSnapshot) {
        lines = session.transcript.map { item in
            switch item {
            case let .user(id, text, _): return Line(id: id, role: .user, text: text)
            case let .assistant(id, text, _): return Line(id: id, role: .assistant, text: text)
            }
        }
        streamingLineID = nil
        isBusy = false
    }

    private func handleEvent(_ event: EngineServerEvent) {
        switch event {
        case let .sessionProgress(_, .assistantDelta(mid, delta)):
            if streamingLineID == nil {
                streamingLineID = mid
                lines.append(Line(id: mid, role: .assistant, text: delta))
            } else if let idx = lines.firstIndex(where: { $0.id == streamingLineID }) {
                lines[idx].text += delta
            }
        case let .toolInvocation(_, invocationId, toolName, input):
            handleToolInvocation(invocationId: invocationId, toolName: toolName, input: input)
        case .sessionProgress(_, .itemFinished),
             .sessionSnapshot, .serverSnapshot, .sessionRemoved:
            break // response 携带权威 snapshot，这里不重复处理
        }
    }

    // MARK: UI 侧工具

    /// UI 侧工具规格（绑 mac 能力，引擎永不持有其凭据）。
    static let uiToolSpecs: [EngineToolSpec] = [
        EngineToolSpec(
            name: "open_url",
            description: "在默认浏览器打开一个 http/https URL。",
            parameters: .map([
                ("type", .text("object")),
                ("properties", .map([("url", .map([("type", .text("string"))]))])),
                ("required", .array([.text("url")])),
            ])
        ),
    ]

    private func handleToolInvocation(invocationId: String, toolName: String, input: CBORValue) {
        appendLine(role: .system, text: "🔧 \(toolName)")
        let (content, isError) = Self.executeUITool(name: toolName, input: input)
        transport.send(EngineClientMessage.request(
            id: nextReqID(),
            command: .toolResult(invocationId: invocationId, content: content, isError: isError)
        ).framed)
    }

    /// 执行一个 UI 侧工具，返回（结果文本, 是否错误）。
    private static func executeUITool(name: String, input: CBORValue) -> (String, Bool) {
        switch name {
        case "open_url":
            guard let urlStr = input["url"]?.stringValue,
                  let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return ("open_url 需要合法的 http/https URL", true)
            }
            NSWorkspace.shared.open(url)
            return ("已在浏览器打开 \(urlStr)", false)
        default:
            return ("未知 UI 工具 \(name)", true)
        }
    }

    private func handleClose() {
        isConnected = false
        guard !reconnecting else { return }
        reconnecting = true
        status = "连接已断开，重连中…"
        // 保留 sessionID，重连后 attach 拉 snapshot 恢复。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isConnected else { return }
            self.establish()
        }
    }

    // MARK: 工具

    private func appendLine(role: Role, text: String) {
        lines.append(Line(id: UUID().uuidString, role: role, text: text))
    }

    private func updateLine(_ id: String, text: String) {
        if let idx = lines.firstIndex(where: { $0.id == id }) { lines[idx].text = text }
    }

    private func nextReqID() -> String {
        reqCounter += 1
        return "r\(reqCounter)"
    }
}
