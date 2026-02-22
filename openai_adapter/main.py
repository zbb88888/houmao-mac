"""
OpenAI 兼容适配层 - MiniCPM-o 4.5
将 OpenAI API 格式转换为 MiniCPM-o WebRTC Backend 格式
"""
import base64
import uuid
import time
import os
from typing import Optional, List, Dict, Any, AsyncGenerator
from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
import httpx
import json
import asyncio
from datetime import datetime

# ==================== 配置 ====================
BACKEND_URL = "http://localhost:8022"  # MiniCPM-o Backend (端口被占用，自动改为 8022)
CPP_SERVER_URL = "http://localhost:9060"  # C++ 推理服务（WebRTC 封装层）
LLAMA_SERVER_URL = "http://localhost:19060"  # llama-server 原生接口（用于文本对话）⭐

# 可选：手动配置 session（用于复用 Frontend 的 session）
MANUAL_SESSION_ID = os.environ.get("MINICPM_SESSION_ID")  # 从环境变量读取
MANUAL_USER_ID = os.environ.get("MINICPM_USER_ID")
MANUAL_TOKEN = os.environ.get("MINICPM_TOKEN")

# ==================== OpenAI 请求/响应模型 ====================

class ChatMessage(BaseModel):
    role: str
    content: str | List[Dict[str, Any]]

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 1024
    stream: Optional[bool] = False
    stop: Optional[List[str]] = None

class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[Dict[str, Any]]
    usage: Dict[str, int]

# ==================== FastAPI 应用 ====================

app = FastAPI(
    title="OpenAI Adapter for MiniCPM-o",
    description="OpenAI 兼容接口适配层",
    version="1.0.0"
)

# HTTP 客户端
http_client = httpx.AsyncClient(timeout=300.0)

# ==================== 会话管理 ====================

active_sessions: Dict[str, Dict] = {}

async def get_or_create_session(api_key: str = "default") -> Dict:
    """获取或创建会话

    优先级：
    1. 如果有手动配置的 session，使用配置的 session
    2. 如果有缓存的 session 且未过期，使用缓存
    3. 否则创建新 session
    """

    # 方式 1：使用手动配置的 session（从环境变量）
    if MANUAL_SESSION_ID and MANUAL_USER_ID:
        print(f"使用手动配置的 session: {MANUAL_SESSION_ID}")
        return {
            "userId": MANUAL_USER_ID,
            "sessionId": MANUAL_SESSION_ID,
            "token": MANUAL_TOKEN or "",
            "created_at": time.time(),
            "manual": True  # 标记为手动配置
        }

    # 方式 2：复用缓存的 session
    if api_key in active_sessions:
        session = active_sessions[api_key]
        # 检查会话是否过期（超过10分钟）
        if time.time() - session.get("created_at", 0) < 600:
            print(f"复用缓存的 session: {session['sessionId']}")
            return session

    # 方式 3：尝试发现已存在的 busy session（Frontend 创建的）
    try:
        print("检查是否有已存在的 busy session...")
        services_resp = await http_client.get(
            f"{BACKEND_URL}/api/inference/services",
            timeout=5.0
        )
        if services_resp.status_code == 200:
            services = services_resp.json().get("services", [])
            busy_services = [s for s in services if s.get("status") == "busy"]

            if busy_services:
                busy = busy_services[0]
                locked_by = busy.get("locked_by")
                print(f"发现已存在的 busy session，locked_by: {locked_by}")
                print(f"⚠️  警告：无法获取完整 session 信息，需要手动配置或等待服务释放")
                print(f"    可以设置环境变量:")
                print(f"    export MINICPM_USER_ID=\"{locked_by}\"")
                print(f"    export MINICPM_SESSION_ID=\"<session_id>\"")
                # 不阻塞，继续尝试创建新 session（会失败，但提示更清楚）
    except Exception as e:
        print(f"检查 busy session 失败: {e}")

    # 方式 4：创建新 session
    try:
        print(f"创建新会话...")
        response = await http_client.post(
            f"{BACKEND_URL}/api/login",
            json={
                "modelType": "duplex",
                "sessionType": "release",
                "serviceName": "o45-cpp"
            },
            timeout=10.0
        )
        print(f"Login 响应状态: {response.status_code}")

        if response.status_code != 200:
            error_detail = response.text
            raise HTTPException(
                status_code=503,
                detail=f"无法创建会话 (状态码 {response.status_code}): {error_detail}"
            )

        response.raise_for_status()
        data = response.json()
        print(f"Login 响应数据: success={data.get('success')}")

        if not data.get("success"):
            raise HTTPException(status_code=503, detail="无法创建会话")

        session = {
            "userId": data["userId"],
            "sessionId": data["sessionId"],
            "token": data["token"],
            "created_at": time.time(),
            "manual": False
        }

        active_sessions[api_key] = session

        # 初始化 C++ 服务的系统提示
        try:
            print(f"初始化 C++ 会话: {session['sessionId']}")
            init_resp = await http_client.post(
                f"{CPP_SERVER_URL}/omni/init_sys_prompt",
                json={
                    "session_id": session["sessionId"],
                    "system_prompt": "You are a helpful AI assistant.",
                    "max_turns": 10
                },
                timeout=30.0
            )
            print(f"Init 响应状态: {init_resp.status_code}")
            init_resp.raise_for_status()
            print(f"✅ 会话初始化成功: {session['sessionId']}")
        except Exception as init_error:
            # 初始化失败，清理会话
            print(f"❌ 会话初始化失败: {init_error}")
            try:
                await http_client.post(
                    f"{BACKEND_URL}/api/logout",
                    json={"userId": session["userId"], "token": session["token"]}
                )
            except:
                pass
            raise HTTPException(status_code=503, detail=f"会话初始化失败: {str(init_error)}")

        return session

    except HTTPException:
        raise
    except Exception as e:
        print(f"会话创建异常: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=503, detail=f"会话创建失败: {str(e)}")

async def cleanup_session(api_key: str):
    """清理会话"""
    if api_key not in active_sessions:
        return

    session = active_sessions[api_key]

    # 如果是手动配置的 session，不要清理
    if session.get("manual"):
        print("跳过清理手动配置的 session")
        return

    try:
        await http_client.post(
            f"{BACKEND_URL}/api/logout",
            json={"userId": session["userId"], "token": session.get("token", "")}
        )
    except:
        pass

    del active_sessions[api_key]

# ==================== 工具函数 ====================

def extract_text_and_media(content: str | List[Dict]) -> tuple[str, Optional[str], Optional[str]]:
    """从 OpenAI 格式的 content 中提取文本和媒体

    Returns:
        (text, image_base64, audio_base64)
    """
    text_parts = []
    image_b64 = None
    audio_b64 = None

    if isinstance(content, str):
        return content, None, None

    for item in content:
        if item.get("type") == "text":
            text_parts.append(item.get("text", ""))

        elif item.get("type") == "image_url":
            url = item.get("image_url", {}).get("url", "")
            # 支持 data:image/xxx;base64,... 格式
            if url.startswith("data:image"):
                image_b64 = url.split(",", 1)[1] if "," in url else url
            else:
                # TODO: 支持 HTTP URL（需要下载图片）
                pass

        elif item.get("type") == "audio_url":
            url = item.get("audio_url", {}).get("url", "")
            if url.startswith("data:audio"):
                audio_b64 = url.split(",", 1)[1] if "," in url else url

    text = " ".join(text_parts)
    return text, image_b64, audio_b64

async def call_cpp_inference(
    session: Dict,
    text: str,
    image_b64: Optional[str] = None,
    audio_b64: Optional[str] = None,
    stream: bool = False
) -> AsyncGenerator[str, None] | Dict:
    """调用 C++ 推理服务"""

    # 1. Prefill - 提交用户输入
    prefill_payload = {
        "session_id": session["sessionId"],
        "is_last_chunk": True
    }

    if image_b64:
        prefill_payload["image"] = image_b64
    if audio_b64:
        prefill_payload["audio"] = audio_b64

    print(f"发送 Prefill 请求: session_id={session['sessionId']}, has_image={bool(image_b64)}, has_audio={bool(audio_b64)}")

    try:
        prefill_resp = await http_client.post(
            f"{CPP_SERVER_URL}/omni/streaming_prefill",
            json=prefill_payload,
            timeout=60.0
        )
        print(f"Prefill 响应状态: {prefill_resp.status_code}")
        prefill_resp.raise_for_status()
    except Exception as e:
        print(f"Prefill 失败: {e}")
        raise HTTPException(status_code=500, detail=f"Prefill 失败: {str(e)}")

    # 2. Generate - 生成响应
    generate_payload = {
        "session_id": session["sessionId"]
    }

    if stream:
        # 流式响应
        async def stream_generator():
            try:
                async with http_client.stream(
                    "POST",
                    f"{CPP_SERVER_URL}/omni/streaming_generate",
                    json=generate_payload
                ) as resp:
                    resp.raise_for_status()
                    async for line in resp.aiter_lines():
                        if not line or not line.startswith("data: "):
                            continue

                        data_str = line[6:]  # 去掉 "data: "
                        if data_str == "[DONE]":
                            break

                        try:
                            data = json.loads(data_str)
                            # 只返回文本内容
                            if data.get("type") == "text":
                                yield data.get("content", "")
                        except json.JSONDecodeError:
                            continue

            except Exception as e:
                print(f"流式生成错误: {e}")

        return stream_generator()

    else:
        # 非流式响应 - 收集所有内容
        full_text = ""
        try:
            async with http_client.stream(
                "POST",
                f"{CPP_SERVER_URL}/omni/streaming_generate",
                json=generate_payload
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line or not line.startswith("data: "):
                        continue

                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break

                    try:
                        data = json.loads(data_str)
                        if data.get("type") == "text":
                            full_text += data.get("content", "")
                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Generate 失败: {str(e)}")

        return {"text": full_text}

# ==================== OpenAI API 端点 ====================

@app.get("/")
async def root():
    return {
        "message": "OpenAI Adapter for MiniCPM-o",
        "version": "1.0.0",
        "backend": BACKEND_URL,
        "cpp_server": CPP_SERVER_URL
    }

@app.get("/v1/models")
async def list_models():
    """列出可用模型"""
    return {
        "object": "list",
        "data": [
            {
                "id": "minicpm-o-4.5",
                "object": "model",
                "created": 1704067200,
                "owned_by": "openbmb"
            }
        ]
    }

@app.post("/v1/chat/completions")
async def chat_completions(
    request: ChatCompletionRequest,
    authorization: Optional[str] = Header(None)
):
    """OpenAI 兼容的聊天补全接口

    直接代理到 llama-server 的原生接口
    """

    # 直接转发到 llama-server
    try:
        # 构建请求数据
        llama_request = {
            "model": "MiniCPM-o-4.5",
            "messages": [{"role": msg.role, "content": msg.content} for msg in request.messages],
            "max_tokens": request.max_tokens or 1024,
            "temperature": request.temperature or 0.7,
            "stream": request.stream or False
        }

        if request.stop:
            llama_request["stop"] = request.stop

        print(f"转发请求到 llama-server: messages={len(request.messages)}, stream={request.stream}")

        if request.stream:
            # 流式响应 - 直接代理
            async def proxy_stream():
                async with http_client.stream(
                    "POST",
                    f"{LLAMA_SERVER_URL}/v1/chat/completions",
                    json=llama_request,
                    timeout=300.0
                ) as resp:
                    resp.raise_for_status()
                    async for line in resp.aiter_lines():
                        if line:
                            yield f"{line}\n"

            return StreamingResponse(
                proxy_stream(),
                media_type="text/event-stream"
            )

        else:
            # 非流式响应
            response = await http_client.post(
                f"{LLAMA_SERVER_URL}/v1/chat/completions",
                json=llama_request,
                timeout=300.0
            )
            response.raise_for_status()
            return response.json()

    except Exception as e:
        print(f"请求失败: {e}")
        raise HTTPException(status_code=500, detail=f"请求失败: {str(e)}")

@app.get("/health")
async def health_check():
    """健康检查"""
    try:
        # 检查 llama-server
        llama_resp = await http_client.get(f"{LLAMA_SERVER_URL}/health", timeout=5.0)
        llama_healthy = llama_resp.status_code == 200

        return {
            "status": "healthy" if llama_healthy else "unhealthy",
            "llama_server": "healthy" if llama_healthy else "unhealthy",
            "llama_server_url": LLAMA_SERVER_URL
        }
    except Exception as e:
        return {
            "status": "unhealthy",
            "error": str(e)
        }

# ==================== 生命周期 ====================

@app.on_event("shutdown")
async def shutdown():
    """关闭时清理资源"""
    await http_client.aclose()
    # 清理所有会话
    for api_key in list(active_sessions.keys()):
        await cleanup_session(api_key)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
