#!/bin/bash
# afterAgentResponse hook: 缓存 Agent 最后一次输出的文本，供 stop hook 使用
# input: {"text": "<assistant final text>"}

CACHE_DIR="$HOME/.cursor/cursor-lark-bridge"
CACHE_FILE="$CACHE_DIR/last-response.txt"

mkdir -p "$CACHE_DIR"

# 将 Agent 的最新输出写入缓存文件；失败静默，不阻断 Agent 执行
CACHE_FILE="$CACHE_FILE" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
    text = (d.get("text", "") or "").strip()
    if text:
        with open(os.environ["CACHE_FILE"], "w", encoding="utf-8") as f:
            f.write(text)
except Exception:
    pass
' 2>/dev/null

echo '{}'
