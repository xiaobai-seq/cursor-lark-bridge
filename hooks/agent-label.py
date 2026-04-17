#!/usr/bin/env python3
"""
从 Cursor hook input (stdin JSON) 提取 Agent 标识，输出到 stdout。

Agent 标识用于在飞书卡片底部 note 区标识来源，方便用户在多 Cursor
窗口同时挂起审批/提问时区分是哪个会话发来的。

标识优先级：
1. 环境变量 FEISHU_BRIDGE_AGENT_LABEL（用户手动指定，完全覆盖）
2. 项目名 (workspace_roots[0] basename) + conversation_id 前 8 位
3. 只有其中一项时单独使用
4. 全部缺失时输出空串（daemon 侧空串不展示）

始终 exit 0，即便解析失败也不打断 hook。
"""

import json
import os
import sys


def main() -> int:
    override = os.environ.get("FEISHU_BRIDGE_AGENT_LABEL", "").strip()
    if override:
        sys.stdout.write(override)
        return 0

    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    if not isinstance(data, dict):
        return 0

    project = ""
    roots = data.get("workspace_roots")
    if isinstance(roots, list) and roots:
        first = str(roots[0] or "").rstrip("/")
        if first:
            project = os.path.basename(first)

    conv_id = str(data.get("conversation_id") or "").strip()
    short_id = conv_id[:8] if conv_id else ""

    parts = []
    if project:
        parts.append(project)
    if short_id:
        parts.append(f"#{short_id}")

    sys.stdout.write(" · ".join(parts))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
