//! 端到端：agent 多步 tool-calling 循环 + engine 侧工具 + UI 侧工具往返。
//! 用进程内 mock provider（非流式 JSON），不依赖外部 LLM。

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use houmao_engine::framing::{read_frame, write_frame};
use houmao_engine::protocol::*;
use houmao_engine::server::{handle_connection, EngineState};
use serde_json::json;

/// 读完整 HTTP 请求（头 + Content-Length 体）。
fn read_http_request(sock: &mut TcpStream) -> Vec<u8> {
    let mut data = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let n = match sock.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        data.extend_from_slice(&buf[..n]);
        if let Some(idx) = find_subslice(&data, b"\r\n\r\n") {
            let content_length = parse_content_length(&data[..idx]);
            if data.len() >= idx + 4 + content_length {
                break;
            }
        }
    }
    data
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn parse_content_length(headers: &[u8]) -> usize {
    let s = String::from_utf8_lossy(headers);
    for line in s.lines() {
        if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            return v.trim().parse().unwrap_or(0);
        }
    }
    0
}

/// mock provider：第 i 个连接返回 responses[i]，并记录收到的请求体。
/// 每连接一个线程（不做顺序 HOL），序号按接受顺序原子递增。
fn start_mock(responses: Vec<String>) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let responses = Arc::new(responses);
    let counter = Arc::new(AtomicUsize::new(0));
    let recv_outer = received.clone();
    thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut sock) = conn else { break };
            let idx = counter.fetch_add(1, Ordering::SeqCst);
            let responses = responses.clone();
            let recv = recv_outer.clone();
            thread::spawn(move || {
                let req = read_http_request(&mut sock);
                let req_str = String::from_utf8_lossy(&req);
                let body = req_str
                    .split_once("\r\n\r\n")
                    .map_or("", |x| x.1)
                    .to_string();
                recv.lock().unwrap().push(body);
                let resp_body = responses.get(idx).cloned().unwrap_or_default();
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",
                    resp_body.len(),
                    resp_body
                );
                let _ = sock.write_all(resp.as_bytes());
            });
        }
    });
    (format!("http://127.0.0.1:{port}"), received)
}

fn final_completion(content: &str) -> String {
    json!({ "choices": [{ "message": { "content": content } }] }).to_string()
}

fn tool_completion(name: &str, arguments: &str) -> String {
    json!({ "choices": [{ "message": {
        "content": null,
        "tool_calls": [{ "id": "c1", "type": "function", "function": { "name": name, "arguments": arguments } }]
    } }] })
    .to_string()
}

fn spawn_engine(tag: &str) -> PathBuf {
    let sock_path =
        std::env::temp_dir().join(format!("houmao-test-{}-{tag}.sock", std::process::id()));
    let _ = std::fs::remove_file(&sock_path);
    let listener = std::os::unix::net::UnixListener::bind(&sock_path).unwrap();
    let state = EngineState::new();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let st = state.clone();
            thread::spawn(move || handle_connection(st, stream));
        }
    });
    sock_path
}

fn send_msg(stream: &mut UnixStream, msg: &ClientMessage) {
    write_frame(stream, &encode(msg)).unwrap();
}

fn read_server(stream: &mut UnixStream) -> ServerMessage {
    let frame = read_frame(stream).unwrap().expect("stream closed");
    decode(&frame).unwrap()
}

fn connect_and_setup(sock: &Path, base: &str, ui_tools: Vec<ToolSpec>) -> (UnixStream, String) {
    let mut client = UnixStream::connect(sock).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();

    send_msg(
        &mut client,
        &ClientMessage::Hello {
            version: PROTOCOL_VERSION,
            ui_tools,
        },
    );
    assert!(matches!(
        read_server(&mut client),
        ServerMessage::Hello { .. }
    ));

    send_msg(
        &mut client,
        &ClientMessage::Request {
            id: "cfg".into(),
            command: Command::Configure {
                base_url: base.into(),
                model: "mock".into(),
                api_key: String::new(),
            },
        },
    );
    assert!(matches!(
        read_server(&mut client),
        ServerMessage::Response {
            result: CommandResult::Configure,
            ..
        }
    ));

    send_msg(
        &mut client,
        &ClientMessage::Request {
            id: "r1".into(),
            command: Command::Create {
                name: None,
                model: None,
            },
        },
    );
    let sid = match read_server(&mut client) {
        ServerMessage::Response {
            result: CommandResult::Create { session },
            ..
        } => session.id,
        o => panic!("unexpected create: {o:?}"),
    };
    (client, sid)
}

fn send_prompt(client: &mut UnixStream, sid: &str, text: &str) {
    send_msg(
        client,
        &ClientMessage::Request {
            id: "p".into(),
            command: Command::Prompt {
                session_id: sid.into(),
                text: text.into(),
            },
        },
    );
}

/// 读到最终 Prompt 响应；`on_tool` 处理 tool_invocation（返回结果内容）。
fn drain(
    client: &mut UnixStream,
    mut on_tool: impl FnMut(&str, &serde_json::Value) -> String,
) -> (String, SessionSnapshot) {
    let mut streamed = String::new();
    loop {
        match read_server(client) {
            ServerMessage::Event {
                event:
                    ServerEvent::SessionProgress {
                        progress: TranscriptProgress::AssistantDelta { delta, .. },
                        ..
                    },
            } => streamed.push_str(&delta),
            ServerMessage::Event {
                event:
                    ServerEvent::ToolInvocation {
                        invocation_id,
                        tool_name,
                        input,
                        ..
                    },
            } => {
                let content = on_tool(&tool_name, &input);
                send_msg(
                    client,
                    &ClientMessage::Request {
                        id: "tr".into(),
                        command: Command::ToolResult {
                            invocation_id,
                            content,
                            is_error: false,
                        },
                    },
                );
            }
            ServerMessage::Event { .. } => {}
            ServerMessage::Response {
                result: CommandResult::Prompt { session },
                ..
            } => return (streamed, session),
            o => panic!("unexpected during prompt: {o:?}"),
        }
    }
}

fn assistant_texts(session: &SessionSnapshot) -> Vec<String> {
    session
        .transcript
        .iter()
        .filter_map(|it| match it {
            TranscriptItem::Assistant { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn plain_answer_streams_and_strips_think() {
    let (base, _rx) = start_mock(vec![final_completion("<think>t</think>你好")]);
    let sock = spawn_engine("plain");
    let (mut client, sid) = connect_and_setup(&sock, &base, vec![]);
    send_prompt(&mut client, &sid, "hi");
    let (streamed, session) = drain(&mut client, |_, _| String::new());
    let _ = std::fs::remove_file(&sock);
    assert_eq!(streamed, "你好");
    assert_eq!(assistant_texts(&session), vec!["你好".to_string()]);
}

#[test]
fn engine_side_tool_loop() {
    // 首次返 get_time 工具调用；引擎执行后二次返终答。
    let (base, received) = start_mock(vec![
        tool_completion("get_time", "{}"),
        final_completion("已获取时间"),
    ]);
    let sock = spawn_engine("engine-tool");
    let (mut client, sid) = connect_and_setup(&sock, &base, vec![]);
    send_prompt(&mut client, &sid, "现在几点");
    let (streamed, _session) = drain(&mut client, |_, _| String::new());
    let _ = std::fs::remove_file(&sock);
    assert_eq!(streamed, "已获取时间");
    let reqs = received.lock().unwrap();
    assert!(reqs.len() >= 2, "应有两次 provider 请求");
    // 第二次请求把工具结果回喂给模型。
    assert!(reqs[1].contains("\"role\":\"tool\""));
    assert!(reqs[1].contains("\"tool_call_id\":\"c1\""));
}

#[test]
fn ui_side_tool_round_trip() {
    let (base, received) = start_mock(vec![
        tool_completion("open_url", r#"{"url":"https://x"}"#),
        final_completion("已打开"),
    ]);
    let sock = spawn_engine("ui-tool");
    let ui = vec![ToolSpec {
        name: "open_url".into(),
        description: "open a URL".into(),
        parameters: json!({ "type": "object", "properties": { "url": { "type": "string" } } }),
    }];
    let (mut client, sid) = connect_and_setup(&sock, &base, ui);
    send_prompt(&mut client, &sid, "打开网页");

    let mut seen_url = String::new();
    let (streamed, _session) = drain(&mut client, |name, input| {
        assert_eq!(name, "open_url");
        seen_url = input
            .get("url")
            .and_then(|u| u.as_str())
            .unwrap_or("")
            .to_string();
        "ok".into()
    });
    let _ = std::fs::remove_file(&sock);

    assert_eq!(streamed, "已打开");
    assert_eq!(seen_url, "https://x");
    let reqs = received.lock().unwrap();
    assert!(reqs.len() >= 2);
    // UI 回填的结果 "ok" 被回喂给模型。
    assert!(reqs[1].contains("\"content\":\"ok\""));
}
