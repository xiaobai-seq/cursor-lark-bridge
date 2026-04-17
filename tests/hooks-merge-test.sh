#!/usr/bin/env bash
# End-to-end smoke test for scripts/hooks-merge.py
# Verifies: user hooks preserved, CLB hooks added, idempotent on re-apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

EXISTING="$TMP/hooks.json"
ADDITIONS="$REPO_ROOT/config/hooks-additions.json"
MERGER="$REPO_ROOT/scripts/hooks-merge.py"

# ── Case 1: new file + additions
python3 "$MERGER" --existing "$EXISTING" --additions "$ADDITIONS" \
    --backup-suffix case1 --apply >/dev/null
python3 - <<PY
import json, sys
d = json.load(open("$EXISTING"))
assert d["version"] == 1, "version must be 1"
shell = d["hooks"]["beforeShellExecution"]
assert any("cursor-lark-bridge" in e["command"] for e in shell), "CLB entry missing"
stop = d["hooks"]["stop"]
assert any(e.get("loop_limit") == 20 for e in stop), "stop loop_limit not preserved"
print("OK case1: new file")
PY

# ── Case 2: preserve user's own hooks
cat > "$EXISTING" <<'J'
{"version":1,"hooks":{"beforeShellExecution":[{"command":"bash ./my/own.sh","timeout":60}]}}
J
python3 "$MERGER" --existing "$EXISTING" --additions "$ADDITIONS" \
    --backup-suffix case2 --apply >/dev/null
python3 - <<PY
import json
d = json.load(open("$EXISTING"))
shell = d["hooks"]["beforeShellExecution"]
assert any("my/own.sh" in e["command"] for e in shell), "user hook lost!"
assert any("cursor-lark-bridge" in e["command"] for e in shell), "CLB hook not added"
print("OK case2: user hook preserved")
PY

# ── Case 3: idempotent
python3 "$MERGER" --existing "$EXISTING" --additions "$ADDITIONS" \
    --backup-suffix case3 --apply >/dev/null
python3 - <<PY
import json
d = json.load(open("$EXISTING"))
shell = d["hooks"]["beforeShellExecution"]
clb = [e for e in shell if "cursor-lark-bridge" in e["command"]]
assert len(clb) == 1, f"expected 1 CLB entry after re-apply, got {len(clb)}"
print("OK case3: idempotent")
PY

# ── Case 4: legacy flat schema
cat > "$EXISTING" <<'J'
{"beforeShellExecution":[{"command":"bash ./legacy.sh","timeout":30}]}
J
python3 "$MERGER" --existing "$EXISTING" --additions "$ADDITIONS" \
    --backup-suffix case4 --apply >/dev/null
python3 - <<PY
import json
d = json.load(open("$EXISTING"))
# flat schema preserved
shell = d["beforeShellExecution"]
assert any("legacy.sh" in e["command"] for e in shell), "legacy hook lost"
assert any("cursor-lark-bridge" in e["command"] for e in shell), "CLB hook not added to flat schema"
print("OK case4: legacy flat schema supported")
PY

echo ""
echo "All hooks-merge test cases passed."
