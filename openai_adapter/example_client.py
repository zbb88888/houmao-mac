"""
OpenAI Adapter 客户端示例
演示如何使用 OpenAI SDK 调用 MiniCPM-o
"""
from openai import OpenAI
import base64

# 初始化客户端
client = OpenAI(
    api_key="your-api-key-here",  # 可选，用于会话管理
    base_url="http://localhost:8080/v1"  # 指向适配层
)

# ==================== 示例 1: 文本对话 ====================
print("=" * 60)
print("示例 1: 文本对话")
print("=" * 60)

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "你好，请介绍一下你自己"}
    ]
)

print(response.choices[0].message.content)

# ==================== 示例 2: 图像理解 ====================
print("\n" + "=" * 60)
print("示例 2: 图像理解")
print("=" * 60)

# 读取本地图片
with open("test_image.jpg", "rb") as f:
    image_data = base64.b64encode(f.read()).decode()

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "这张图片里有什么？"},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{image_data}"
                    }
                }
            ]
        }
    ]
)

print(response.choices[0].message.content)

# ==================== 示例 3: 流式响应 ====================
print("\n" + "=" * 60)
print("示例 3: 流式响应")
print("=" * 60)

stream = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "请讲一个短故事"}
    ],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)

print("\n")

# ==================== 示例 4: 多轮对话 ====================
print("\n" + "=" * 60)
print("示例 4: 多轮对话")
print("=" * 60)

messages = [
    {"role": "user", "content": "今天天气怎么样？"}
]

response1 = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages
)

print(f"User: {messages[0]['content']}")
print(f"AI: {response1.choices[0].message.content}")

# 继续对话
messages.append({"role": "assistant", "content": response1.choices[0].message.content})
messages.append({"role": "user", "content": "那适合出去玩吗？"})

response2 = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages
)

print(f"User: {messages[-1]['content']}")
print(f"AI: {response2.choices[0].message.content}")
