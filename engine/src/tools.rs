//! Engine 侧内建工具（在引擎进程内执行）。UI 侧工具经 hello 声明、由 UI 执行。

use serde_json::{json, Value};

use crate::protocol::ToolSpec;

/// engine 侧工具的规格，合并进 agent 的工具集。
pub fn engine_tool_specs() -> Vec<ToolSpec> {
    vec![ToolSpec {
        name: "get_time".into(),
        description: "返回当前 UNIX 时间（秒）。无参数。".into(),
        parameters: json!({ "type": "object", "properties": {}, "additionalProperties": false }),
    }]
}

/// 执行 engine 侧工具；非本层工具返回 None（交由 UI 侧处理）。
pub fn run_engine_tool(name: &str, _input: &Value) -> Option<Result<String, String>> {
    match name {
        "get_time" => Some(Ok(now_unix())),
        _ => None,
    }
}

fn now_unix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}
