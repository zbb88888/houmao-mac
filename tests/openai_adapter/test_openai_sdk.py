"""
OpenAI SDK Test Examples
"""
from openai import OpenAI

# Initialize client
client = OpenAI(
    api_key="not-needed",  # No API key required
    base_url="http://localhost:8080/v1"
)

print("=" * 60)
print("Test 1: Simple Conversation")
print("=" * 60)

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "Hello, please introduce yourself in one sentence"}
    ]
)

print(f"AI: {response.choices[0].message.content}")
print(f"Token usage: {response.usage.total_tokens}")

print("\n" + "=" * 60)
print("Test 2: Streaming Response")
print("=" * 60)

stream = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=[
        {"role": "user", "content": "Tell me a short story in 30 words or less"}
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
print("Test 3: Multi-turn Conversation")
print("=" * 60)

messages = [
    {"role": "user", "content": "Please recommend a science fiction novel"}
]

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages,
    max_tokens=100
)

print(f"User: {messages[0]['content']}")
print(f"AI: {response.choices[0].message.content}")

# Continue conversation
messages.append({"role": "assistant", "content": response.choices[0].message.content})
messages.append({"role": "user", "content": "Why do you recommend this book?"})

response = client.chat.completions.create(
    model="minicpm-o-4.5",
    messages=messages,
    max_tokens=100
)

print(f"\nUser: {messages[-1]['content']}")
print(f"AI: {response.choices[0].message.content}")

print("\n" + "=" * 60)
print("✅ All tests passed!")
print("=" * 60)
