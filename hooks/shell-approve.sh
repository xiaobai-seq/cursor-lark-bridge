#!/bin/bash
# beforeShellExecution hook: 拦截 shell 命令，通过飞书远程审批
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# 提取 Agent 标识（项目名 · #短id），供多会话并行时区分来源
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL

# 提取命令，跳过不需要审批的安全命令
command=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command',''))" 2>/dev/null)
case "$command" in
    curl*127.0.0.1:19836*|curl*localhost:19836*|fb\ *|*cursor-lark-bridge/bridge.sh*|*lark-cli*|cat\ *|tail\ *|head\ *|ls\ *|echo\ *|which\ *|pwd|whoami)
        echo '{"permission":"allow"}'
        exit 0
        ;;
esac

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
cmd = d.get('command', '')
cwd = d.get('cwd', '')
safe_cmd = re.sub(r'(password|token|secret|key)=[^\s]*', r'\1=***', cmd, flags=re.IGNORECASE)
print(json.dumps({
    'type': 'shell',
    'title': '🖥️ Shell 命令待授权',
    'content': f'**命令**\n\`\`\`\n{safe_cmd}\n\`\`\`\n**目录** \`{cwd}\`',
    'context': 'Shell 命令执行',
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
if decision == 'deny':
    print(json.dumps({
        'permission': 'deny',
        'user_message': '飞书远程审批：已拒绝',
        'agent_message': '用户通过飞书远程拒绝了此命令的执行。请考虑替代方案或跳过此步骤。'
    }))
else:
    print(json.dumps({'permission': 'allow'}))
" 2>/dev/null || echo '{"permission":"allow"}'
