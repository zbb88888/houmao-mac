"""
OpenAI SDK 测试示例
"""
from openai import OpenAI

# 初始化客户端
client = OpenAI(
    api_key="not-needed",  # 不需要 API key
    base_url="http://localhost:8080/v1"
)

print("=" * 60)
print("测试 1: 简单对话")
print("=" * 60)

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "你好，请用一句话介绍你自己"}
    ]
)

print(f"AI: {response.choices[0].message.content}")
print(f"Token 使用: {response.usage.total_tokens}")

print("\n" + "=" * 60)
print("测试 2: 流式响应")
print("=" * 60)

stream = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "讲一个30字以内的小故事"}
    ],
    stream=True,
    max_tokens=50
)

print("AI: ", end="", flush=True)
for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print("\n")

print("=" * 60)
print("测试 3: 多轮对话")
print("=" * 60)

messages = [
    {"role": "user", "content": "请推荐一本科幻小说"}
]

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages,
    max_tokens=100
)

print(f"User: {messages[0]['content']}")
print(f"AI: {response.choices[0].message.content}")

# 继续对话
messages.append({"role": "assistant", "content": response.choices[0].message.content})
messages.append({"role": "user", "content": "为什么推荐这本书？"})

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages,
    max_tokens=100
)

print(f"\nUser: {messages[-1]['content']}")
print(f"AI: {response.choices[0].message.content}")

print("\n" + "=" * 60)
print("✅ 所有测试通过！")
print("=" * 60)
