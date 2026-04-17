#!/bin/bash
# preToolUse hook: 拦截 AskQuestion 和 SwitchMode 工具调用
DAEMON="http://127.0.0.1:19836"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# 提取 Agent 标识，用于多会话并行时区分来源
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)
export AGENT_LABEL

mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo '{}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{}'
    exit 0
fi

echo "$input" | python3 -c "
import sys, json, os

DAEMON = 'http://127.0.0.1:19836'
AGENT = os.environ.get('AGENT_LABEL', '')

d = json.load(sys.stdin)
tool_name = d.get('tool_name', '')
tool_input = d.get('tool_input', {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except:
        tool_input = {}

def curl_post(endpoint, data):
    import urllib.request
    req = urllib.request.Request(
        DAEMON + endpoint,
        data=json.dumps(data).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return json.loads(resp.read())
    except Exception:
        return None

if tool_name == 'AskQuestion':
    questions = tool_input.get('questions', [])
    parts = []
    options_all = []
    for q in questions:
        parts.append(q.get('prompt', ''))
        for o in q.get('options', []):
            options_all.append(o.get('label', ''))

    question_text = ' | '.join(parts) if parts else '需要您做选择'
    resp = curl_post('/ask', {
        'question': question_text,
        'options': options_all,
        'context': 'AskQuestion 交互',
        'agent': AGENT,
    })
    if resp and resp.get('reply'):
        reply = resp['reply']
        print(json.dumps({
            'permission': 'deny',
            'user_message': f'飞书远程回复: {reply}',
            'agent_message': f'用户通过飞书远程回复了此问题，答案是: {reply}。请根据此回复继续工作，不需要再次提问。'
        }))
    else:
        print(json.dumps({}))

elif tool_name == 'SwitchMode':
    target_mode = tool_input.get('target_mode_id', '')
    explanation = tool_input.get('explanation', '')
    resp = curl_post('/approve', {
        'type': 'mode_switch',
        'title': '🔄 模式切换请求',
        'content': f'**目标模式** \`{target_mode}\`\n**说明** {explanation}',
        'context': '模式切换',
        'agent': AGENT,
    })
    if resp and resp.get('decision') == 'deny':
        print(json.dumps({
            'permission': 'deny',
            'user_message': '飞书远程审批：拒绝模式切换',
            'agent_message': f'用户通过飞书拒绝了切换到 {target_mode} 模式。请在当前模式下继续工作。'
        }))
    else:
        print(json.dumps({'permission': 'allow'}))
else:
    print(json.dumps({}))
" 2>/dev/null || echo '{}'
