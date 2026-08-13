import Foundation

// 引擎线协议的 Swift 侧类型 + CBOR 映射。字段名/标签与 Rust `protocol.rs` 严格一致。
// 客户端只需：编码 `EngineClientMessage`，解码 `EngineServerMessage`。

/// 协议版本，必须与引擎 `PROTOCOL_VERSION` 一致。
let engineProtocolVersion: UInt64 = 1

// MARK: - 公共类型

struct EngineModelRef: Equatable {
    let provider: String
    let id: String

    var cbor: CBORValue { .map([("provider", .text(provider)), ("id", .text(id))]) }

    init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }

    init?(cbor: CBORValue) {
        guard let p = cbor["provider"]?.stringValue, let i = cbor["id"]?.stringValue else { return nil }
        provider = p
        id = i
    }
}

/// 工具规格（UI 侧工具经 hello 声明给引擎）。`parameters` 为 JSON Schema。
struct EngineToolSpec {
    let name: String
    let description: String
    let parameters: CBORValue

    var cbor: CBORValue {
        .map([
            ("name", .text(name)),
            ("description", .text(description)),
            ("parameters", parameters),
        ])
    }
}

struct EngineSessionMetadata: Equatable {
    let id: String
    let createdAt: UInt64
    let name: String?

    init?(cbor: CBORValue) {
        guard let i = cbor["id"]?.stringValue, let c = cbor["created_at"]?.uintValue else { return nil }
        id = i
        createdAt = c
        name = cbor["name"]?.stringValue
    }
}

struct EngineProtocolError: Equatable {
    let code: String
    let message: String

    init?(cbor: CBORValue) {
        guard let c = cbor["code"]?.stringValue, let m = cbor["message"]?.stringValue else { return nil }
        code = c
        message = m
    }
}

enum EngineTranscriptItem: Equatable {
    case user(id: String, text: String, timestamp: UInt64)
    case assistant(id: String, text: String, timestamp: UInt64)

    init?(cbor: CBORValue) {
        guard let role = cbor["role"]?.stringValue,
              let id = cbor["id"]?.stringValue,
              let text = cbor["text"]?.stringValue,
              let ts = cbor["timestamp"]?.uintValue
        else { return nil }
        switch role {
        case "user": self = .user(id: id, text: text, timestamp: ts)
        case "assistant": self = .assistant(id: id, text: text, timestamp: ts)
        default: return nil
        }
    }
}

struct EngineServerSnapshot: Equatable {
    let serverId: String
    let protocolVersion: UInt64
    let revision: UInt64
    let sessions: [EngineSessionMetadata]
    let models: [EngineModelRef]

    init?(cbor: CBORValue) {
        guard let sid = cbor["server_id"]?.stringValue,
              let pv = cbor["protocol_version"]?.uintValue,
              let rev = cbor["revision"]?.uintValue,
              let sessions = cbor["sessions"]?.arrayValue,
              let models = cbor["models"]?.arrayValue
        else { return nil }
        serverId = sid
        protocolVersion = pv
        revision = rev
        self.sessions = sessions.compactMap(EngineSessionMetadata.init(cbor:))
        self.models = models.compactMap(EngineModelRef.init(cbor:))
    }
}

struct EngineSessionSnapshot: Equatable {
    let id: String
    let createdAt: UInt64
    let updatedAt: UInt64
    let revision: UInt64
    let model: EngineModelRef
    let transcript: [EngineTranscriptItem]

    init?(cbor: CBORValue) {
        guard let i = cbor["id"]?.stringValue,
              let c = cbor["created_at"]?.uintValue,
              let u = cbor["updated_at"]?.uintValue,
              let rev = cbor["revision"]?.uintValue,
              let m = cbor["model"].flatMap(EngineModelRef.init(cbor:)),
              let t = cbor["transcript"]?.arrayValue
        else { return nil }
        id = i
        createdAt = c
        updatedAt = u
        revision = rev
        model = m
        transcript = t.compactMap(EngineTranscriptItem.init(cbor:))
    }
}

enum EngineTranscriptProgress: Equatable {
    case assistantDelta(messageId: String, delta: String)
    case itemFinished(EngineTranscriptItem)

    init?(cbor: CBORValue) {
        guard let type = cbor["type"]?.stringValue else { return nil }
        switch type {
        case "assistant_delta":
            guard let mid = cbor["message_id"]?.stringValue, let d = cbor["delta"]?.stringValue else { return nil }
            self = .assistantDelta(messageId: mid, delta: d)
        case "item_finished":
            guard let item = cbor["item"].flatMap(EngineTranscriptItem.init(cbor:)) else { return nil }
            self = .itemFinished(item)
        default:
            return nil
        }
    }
}

// MARK: - 客户端 → 服务端

enum EngineCommand {
    case list
    case create(name: String?, model: EngineModelRef?)
    case prompt(sessionId: String, text: String)
    case abort(sessionId: String)
    case attach(sessionId: String)
    case configure(baseURL: String, model: String, apiKey: String)
    case toolResult(invocationId: String, content: String, isError: Bool)

    var cbor: CBORValue {
        switch self {
        case .list:
            return .map([("command", .text("list"))])
        case let .create(name, model):
            var pairs: [(String, CBORValue)] = [("command", .text("create"))]
            if let name { pairs.append(("name", .text(name))) }
            if let model { pairs.append(("model", model.cbor)) }
            return .map(pairs)
        case let .prompt(sessionId, text):
            return .map([("command", .text("prompt")), ("session_id", .text(sessionId)), ("text", .text(text))])
        case let .abort(sessionId):
            return .map([("command", .text("abort")), ("session_id", .text(sessionId))])
        case let .attach(sessionId):
            return .map([("command", .text("attach")), ("session_id", .text(sessionId))])
        case let .configure(baseURL, model, apiKey):
            return .map([
                ("command", .text("configure")),
                ("base_url", .text(baseURL)),
                ("model", .text(model)),
                ("api_key", .text(apiKey)),
            ])
        case let .toolResult(invocationId, content, isError):
            return .map([
                ("command", .text("tool_result")),
                ("invocation_id", .text(invocationId)),
                ("content", .text(content)),
                ("is_error", .bool(isError)),
            ])
        }
    }
}

enum EngineClientMessage {
    case hello(version: UInt64, uiTools: [EngineToolSpec])
    case request(id: String, command: EngineCommand)

    var cbor: CBORValue {
        switch self {
        case let .hello(version, uiTools):
            var pairs: [(String, CBORValue)] = [("type", .text("hello")), ("version", .uint(version))]
            if !uiTools.isEmpty { pairs.append(("ui_tools", .array(uiTools.map { $0.cbor }))) }
            return .map(pairs)
        case let .request(id, command):
            return .map([("type", .text("request")), ("id", .text(id)), ("command", command.cbor)])
        }
    }

    /// 编码并加帧，可直接写入 socket。
    var framed: Data { EngineFraming.frame(encodeCBOR(cbor)) }
}

// MARK: - 服务端 → 客户端

enum EngineCommandResult: Equatable {
    case list([EngineSessionMetadata])
    case create(EngineSessionSnapshot)
    case prompt(EngineSessionSnapshot)
    case abort(sessionId: String)
    case attach(EngineSessionSnapshot)
    case configure

    init?(cbor: CBORValue) {
        guard let command = cbor["command"]?.stringValue else { return nil }
        switch command {
        case "list":
            let sessions = cbor["sessions"]?.arrayValue?.compactMap(EngineSessionMetadata.init(cbor:)) ?? []
            self = .list(sessions)
        case "create":
            guard let s = cbor["session"].flatMap(EngineSessionSnapshot.init(cbor:)) else { return nil }
            self = .create(s)
        case "prompt":
            guard let s = cbor["session"].flatMap(EngineSessionSnapshot.init(cbor:)) else { return nil }
            self = .prompt(s)
        case "abort":
            guard let sid = cbor["session_id"]?.stringValue else { return nil }
            self = .abort(sessionId: sid)
        case "attach":
            guard let s = cbor["session"].flatMap(EngineSessionSnapshot.init(cbor:)) else { return nil }
            self = .attach(s)
        case "configure":
            self = .configure
        default:
            return nil
        }
    }
}

enum EngineServerEvent: Equatable {
    case serverSnapshot(EngineServerSnapshot)
    case sessionSnapshot(EngineSessionSnapshot)
    case sessionProgress(sessionId: String, progress: EngineTranscriptProgress)
    case sessionRemoved(sessionId: String)
    case toolInvocation(sessionId: String, invocationId: String, toolName: String, input: CBORValue)

    init?(cbor: CBORValue) {
        guard let type = cbor["type"]?.stringValue else { return nil }
        switch type {
        case "server_snapshot":
            guard let s = cbor["snapshot"].flatMap(EngineServerSnapshot.init(cbor:)) else { return nil }
            self = .serverSnapshot(s)
        case "session_snapshot":
            guard let s = cbor["snapshot"].flatMap(EngineSessionSnapshot.init(cbor:)) else { return nil }
            self = .sessionSnapshot(s)
        case "session_progress":
            guard let sid = cbor["session_id"]?.stringValue,
                  let p = cbor["progress"].flatMap(EngineTranscriptProgress.init(cbor:)) else { return nil }
            self = .sessionProgress(sessionId: sid, progress: p)
        case "session_removed":
            guard let sid = cbor["session_id"]?.stringValue else { return nil }
            self = .sessionRemoved(sessionId: sid)
        case "tool_invocation":
            guard let sid = cbor["session_id"]?.stringValue,
                  let iid = cbor["invocation_id"]?.stringValue,
                  let name = cbor["tool_name"]?.stringValue,
                  let input = cbor["input"] else { return nil }
            self = .toolInvocation(sessionId: sid, invocationId: iid, toolName: name, input: input)
        default:
            return nil
        }
    }
}

enum EngineServerMessage: Equatable {
    case hello(version: UInt64, connectionId: String, snapshot: EngineServerSnapshot)
    case response(id: String, result: EngineCommandResult)
    case error(id: String, error: EngineProtocolError)
    case event(EngineServerEvent)

    init?(cbor: CBORValue) {
        guard let type = cbor["type"]?.stringValue else { return nil }
        switch type {
        case "hello":
            guard let v = cbor["version"]?.uintValue,
                  let cid = cbor["connection_id"]?.stringValue,
                  let snap = cbor["snapshot"].flatMap(EngineServerSnapshot.init(cbor:)) else { return nil }
            self = .hello(version: v, connectionId: cid, snapshot: snap)
        case "response":
            guard let id = cbor["id"]?.stringValue,
                  let res = cbor["result"].flatMap(EngineCommandResult.init(cbor:)) else { return nil }
            self = .response(id: id, result: res)
        case "error":
            guard let id = cbor["id"]?.stringValue,
                  let err = cbor["error"].flatMap(EngineProtocolError.init(cbor:)) else { return nil }
            self = .error(id: id, error: err)
        case "event":
            guard let ev = cbor["event"].flatMap(EngineServerEvent.init(cbor:)) else { return nil }
            self = .event(ev)
        default:
            return nil
        }
    }

    /// 从一帧载荷解码。
    static func decode(frame: Data) throws -> EngineServerMessage? {
        EngineServerMessage(cbor: try decodeCBOR(frame))
    }
}
