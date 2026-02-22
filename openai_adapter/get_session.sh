#!/bin/bash
# 从 MiniCPM-o Backend 获取当前 session 信息的辅助脚本

BACKEND_URL="http://localhost:8022"

echo "======================================"
echo "  MiniCPM-o Session 信息获取工具"
echo "======================================"
echo ""

# 检查 Backend 是否运行
if ! curl -s "$BACKEND_URL/health" > /dev/null 2>&1; then
    echo "❌ 错误：Backend 未运行 ($BACKEND_URL)"
    echo "   请先启动 MiniCPM-o 服务"
    exit 1
fi

echo "✅ Backend 正常运行"
echo ""

# 获取推理服务状态
echo "正在查询推理服务状态..."
services=$(curl -s "$BACKEND_URL/api/inference/services")

if [ -z "$services" ]; then
    echo "❌ 无法获取服务状态"
    exit 1
fi

# 解析 JSON（需要 jq）
if ! command -v jq &> /dev/null; then
    echo "⚠️  未安装 jq，显示原始 JSON："
    echo "$services" | python3 -m json.tool
    echo ""
    echo "📝 请手动从上面的 JSON 中提取："
    echo "   - locked_by (这是 userId)"
    echo "   - 注意：sessionId 需要从浏览器获取"
    exit 0
fi

# 使用 jq 解析
status=$(echo "$services" | jq -r '.services[0].status')
locked_by=$(echo "$services" | jq -r '.services[0].locked_by')

echo "服务状态: $status"
echo ""

if [ "$status" = "busy" ]; then
    echo "🔒 推理服务被占用（Frontend 正在使用）"
    echo ""
    echo "📋 当前 Session 信息："
    echo "   User ID: $locked_by"
    echo ""
    echo "⚠️  注意：无法直接获取完整的 sessionId"
    echo ""
    echo "📌 请按以下步骤获取完整信息："
    echo ""
    echo "1️⃣  打开浏览器访问: https://localhost:8088"
    echo "2️⃣  打开开发者工具 (F12)"
    echo "3️⃣  切换到 Network 标签"
    echo "4️⃣  在页面中登录/刷新"
    echo "5️⃣  找到 /api/login 请求"
    echo "6️⃣  查看响应，复制 sessionId"
    echo ""
    echo "然后设置环境变量："
    echo ""
    echo "  export MINICPM_USER_ID=\"$locked_by\""
    echo "  export MINICPM_SESSION_ID=\"<从浏览器复制的sessionId>\""
    echo ""
    echo "最后启动适配层："
    echo "  cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter"
    echo "  /Users/ftwhmg/v.v/bin/python main.py"
    echo ""

elif [ "$status" = "available" ]; then
    echo "✅ 推理服务空闲，可以直接使用"
    echo ""
    echo "💡 建议：直接启动适配层，它会自动创建 session"
    echo ""
    echo "  cd /Users/ftwhmg/houmao/houmao-mac/openai_adapter"
    echo "  /Users/ftwhmg/v.v/bin/python main.py"
    echo ""

else
    echo "⚠️  未知状态: $status"
fi

echo "======================================"
