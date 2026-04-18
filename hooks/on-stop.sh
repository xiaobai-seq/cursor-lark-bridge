#!/bin/bash
# stop hook: Agent 停止时，通过飞书发送暂停卡片并等待用户回复
# input: {"status": "completed"|"aborted"|"error", "loop_count": 0}
# output: {"followup_message": "..."} 或 {}
#
# 关键修复：Cursor stop hook 的 input 只有 status/loop_count，没有 transcript_path。
# 所以我们用 afterAgentResponse hook 把 Agent 最后输出缓存到 last-response.txt，
# 这里读缓存，再调用 daemon /stop 端点发飞书等回复。

DAEMON="http://127.0.0.1:19836"
CACHE_FILE="$HOME/.cursor/cursor-lark-bridge/last-response.txt"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# 提取 Agent 标识（暂停卡片底部展示），便于多会话并行时区分
AGENT_LABEL=$(echo "$input" | python3 "$HOOKS_DIR/agent-label.py" 2>/dev/null)

# 1. 远程模式未激活 → 直接放行，不打扰用户
mode=$(curl -s --connect-timeout 1 --max-time 2 "$DAEMON/mode" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$mode" ]; then
    echo '{}'
    exit 0
fi
active=$(echo "$mode" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
if [ "$active" != "True" ]; then
    echo '{}'
    exit 0
fi

# 2. 解析 stop hook input
status=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
loop_count=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('loop_count',0))" 2>/dev/null)

# aborted 状态说明用户主动取消，不打扰
if [ "$status" = "aborted" ]; then
    echo '{}'
    exit 0
fi

# 3. 读取 Agent 最后一次输出（由 afterAgentResponse hook 缓存）
summary=""
if [ -f "$CACHE_FILE" ]; then
    summary=$(cat "$CACHE_FILE" 2>/dev/null)
fi

# 无摘要也继续（比如 Agent 只调了工具没说话）—— 卡片会显示默认文案

# 从 stdin 抽 workspace（与其他 hook 保持一致；daemon 侧用它做 /status 展示）
WORKSPACE=$(echo "$input" | python3 -c "
import sys, json, os
try:
    d = json.load(sys.stdin)
    roots = d.get('workspace_roots') or []
    root_path = (roots[0] if roots else '') or ''
    root_path = root_path.rstrip('/')
    print(os.path.basename(root_path))
except Exception:
    pass
" 2>/dev/null)

# 4. 调用 daemon /stop 端点，发送暂停卡片并阻塞等回复
resp=$(STATUS="$status" LOOP_COUNT="$loop_count" SUMMARY="$summary" AGENT_LABEL="$AGENT_LABEL" WORKSPACE="$WORKSPACE" python3 <<'PYEOF'
import json, os, re, urllib.request, urllib.error, sys

# 脱敏：v1 的 on-stop summary 直接是 Agent 最后输出，未做脱敏。P2.1 之后这份 summary
# 既会进 daemon /status snapshot，也会被 buildStopCard 展示回飞书卡片——Agent 偶尔会
# 把 curl -H "Bearer ..." 之类的命令原文印到末段总结里，补一道防御性脱敏。
# 正则与 shell-approve / pretool-approve 同源，保证行为一致。
SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+',
    re.IGNORECASE,
)

raw_summary = os.environ.get("SUMMARY", "")
safe_summary = SENSITIVE.sub(r'\1***', raw_summary)

body = json.dumps({
    "status": os.environ.get("STATUS", ""),
    "loop_count": int(os.environ.get("LOOP_COUNT", "0") or 0),
    "summary": safe_summary,
    "agent": os.environ.get("AGENT_LABEL", ""),
    "kind": "stop",
    "workspace": os.environ.get("WORKSPACE", ""),
}).encode("utf-8")

req = urllib.request.Request(
    "http://127.0.0.1:19836/stop",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=600) as r:
        sys.stdout.write(r.read().decode("utf-8", errors="replace"))
except Exception:
    sys.stdout.write("")
PYEOF
)

# 5. 解析回复并决定是否注入 followup_message
if [ -z "$resp" ]; then
    echo '{}'
    exit 0
fi

echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    reply = (d.get('reply', '') or '').strip()
    # 空回复或显式 skip → 结束会话
    if not reply or reply.lower() == 'skip':
        print(json.dumps({}))
    else:
        print(json.dumps({'followup_message': reply}))
except Exception:
    print(json.dumps({}))
" 2>/dev/null || echo '{}'
