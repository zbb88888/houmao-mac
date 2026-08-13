//! OpenAI 兼容 provider：非流式 tool-calling 补全。
//!
//! 不引 async runtime——`ureq` 阻塞 HTTP。支持 tool-calling：请求带 `tools`、
//! 解析回传的 `tool_calls`。`<think>...</think>` 从 content 剥离。

use serde_json::{json, Value};

use crate::protocol::ToolSpec;

/// provider 连接配置，经协议 `configure` 命令下发（不落盘、不读环境变量）。
#[derive(Clone)]
pub struct ProviderConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
}

/// 对话消息（支持 tool-calling）。
pub enum ChatMessage {
    System(String),
    User(String),
    Assistant {
        content: Option<String>,
        tool_calls: Vec<ToolCall>,
    },
    Tool {
        tool_call_id: String,
        content: String,
    },
}

/// 模型请求的一次工具调用。`arguments` 是模型回传的原始 JSON 字符串。
#[derive(Clone)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// 一次补全的助手回合：终答文本 和/或 工具调用。
pub struct AssistantResponse {
    pub content: Option<String>,
    pub tool_calls: Vec<ToolCall>,
}

/// 非流式补全，返回 content 和/或 tool_calls。阻塞。
pub fn complete(
    config: &ProviderConfig,
    messages: &[ChatMessage],
    tools: &[ToolSpec],
) -> Result<AssistantResponse, String> {
    let endpoint = if config.base_url.ends_with('/') {
        format!("{}v1/chat/completions", config.base_url)
    } else {
        format!("{}/v1/chat/completions", config.base_url)
    };

    let body = build_body(config, messages, tools);
    let json = serde_json::to_string(&body).map_err(|e| format!("编码请求失败: {e}"))?;

    let mut req = ureq::post(&endpoint)
        .set("Content-Type", "application/json")
        .set("Connection", "close"); // 不复用连接，避免命中已被对端关闭的池连接
    if !config.api_key.is_empty() {
        req = req.set("Authorization", &format!("Bearer {}", config.api_key));
    }
    let resp = req
        .send_string(&json)
        .map_err(|e| format!("请求失败: {e}"))?;
    let text = resp
        .into_string()
        .map_err(|e| format!("读取响应失败: {e}"))?;
    parse_response(&text)
}

fn build_body(config: &ProviderConfig, messages: &[ChatMessage], tools: &[ToolSpec]) -> Value {
    let msgs: Vec<Value> = messages.iter().map(message_to_json).collect();
    let mut body = json!({
        "model": config.model,
        "messages": msgs,
        "stream": false,
    });
    if !tools.is_empty() {
        let specs: Vec<Value> = tools
            .iter()
            .map(|t| {
                json!({
                    "type": "function",
                    "function": {
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parameters,
                    }
                })
            })
            .collect();
        body["tools"] = Value::Array(specs);
    }
    body
}

fn message_to_json(m: &ChatMessage) -> Value {
    match m {
        ChatMessage::System(s) => json!({ "role": "system", "content": s }),
        ChatMessage::User(s) => json!({ "role": "user", "content": s }),
        ChatMessage::Assistant {
            content,
            tool_calls,
        } => {
            let calls: Vec<Value> = tool_calls
                .iter()
                .map(|tc| {
                    json!({
                        "id": tc.id,
                        "type": "function",
                        "function": { "name": tc.name, "arguments": tc.arguments },
                    })
                })
                .collect();
            let mut obj = json!({ "role": "assistant", "content": content });
            if !calls.is_empty() {
                obj["tool_calls"] = Value::Array(calls);
            }
            obj
        }
        ChatMessage::Tool {
            tool_call_id,
            content,
        } => {
            json!({ "role": "tool", "tool_call_id": tool_call_id, "content": content })
        }
    }
}

fn parse_response(text: &str) -> Result<AssistantResponse, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| format!("解析响应失败: {e}: {text}"))?;
    let msg = v
        .get("choices")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())
        .and_then(|c| c.get("message"))
        .ok_or_else(|| format!("响应缺 choices[0].message: {text}"))?;

    let raw = msg
        .get("content")
        .and_then(|c| c.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| msg.get("reasoning_content").and_then(|c| c.as_str()));
    let content = raw.map(strip_think).filter(|s| !s.is_empty());

    let tool_calls = msg
        .get("tool_calls")
        .and_then(|c| c.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|tc| {
                    let id = tc.get("id")?.as_str()?.to_string();
                    let f = tc.get("function")?;
                    let name = f.get("name")?.as_str()?.to_string();
                    let arguments = f
                        .get("arguments")
                        .and_then(|a| a.as_str())
                        .unwrap_or("{}")
                        .to_string();
                    Some(ToolCall {
                        id,
                        name,
                        arguments,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    Ok(AssistantResponse {
        content,
        tool_calls,
    })
}

/// 剥离全部 `<think>...</think>` 段。
pub fn strip_think(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rem = s;
    while let Some(start) = rem.find("<think>") {
        out.push_str(&rem[..start]);
        if let Some(end) = rem[start..].find("</think>") {
            rem = &rem[start + end + "</think>".len()..];
        } else {
            rem = ""; // 未闭合，丢弃其后
            break;
        }
    }
    out.push_str(rem);
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_think_spans() {
        assert_eq!(strip_think("<think>reason</think>你好"), "你好");
        assert_eq!(strip_think("a<think>x</think>b<think>y</think>c"), "abc");
        assert_eq!(strip_think("plain"), "plain");
        assert_eq!(strip_think("open<think>never closes"), "open");
    }

    #[test]
    fn parses_final_content() {
        let text = r#"{"choices":[{"message":{"content":"<think>t</think>hi"}}]}"#;
        let r = parse_response(text).unwrap();
        assert_eq!(r.content.as_deref(), Some("hi"));
        assert!(r.tool_calls.is_empty());
    }

    #[test]
    fn parses_tool_call() {
        let text = r#"{"choices":[{"message":{"content":null,"tool_calls":[
            {"id":"c1","type":"function","function":{"name":"open_url","arguments":"{\"url\":\"https://x\"}"}}]}}]}"#;
        let r = parse_response(text).unwrap();
        assert!(r.content.is_none());
        assert_eq!(r.tool_calls.len(), 1);
        assert_eq!(r.tool_calls[0].name, "open_url");
        assert_eq!(r.tool_calls[0].arguments, r#"{"url":"https://x"}"#);
    }
}
