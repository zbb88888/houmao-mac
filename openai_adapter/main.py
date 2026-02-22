"""
OpenAI 兼容适配层 - MiniCPM-o 4.5
透明代理，将 OpenAI API 请求直接转发到 llama-server
"""
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse
import httpx

# ==================== 配置 ====================

LLAMA_SERVER_URL = "http://localhost:19060"
TIMEOUT = 300.0

# ==================== FastAPI 应用 ====================

http_client: httpx.AsyncClient

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient(timeout=TIMEOUT)
    yield
    await http_client.aclose()

app = FastAPI(
    title="OpenAI Adapter for MiniCPM-o",
    version="1.0.0",
    lifespan=lifespan
)

# ==================== API 端点 ====================

@app.get("/")
def root():
    return {
        "service": "OpenAI Adapter for MiniCPM-o 4.5",
        "version": "1.0.0",
        "status": "running"
    }

@app.get("/v1/models")
def list_models():
    return {
        "object": "list",
        "data": [{
            "id": "minicpm-o-4.5",
            "object": "model",
            "created": 1704067200,
            "owned_by": "openbmb"
        }]
    }

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """透明代理 - 转发所有 OpenAI 兼容参数到 llama-server"""
    try:
        body = await request.json()
        body["model"] = "MiniCPM-o-4.5"

        if body.get("stream"):
            return StreamingResponse(
                stream_response(body),
                media_type="text/event-stream"
            )

        resp = await http_client.post(
            f"{LLAMA_SERVER_URL}/v1/chat/completions",
            json=body
        )
        resp.raise_for_status()
        return resp.json()

    except httpx.HTTPError as e:
        raise HTTPException(status_code=503, detail=f"llama-server 错误: {e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"请求失败: {e}")

async def stream_response(payload: dict):
    """流式透传 - 原样转发 SSE 字节流"""
    async with http_client.stream(
        "POST",
        f"{LLAMA_SERVER_URL}/v1/chat/completions",
        json=payload
    ) as resp:
        resp.raise_for_status()
        async for chunk in resp.aiter_bytes():
            yield chunk

@app.get("/health")
async def health():
    try:
        resp = await http_client.get(f"{LLAMA_SERVER_URL}/health", timeout=5.0)
        ok = resp.status_code == 200
        return {
            "status": "healthy" if ok else "unhealthy",
            "llama_server": "healthy" if ok else "unhealthy"
        }
    except Exception as e:
        return {
            "status": "unhealthy",
            "llama_server": "unreachable",
            "error": str(e)
        }

# ==================== 启动 ====================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
