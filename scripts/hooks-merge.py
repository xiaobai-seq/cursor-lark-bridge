#!/usr/bin/env python3
"""Merge cursor-lark-bridge hook entries into the user's ~/.cursor/hooks.json.

Safety contract:
  * Existing hooks.json is always backed up before --apply.
  * User's own entries (non cursor-lark-bridge) are preserved as-is.
  * Pre-existing cursor-lark-bridge entries (detected by path marker) are
    replaced, not duplicated, so re-running is idempotent.
  * Supports Cursor hook schema where hooks live under top-level "hooks" key
    (new format), and also flat {event: [entries]} (older format).

Modes:
  --dry-run     print merged JSON to stdout
  --show-diff   print unified diff (colored when stdout is a TTY)
  --apply       overwrite file (with timestamped backup)
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import shutil
import sys
from typing import Any, Dict, List

# Any entry whose command contains this marker is considered "ours" and is safe
# to drop/replace on re-install. Keep in sync with hooks-additions.json paths.
CLB_MARKER = "hooks/cursor-lark-bridge/"

HOOK_EVENTS = (
    "beforeShellExecution",
    "beforeMCPExecution",
    "preToolUse",
    "afterAgentResponse",
    "stop",
)


def is_clb_entry(entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    return CLB_MARKER in str(entry.get("command", ""))


def _ensure_list(value: Any) -> List[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return list(value)
    return [value]


def _has_new_schema(doc: Dict[str, Any]) -> bool:
    """Detect whether the file uses the newer {"hooks": {...}} wrapper."""
    if "hooks" in doc and isinstance(doc["hooks"], dict):
        return True
    # If we see top-level event keys, it's the older flat schema.
    for k in HOOK_EVENTS:
        if k in doc:
            return False
    # Empty file — default to new schema to produce valid output.
    return True


def merge(existing: Dict[str, Any], additions: Dict[str, Any]) -> Dict[str, Any]:
    """Return a new dict that merges `additions` into `existing` non-destructively."""
    existing = existing or {}
    new_schema = _has_new_schema(existing)

    if new_schema:
        merged: Dict[str, Any] = {
            k: (list(v) if isinstance(v, list) else v) for k, v in existing.items()
        }
        merged.setdefault("version", 1)
        inner = merged.get("hooks")
        if not isinstance(inner, dict):
            inner = {}
        merged["hooks"] = _merge_events(inner, additions)
        return merged

    # Flat schema: events live at the top level.
    merged = {k: (list(v) if isinstance(v, list) else v) for k, v in existing.items()}
    return _merge_events(merged, additions)


def _merge_events(
    target: Dict[str, Any], additions: Dict[str, Any]
) -> Dict[str, Any]:
    merged = dict(target)
    for event, entries in additions.items():
        entries = _ensure_list(entries)
        current = _ensure_list(merged.get(event))
        # Strip out any previously installed CLB entries so re-runs are idempotent.
        current = [e for e in current if not is_clb_entry(e)]
        current.extend(entries)
        merged[event] = current
    return merged


def _format_json(doc: Any) -> str:
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def _colored_diff(before: Any, after: Any, use_color: bool) -> str:
    a_lines = _format_json(before).splitlines(keepends=True)
    b_lines = _format_json(after).splitlines(keepends=True)
    diff = list(
        difflib.unified_diff(a_lines, b_lines, fromfile="before", tofile="after")
    )
    if not diff:
        return "  (no changes — already installed)\n"
    if not use_color:
        return "".join(diff)
    out = []
    for line in diff:
        if line.startswith("+") and not line.startswith("+++"):
            out.append(f"\033[32m{line}\033[0m")
        elif line.startswith("-") and not line.startswith("---"):
            out.append(f"\033[31m{line}\033[0m")
        elif line.startswith("@@"):
            out.append(f"\033[36m{line}\033[0m")
        else:
            out.append(line)
    return "".join(out)


def _load_json(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        return {}
    return json.loads(text)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--existing", required=True, help="path to ~/.cursor/hooks.json")
    p.add_argument(
        "--additions", required=True, help="path to the hooks-additions.json template"
    )
    p.add_argument(
        "--backup-suffix",
        required=True,
        help="timestamp-like suffix for backup file (e.g. 2026-04-17-120000)",
    )
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="print merged JSON")
    mode.add_argument("--show-diff", action="store_true", help="print unified diff")
    mode.add_argument("--apply", action="store_true", help="overwrite existing file")
    args = p.parse_args()

    existing = _load_json(args.existing)
    additions = _load_json(args.additions)
    if not additions:
        print("error: additions file is empty", file=sys.stderr)
        return 2

    merged = merge(existing, additions)

    if args.dry_run:
        sys.stdout.write(_format_json(merged))
        return 0

    if args.show_diff:
        sys.stdout.write(_colored_diff(existing, merged, sys.stdout.isatty()))
        return 0

    # --apply
    os.makedirs(os.path.dirname(args.existing) or ".", exist_ok=True)
    if os.path.exists(args.existing):
        backup = f"{args.existing}.bak.{args.backup_suffix}"
        shutil.copy(args.existing, backup)
        print(f"  \u2713 backed up existing hooks.json \u2192 {backup}")
    with open(args.existing, "w", encoding="utf-8") as f:
        f.write(_format_json(merged))
    print(f"  \u2713 hooks merged into {args.existing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
