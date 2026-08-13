//! 连接处理 + agent 多步 tool-calling 循环。
//!
//! 并发模型：连接线程读帧（`reader`）；一轮 `prompt` 在独立 worker 线程跑 agent
//! 循环，经共享 `writer`（写半，Mutex 保护）推事件/响应。连接线程把 `tool_result`/
//! `abort` 帧经 mpsc 通道路由给活跃 worker——否则 UI 侧工具会与读帧线程死锁。

use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::ai;
use crate::framing::{read_frame, write_frame};
use crate::protocol::*;
use crate::tools;

/// 自由聊天系统提示（对齐 Swift 侧 `AiTxtClient.chatSystemPrompt`）。
const SYSTEM_PROMPT: &str = "优先用简体中文回复。可调用工具获取信息后再回答。";

/// agent 循环单轮最多步数（防失控）。
const MAX_STEPS: usize = 8;

/// 等待 UI 侧工具结果的超时。
const UI_TOOL_TIMEOUT: Duration = Duration::from_secs(120);

/// UI 工具调用的全局单调序号。
static INVOCATION_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 进程内共享状态（纯内存，不持久化）。
#[derive(Default)]
pub struct EngineState {
    pub server_id: String,
    pub revision: AtomicU64,
    pub sessions: Mutex<HashMap<String, SessionSnapshot>>,
    pub provider: Mutex<Option<ai::ProviderConfig>>,
    counter: AtomicU64,
}

impl EngineState {
    pub fn new() -> Arc<Self> {
        Arc::new(EngineState {
            server_id: format!("engine-{}", now_ms()),
            ..Default::default()
        })
    }

    fn next_id(&self, prefix: &str) -> String {
        let n = self.counter.fetch_add(1, Ordering::Relaxed);
        format!("{prefix}-{n}")
    }

    fn server_snapshot(&self) -> ServerSnapshot {
        let sessions = self.sessions.lock().unwrap();
        ServerSnapshot {
            server_id: self.server_id.clone(),
            protocol_version: PROTOCOL_VERSION,
            revision: self.revision.load(Ordering::Relaxed),
            sessions: sessions
                .values()
                .map(|s| SessionMetadata {
                    id: s.id.clone(),
                    created_at: s.created_at,
                    name: None,
                })
                .collect(),
            models: vec![ModelRef {
                provider: "local".into(),
                id: "unknown".into(),
            }],
        }
    }
}

/// 连接线程发给 worker 的路由消息。
enum TurnInput {
    ToolResult {
        invocation_id: String,
        content: String,
        is_error: bool,
    },
    Abort,
}

/// 活跃轮次句柄：路由通道 + 完成标志。
struct ActiveTurn {
    tx: Sender<TurnInput>,
    done: Arc<AtomicBool>,
}

type SharedWriter = Arc<Mutex<UnixStream>>;

/// 处理单个连接的完整生命周期（阻塞，运行在自己的线程里）。
pub fn handle_connection(state: Arc<EngineState>, stream: UnixStream) {
    if let Err(e) = serve(&state, stream) {
        eprintln!("[engine] connection ended: {e}");
    }
}

fn serve(state: &Arc<EngineState>, stream: UnixStream) -> std::io::Result<()> {
    let mut reader = stream;
    let writer: SharedWriter = Arc::new(Mutex::new(reader.try_clone()?));

    // 1) 握手：首帧必为 client hello（携带 UI 侧工具规格）。
    let Some(first) = read_frame(&mut reader)? else {
        return Ok(());
    };
    let hello: ClientMessage = decode(&first).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, format!("bad hello: {e}"))
    })?;
    let ClientMessage::Hello { version, ui_tools } = hello else {
        return send_locked(
            &writer,
            &ServerMessage::Error {
                id: String::new(),
                error: ProtocolError {
                    code: "invalid_request".into(),
                    message: "first frame must be hello".into(),
                },
            },
        );
    };
    if version != PROTOCOL_VERSION {
        return send_locked(
            &writer,
            &ServerMessage::Error {
                id: String::new(),
                error: ProtocolError {
                    code: "version".into(),
                    message: format!("unsupported version {version}"),
                },
            },
        );
    }
    let connection_id = state.next_id("conn");
    send_locked(
        &writer,
        &ServerMessage::Hello {
            version: PROTOCOL_VERSION,
            connection_id,
            snapshot: state.server_snapshot(),
        },
    )?;

    let ui_tools = Arc::new(ui_tools);
    let mut active: Option<ActiveTurn> = None;

    // 2) 命令循环。
    while let Some(frame) = read_frame(&mut reader)? {
        let msg: ClientMessage = match decode(&frame) {
            Ok(m) => m,
            Err(e) => {
                send_locked(
                    &writer,
                    &ServerMessage::Error {
                        id: String::new(),
                        error: ProtocolError {
                            code: "invalid_request".into(),
                            message: format!("{e}"),
                        },
                    },
                )?;
                continue;
            }
        };
        let ClientMessage::Request { id, command } = msg else {
            continue; // 重复 hello 忽略
        };
        match command {
            Command::ToolResult {
                invocation_id,
                content,
                is_error,
            } => {
                if let Some(a) = &active {
                    let _ = a.tx.send(TurnInput::ToolResult {
                        invocation_id,
                        content,
                        is_error,
                    });
                }
                // tool_result 无响应（路由给 worker）。
            }
            Command::Abort { session_id } => {
                if let Some(a) = &active {
                    let _ = a.tx.send(TurnInput::Abort);
                }
                send_locked(
                    &writer,
                    &ServerMessage::Response {
                        id,
                        result: CommandResult::Abort { session_id },
                    },
                )?;
            }
            Command::Prompt { session_id, text } => {
                let busy = active
                    .as_ref()
                    .map(|a| !a.done.load(Ordering::Relaxed))
                    .unwrap_or(false);
                if busy {
                    send_locked(
                        &writer,
                        &ServerMessage::Error {
                            id,
                            error: ProtocolError {
                                code: "busy".into(),
                                message: "a turn is already in progress".into(),
                            },
                        },
                    )?;
                    continue;
                }
                let (tx, rx) = std::sync::mpsc::channel();
                let done = Arc::new(AtomicBool::new(false));
                active = Some(ActiveTurn {
                    tx,
                    done: done.clone(),
                });
                let st = state.clone();
                let w = writer.clone();
                let tools = ui_tools.clone();
                thread::spawn(move || {
                    run_turn(&st, &w, &tools, id, session_id, text, rx, done);
                });
            }
            other => handle_sync(state, &writer, id, other)?,
        }
    }
    Ok(())
}

/// 非轮次命令（同步应答）：list / create / attach / configure。
fn handle_sync(
    state: &Arc<EngineState>,
    writer: &SharedWriter,
    id: String,
    command: Command,
) -> std::io::Result<()> {
    match command {
        Command::List => {
            let list = state
                .sessions
                .lock()
                .unwrap()
                .values()
                .map(|s| SessionMetadata {
                    id: s.id.clone(),
                    created_at: s.created_at,
                    name: None,
                })
                .collect();
            send_locked(
                writer,
                &ServerMessage::Response {
                    id,
                    result: CommandResult::List { sessions: list },
                },
            )
        }
        Command::Create { name: _, model } => {
            let session = new_session(state, model);
            state
                .sessions
                .lock()
                .unwrap()
                .insert(session.id.clone(), session.clone());
            state.revision.fetch_add(1, Ordering::Relaxed);
            send_locked(
                writer,
                &ServerMessage::Response {
                    id,
                    result: CommandResult::Create { session },
                },
            )
        }
        Command::Attach { session_id } => {
            let session = state.sessions.lock().unwrap().get(&session_id).cloned();
            match session {
                Some(session) => send_locked(
                    writer,
                    &ServerMessage::Response {
                        id,
                        result: CommandResult::Attach { session },
                    },
                ),
                None => send_locked(
                    writer,
                    &ServerMessage::Error {
                        id,
                        error: ProtocolError {
                            code: "not_found".into(),
                            message: format!("no session {session_id}"),
                        },
                    },
                ),
            }
        }
        Command::Configure {
            base_url,
            model,
            api_key,
        } => {
            *state.provider.lock().unwrap() = Some(ai::ProviderConfig {
                base_url,
                model,
                api_key,
            });
            send_locked(
                writer,
                &ServerMessage::Response {
                    id,
                    result: CommandResult::Configure,
                },
            )
        }
        // Prompt / Abort / ToolResult 在 serve 里处理。
        _ => Ok(()),
    }
}

/// 在 worker 线程跑一轮 agent；结束置 `done`。
#[allow(clippy::too_many_arguments)]
fn run_turn(
    state: &Arc<EngineState>,
    writer: &SharedWriter,
    ui_tools: &[ToolSpec],
    req_id: String,
    session_id: String,
    user_text: String,
    rx: Receiver<TurnInput>,
    done: Arc<AtomicBool>,
) {
    if let Err(e) = run_turn_inner(
        state,
        writer,
        ui_tools,
        &req_id,
        &session_id,
        user_text,
        &rx,
    ) {
        eprintln!("[engine] turn error: {e}");
    }
    done.store(true, Ordering::Relaxed);
}

fn run_turn_inner(
    state: &Arc<EngineState>,
    writer: &SharedWriter,
    ui_tools: &[ToolSpec],
    req_id: &str,
    session_id: &str,
    user_text: String,
    rx: &Receiver<TurnInput>,
) -> std::io::Result<()> {
    // 1) 记录用户消息，构建历史消息（含 system）。
    let mut messages = {
        let mut sessions = state.sessions.lock().unwrap();
        let Some(session) = sessions.get_mut(session_id) else {
            return send_locked(
                writer,
                &ServerMessage::Error {
                    id: req_id.into(),
                    error: ProtocolError {
                        code: "not_found".into(),
                        message: format!("no session {session_id}"),
                    },
                },
            );
        };
        session.transcript.push(TranscriptItem::User {
            id: state.next_id("msg"),
            text: user_text,
            timestamp: now_ms(),
        });
        build_messages(&session.transcript)
    };

    let assistant_id = state.next_id("msg");
    let config = state.provider.lock().unwrap().clone();

    // 2) agent 多步循环。
    let reply = match config {
        None => "未配置 provider：请先经 configure 命令下发 base_url/model。".to_string(),
        Some(cfg) => {
            let mut all_tools = tools::engine_tool_specs();
            all_tools.extend(ui_tools.iter().cloned());
            run_agent_loop(
                &cfg,
                &all_tools,
                ui_tools,
                &mut messages,
                writer,
                session_id,
                rx,
            )
        }
    };

    // 3) 流式吐出终答（分片增量），落权威态，收尾。
    emit_reply(writer, session_id, &assistant_id, &reply)?;

    let ts = now_ms();
    let item = TranscriptItem::Assistant {
        id: assistant_id,
        text: reply,
        timestamp: ts,
    };
    let snapshot = {
        let mut sessions = state.sessions.lock().unwrap();
        let Some(session) = sessions.get_mut(session_id) else {
            return send_locked(
                writer,
                &ServerMessage::Error {
                    id: req_id.into(),
                    error: ProtocolError {
                        code: "not_found".into(),
                        message: format!("session {session_id} disappeared"),
                    },
                },
            );
        };
        session.transcript.push(item.clone());
        session.updated_at = ts;
        session.revision += 1;
        session.clone()
    };
    state.revision.fetch_add(1, Ordering::Relaxed);

    send_locked(
        writer,
        &ServerMessage::Event {
            event: ServerEvent::SessionProgress {
                session_id: session_id.into(),
                progress: TranscriptProgress::ItemFinished { item },
            },
        },
    )?;
    send_locked(
        writer,
        &ServerMessage::Response {
            id: req_id.into(),
            result: CommandResult::Prompt { session: snapshot },
        },
    )
}

/// 跑 tool-calling 循环，返回终答文本。工具执行期间会经 writer 推 tool_invocation。
fn run_agent_loop(
    cfg: &ai::ProviderConfig,
    all_tools: &[ToolSpec],
    ui_tools: &[ToolSpec],
    messages: &mut Vec<ai::ChatMessage>,
    writer: &SharedWriter,
    session_id: &str,
    rx: &Receiver<TurnInput>,
) -> String {
    for _ in 0..MAX_STEPS {
        // 轮首检查取消。
        match rx.try_recv() {
            Ok(TurnInput::Abort) | Err(TryRecvError::Disconnected) => return "（已取消）".into(),
            _ => {}
        }

        let resp = match ai::complete(cfg, messages, all_tools) {
            Ok(r) => r,
            Err(e) => return format!("调用 provider 失败：{e}"),
        };

        if resp.tool_calls.is_empty() {
            return resp.content.unwrap_or_default();
        }

        messages.push(ai::ChatMessage::Assistant {
            content: resp.content.clone(),
            tool_calls: resp.tool_calls.clone(),
        });

        for tc in &resp.tool_calls {
            let input: serde_json::Value =
                serde_json::from_str(&tc.arguments).unwrap_or(serde_json::Value::Null);

            let result = if let Some(r) = tools::run_engine_tool(&tc.name, &input) {
                r.unwrap_or_else(|e| format!("工具错误：{e}"))
            } else if ui_tools.iter().any(|t| t.name == tc.name) {
                match invoke_ui_tool(writer, session_id, &tc.name, &input, rx) {
                    ToolWait::Result(s) => s,
                    ToolWait::Aborted => {
                        messages.push(ai::ChatMessage::Tool {
                            tool_call_id: tc.id.clone(),
                            content: "（已取消）".into(),
                        });
                        return "（已取消）".into();
                    }
                }
            } else {
                format!("未知工具 {}", tc.name)
            };

            messages.push(ai::ChatMessage::Tool {
                tool_call_id: tc.id.clone(),
                content: result,
            });
        }
    }
    "（已达最大步数，未得终答）".into()
}

enum ToolWait {
    Result(String),
    Aborted,
}

/// 下发 tool_invocation 给 UI，阻塞等对应 tool_result（或 abort/超时）。
fn invoke_ui_tool(
    writer: &SharedWriter,
    session_id: &str,
    tool_name: &str,
    input: &serde_json::Value,
    rx: &Receiver<TurnInput>,
) -> ToolWait {
    let invocation_id = format!("inv-{}", INVOCATION_COUNTER.fetch_add(1, Ordering::Relaxed));
    if send_locked(
        writer,
        &ServerMessage::Event {
            event: ServerEvent::ToolInvocation {
                session_id: session_id.into(),
                invocation_id: invocation_id.clone(),
                tool_name: tool_name.into(),
                input: input.clone(),
            },
        },
    )
    .is_err()
    {
        return ToolWait::Result("下发 UI 工具失败".into());
    }

    let deadline = Instant::now() + UI_TOOL_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return ToolWait::Result("UI 工具超时".into());
        }
        match rx.recv_timeout(remaining) {
            Ok(TurnInput::ToolResult {
                invocation_id: iv,
                content,
                is_error,
            }) if iv == invocation_id => {
                return ToolWait::Result(if is_error {
                    format!("工具错误：{content}")
                } else {
                    content
                });
            }
            Ok(TurnInput::ToolResult { .. }) => continue, // 不匹配，忽略
            Ok(TurnInput::Abort) => return ToolWait::Aborted,
            Err(RecvTimeoutError::Timeout) => return ToolWait::Result("UI 工具超时".into()),
            Err(RecvTimeoutError::Disconnected) => return ToolWait::Aborted,
        }
    }
}

/// 分片吐出终答为 assistant_delta（伪流式，每片若干字符）。
fn emit_reply(
    writer: &SharedWriter,
    session_id: &str,
    message_id: &str,
    reply: &str,
) -> std::io::Result<()> {
    let chars: Vec<char> = reply.chars().collect();
    for chunk in chars.chunks(6) {
        let delta: String = chunk.iter().collect();
        send_locked(
            writer,
            &ServerMessage::Event {
                event: ServerEvent::SessionProgress {
                    session_id: session_id.into(),
                    progress: TranscriptProgress::AssistantDelta {
                        message_id: message_id.into(),
                        delta,
                    },
                },
            },
        )?;
    }
    Ok(())
}

/// transcript → provider 消息（前置 system 提示）。
fn build_messages(transcript: &[TranscriptItem]) -> Vec<ai::ChatMessage> {
    let mut msgs = vec![ai::ChatMessage::System(SYSTEM_PROMPT.into())];
    for item in transcript {
        match item {
            TranscriptItem::User { text, .. } => msgs.push(ai::ChatMessage::User(text.clone())),
            TranscriptItem::Assistant { text, .. } => msgs.push(ai::ChatMessage::Assistant {
                content: Some(text.clone()),
                tool_calls: Vec::new(),
            }),
        }
    }
    msgs
}

fn new_session(state: &Arc<EngineState>, model: Option<ModelRef>) -> SessionSnapshot {
    let ts = now_ms();
    SessionSnapshot {
        id: state.next_id("sess"),
        created_at: ts,
        updated_at: ts,
        revision: 0,
        model: model.unwrap_or(ModelRef {
            provider: "local".into(),
            id: "unknown".into(),
        }),
        transcript: Vec::new(),
    }
}

fn send_locked(writer: &SharedWriter, msg: &ServerMessage) -> std::io::Result<()> {
    let mut w = writer.lock().unwrap();
    write_frame(&mut *w, &encode(msg))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
