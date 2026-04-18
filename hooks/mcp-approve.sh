#!/bin/bash
# beforeMCPExecution hook: 拦截 MCP 工具调用，通过飞书远程审批
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# 提取 Agent 标识，用于多会话并行时区分来源
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL

mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo '{"permission":"allow"}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi

body=$(echo "$input" | python3 -c "
import sys, json, os, re
d = json.load(sys.stdin)
tool_name = d.get('tool_name', '')
tool_input = d.get('tool_input', '{}')

# workspace 提取（与其他 hook 一致）
roots = d.get('workspace_roots') or []
root_path = (roots[0] if roots else '') or ''
root_path = root_path.rstrip('/')
workspace = os.path.basename(root_path)

# 脱敏：JSON 场景（含引号）覆盖 api_key / password / token / secret / bearer。
# 注意：本正则刻意不收录单独的 "key"——JSON 里 "key": "value" 在 MCP 工具参数里太常见
# （如用户主键、issue 标识、字段名、排序键），误伤率远超保护价值。真正的敏感字段通常叫
# api_key / api-key / api key，已由 api[_-]?key 模式覆盖。若未来发现误露凭据，优先在
# Agent 层或此处单独收紧，而不是在这里放开 "key"。该决策在 P2.2 rework 时由 Planner 裁定。
SENSITIVE = re.compile(r'((?:api[_-]?key|password|token|secret|bearer)[\"\s:=]+)\"?[^\"\s,\}]+', re.IGNORECASE)
if isinstance(tool_input, dict):
    ti_str = json.dumps(tool_input, ensure_ascii=False)
else:
    ti_str = str(tool_input)
ti_str = SENSITIVE.sub(r'\1***', ti_str)[:500]

# summary：仅用工具名即可（tool_input 可能含敏感信息，不放 summary）
summary = tool_name[:80]

print(json.dumps({
    'type': 'mcp',
    'kind': 'mcp',
    'title': '🔧 MCP 工具调用待授权',
    'content': f'**工具** \`{tool_name}\`\n**参数摘要**\n\`\`\`\n{ti_str}\n\`\`\`',
    'context': 'MCP 工具调用',
    'summary': summary,
    'workspace': workspace,
    'agent': os.environ.get('AGENT_LABEL', ''),
}))
" 2>/dev/null)

if [ -z "$body" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi

resp=$(curl -s --max-time 600 -X POST "$DAEMON/approve" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$resp" ]; then
    echo '{"permission":"allow"}'
    exit 0
fi

echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
decision = d.get('decision', 'allow')
tool_name = '$( echo "$input" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\"tool_name\",\"\"))" 2>/dev/null )'
if decision == 'deny':
    print(json.dumps({
        'permission': 'deny',
        'user_message': '飞书远程审批：已拒绝此 MCP 调用',
        'agent_message': f'用户通过飞书远程拒绝了 MCP 工具 {tool_name} 的调用。请考虑替代方案。'
    }))
else:
    print(json.dumps({'permission': 'allow'}))
" 2>/dev/null || echo '{"permission":"allow"}'
