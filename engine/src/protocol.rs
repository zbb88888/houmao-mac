//! 线协议消息类型（serde + CBOR）。镜像 pi-protocol 的 vocabulary，裁剪到 houmao 所需。
//!
//! 线格式见 [`crate::framing`]：`[u32-be 长度][CBOR item]`。
//! 消息用内部标签（`{"type": "hello", ...}`），便于 Swift `Codable` 对接。

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 协议版本。客户端首帧 `hello` 必须携带；不匹配则服务端拒绝。
pub const PROTOCOL_VERSION: u32 = 1;

// ===== 公共类型 =====

/// 工具规格（UI 侧工具经 hello 声明；engine 侧工具内建）。`parameters` 为 JSON Schema。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

/// 模型引用：provider + 模型 id。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelRef {
    pub provider: String,
    pub id: String,
}

/// 会话元数据（无需持有 runtime 即可获取的持久字段）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMetadata {
    pub id: String,
    pub created_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// 服务端全局快照（权威态）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerSnapshot {
    pub server_id: String,
    pub protocol_version: u32,
    pub revision: u64,
    pub sessions: Vec<SessionMetadata>,
    pub models: Vec<ModelRef>,
}

/// 单会话权威态。transcript 为全量，重连时据此恢复。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSnapshot {
    pub id: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub revision: u64,
    pub model: ModelRef,
    pub transcript: Vec<TranscriptItem>,
}

/// transcript 条目（第一阶段最小集：user / assistant）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum TranscriptItem {
    User {
        id: String,
        text: String,
        timestamp: u64,
    },
    Assistant {
        id: String,
        text: String,
        timestamp: u64,
    },
}

/// 瞬态增量（UI 提示，非权威态）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TranscriptProgress {
    /// 助手消息的一段增量 token。
    AssistantDelta { message_id: String, delta: String },
    /// 一个条目完结。
    ItemFinished { item: TranscriptItem },
}

// ===== 客户端 → 服务端 =====

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// 必为客户端首帧。
    Hello {
        version: u32,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        ui_tools: Vec<ToolSpec>,
    },
    /// 关联式请求。
    Request { id: String, command: Command },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Command {
    List,
    Create {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<ModelRef>,
    },
    Prompt {
        session_id: String,
        text: String,
    },
    Abort {
        session_id: String,
    },
    Attach {
        session_id: String,
    },
    Configure {
        base_url: String,
        model: String,
        #[serde(default)]
        api_key: String,
    },
    ToolResult {
        invocation_id: String,
        content: String,
        #[serde(default)]
        is_error: bool,
    },
}

// ===== 服务端 → 客户端 =====

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    /// 对客户端 hello 的应答，附全局快照。
    Hello {
        version: u32,
        connection_id: String,
        snapshot: ServerSnapshot,
    },
    /// 对 `Request` 的应答（成功）。
    Response { id: String, result: CommandResult },
    /// 对 `Request` 的应答（失败）。
    Error { id: String, error: ProtocolError },
    /// 服务端主动事件。
    Event { event: ServerEvent },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum CommandResult {
    List { sessions: Vec<SessionMetadata> },
    Create { session: SessionSnapshot },
    Prompt { session: SessionSnapshot },
    Abort { session_id: String },
    Attach { session: SessionSnapshot },
    Configure,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    ServerSnapshot {
        snapshot: ServerSnapshot,
    },
    SessionSnapshot {
        snapshot: SessionSnapshot,
    },
    SessionProgress {
        session_id: String,
        progress: TranscriptProgress,
    },
    SessionRemoved {
        session_id: String,
    },
    /// 请 UI 执行一个 UI 侧工具，UI 经 `tool_result` 命令回填。
    ToolInvocation {
        session_id: String,
        invocation_id: String,
        tool_name: String,
        input: Value,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

// ===== 编解码 =====

/// 把消息编码成 CBOR 字节。
pub fn encode<T: Serialize>(value: &T) -> Vec<u8> {
    let mut buf = Vec::new();
    ciborium::into_writer(value, &mut buf).expect("CBOR encode into Vec cannot fail");
    buf
}

/// 从 CBOR 字节解码消息。
pub fn decode<T: for<'de> Deserialize<'de>>(
    bytes: &[u8],
) -> Result<T, ciborium::de::Error<std::io::Error>> {
    ciborium::from_reader(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 内部标签枚举经 CBOR 往返后保持不变（ciborium + serde tagged enum 的关键验证点）。
    #[test]
    fn client_hello_round_trip() {
        let msg = ClientMessage::Hello {
            version: PROTOCOL_VERSION,
            ui_tools: vec![],
        };
        let back: ClientMessage = decode(&encode(&msg)).unwrap();
        assert!(
            matches!(back, ClientMessage::Hello { version, .. } if version == PROTOCOL_VERSION)
        );
    }

    #[test]
    fn prompt_command_round_trip() {
        let msg = ClientMessage::Request {
            id: "r1".into(),
            command: Command::Prompt {
                session_id: "s1".into(),
                text: "你好".into(),
            },
        };
        let back: ClientMessage = decode(&encode(&msg)).unwrap();
        match back {
            ClientMessage::Request {
                id,
                command: Command::Prompt { session_id, text },
            } => {
                assert_eq!(id, "r1");
                assert_eq!(session_id, "s1");
                assert_eq!(text, "你好");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn server_event_progress_round_trip() {
        let msg = ServerMessage::Event {
            event: ServerEvent::SessionProgress {
                session_id: "s1".into(),
                progress: TranscriptProgress::AssistantDelta {
                    message_id: "m1".into(),
                    delta: "片段".into(),
                },
            },
        };
        let back: ServerMessage = decode(&encode(&msg)).unwrap();
        assert!(matches!(back, ServerMessage::Event { .. }));
    }

    #[test]
    fn transcript_item_tag_is_role() {
        let item = TranscriptItem::Assistant {
            id: "m1".into(),
            text: "hi".into(),
            timestamp: 0,
        };
        let back: TranscriptItem = decode(&encode(&item)).unwrap();
        assert!(matches!(back, TranscriptItem::Assistant { .. }));
    }
}
