"""
简化的测试脚本 - 直接测试文本对话
"""
import asyncio
import httpx

async def test_text_chat():
    client = httpx.AsyncClient(timeout=60.0)

    # 1. 创建会话
    print("1. 创建会话...")
    login_resp = await client.post(
        "http://localhost:8022/api/login",
        json={
            "modelType": "duplex",
            "sessionType": "release",
            "serviceName": "o45-cpp"
        }
    )
    print(f"   响应状态: {login_resp.status_code}")
    login_data = login_resp.json()
    print(f"   响应数据: {login_data}")

    if not login_data.get("success"):
        print(f"   登录失败!")
        return

    print(f"   会话创建成功: {login_data['sessionId']}")

    # 2. 初始化会话
    print("\n2. 初始化会话...")
    init_resp = await client.post(
        "http://localhost:9060/omni/init_sys_prompt",
        json={
            "session_id": login_data["sessionId"],
            "system_prompt": "You are a helpful assistant.",
            "max_turns": 10
        }
    )
    print(f"   初始化状态: {init_resp.status_code}")

    # 3. 发送空 prefill（纯文本模式）
    print("\n3. 发送 Prefill...")
    prefill_resp = await client.post(
        "http://localhost:9060/omni/streaming_prefill",
        json={
            "session_id": login_data["sessionId"],
            "is_last_chunk": True
        }
    )
    print(f"   Prefill 状态: {prefill_resp.status_code}")
    if prefill_resp.status_code != 200:
        print(f"   错误: {prefill_resp.text}")

    # 4. Generate - 获取响应
    print("\n4. 生成响应...")
    async with client.stream(
        "POST",
        "http://localhost:9060/omni/streaming_generate",
        json={"session_id": login_data["sessionId"]}
    ) as resp:
        print(f"   Generate 状态: {resp.status_code}")
        if resp.status_code == 200:
            print("\n   AI 响应:")
            async for line in resp.aiter_lines():
                if line and line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        import json
                        data = json.loads(data_str)
                        if data.get("type") == "text":
                            print(f"   {data.get('content', '')}", end="", flush=True)
                    except:
                        pass
            print()  # 换行

    # 5. 清理
    print("\n5. 清理会话...")
    await client.post(
        "http://localhost:8022/api/logout",
        json={"userId": login_data["userId"]}
    )
    print("   完成!")

    await client.aclose()

if __name__ == "__main__":
    asyncio.run(test_text_chat())
