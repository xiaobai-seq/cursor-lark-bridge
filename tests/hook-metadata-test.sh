#!/usr/bin/env bash
# 确保 4 个 hook 脚本补发了 kind / summary / workspace 给 daemon，
# 并保证脱敏正则与 workspace 抽取在所有 hook 里行为一致。
#
# 为什么不真调 daemon：
#   hook 末端是 curl POST，测试不依赖 daemon 在线；
#   这里只覆盖 "构造 body 的纯逻辑"：脱敏正则、workspace 抽取、字段存在性。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/hooks"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

echo "=== hook-metadata-test ==="

# ──────────────────────────────────────────────────────────────
# 1. shell 场景脱敏正则（shell-approve.sh / pretool-approve.sh 共用）
# ──────────────────────────────────────────────────────────────
python3 <<'PYEOF' || fail "shell 脱敏正则失败"
import re

SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+',
    re.IGNORECASE,
)

cases = [
    ('password=secret123',          'password=***'),
    ('API_KEY=abcdef',              'API_KEY=***'),
    ('Bearer foobar',               'Bearer ***'),
    ('token: xyz',                  'token: ***'),
    ('normal command',              'normal command'),  # 不命中
    ('--password my_pw xx',         '--password *** xx'),  # 行内 kv
    ('api-key = kVal',              'api-key = ***'),
]
for inp, want in cases:
    got = SENSITIVE.sub(r'\1***', inp)
    assert got == want, f"case {inp!r}: want {want!r}, got {got!r}"
print(f"shell 脱敏正则通过 {len(cases)} 个用例")
PYEOF
pass "shell 脱敏正则（shell-approve / pretool-approve）"

# ──────────────────────────────────────────────────────────────
# 2. JSON 场景脱敏正则（mcp-approve.sh 使用）
# ──────────────────────────────────────────────────────────────
python3 <<'PYEOF' || fail "JSON 脱敏正则失败"
import re, json

SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|bearer)["\s:=]+)"?[^"\s,\}]+',
    re.IGNORECASE,
)

payload = json.dumps({
    "api_key": "abcdef",
    "password": "my_secret",
    "normal_field": "hello",
    "nested_token": "xyz",
})
out = SENSITIVE.sub(r'\1***', payload)
assert 'abcdef' not in out,    f"api_key 未脱敏: {out}"
assert 'my_secret' not in out, f"password 未脱敏: {out}"
assert 'xyz' not in out,       f"token 未脱敏: {out}"
assert 'hello' in out,         f"normal 被误伤: {out}"
print("JSON 脱敏正则通过 3 敏感 + 1 普通字段测试")
PYEOF
pass "JSON 脱敏正则（mcp-approve）"

# ──────────────────────────────────────────────────────────────
# 3. workspace 抽取：workspace_roots[0] basename，容忍尾随斜杠
# ──────────────────────────────────────────────────────────────
python3 <<'PYEOF' || fail "workspace 抽取失败"
import json, os

def extract(payload_json):
    d = json.loads(payload_json)
    roots = d.get('workspace_roots') or []
    root_path = (roots[0] if roots else '') or ''
    root_path = root_path.rstrip('/')
    return os.path.basename(root_path)

cases = [
    ('{"workspace_roots":["/Users/me/work/myproject"]}',  'myproject'),
    ('{"workspace_roots":["/Users/me/work/myproject/"]}', 'myproject'),  # 尾随 /
    ('{"workspace_roots":[]}',                            ''),
    ('{}',                                                ''),
    ('{"workspace_roots":[""]}',                          ''),
]
for inp, want in cases:
    got = extract(inp)
    assert got == want, f"case {inp!r}: want {want!r}, got {got!r}"
print(f"workspace 抽取通过 {len(cases)} 个用例（含尾随斜杠）")
PYEOF
pass "workspace 抽取（含尾随斜杠容错）"

# ──────────────────────────────────────────────────────────────
# 4. 4 个 hook 文件都含 'kind' 和 'summary' 字段（字面出现）
# ──────────────────────────────────────────────────────────────
for h in shell-approve.sh mcp-approve.sh pretool-approve.sh on-stop.sh; do
    file="$HOOKS_DIR/$h"
    [ -f "$file" ] || fail "$h 不存在"
    # kind 字段
    grep -q "'kind'" "$file" || grep -q '"kind"' "$file" \
        || fail "$h 缺 kind 字段"
    # summary 字段（on-stop.sh 的 summary 是 v1 就有的）
    grep -q "'summary'" "$file" || grep -q '"summary"' "$file" \
        || fail "$h 缺 summary 字段"
    # workspace 字段
    grep -q "'workspace'" "$file" || grep -q '"workspace"' "$file" \
        || fail "$h 缺 workspace 字段"
done
pass "4 个 hook 都包含 kind / summary / workspace 字段"

# ──────────────────────────────────────────────────────────────
# 5. 4 个 hook 的 bash 语法检查
# ──────────────────────────────────────────────────────────────
for h in shell-approve.sh mcp-approve.sh pretool-approve.sh on-stop.sh; do
    bash -n "$HOOKS_DIR/$h" || fail "$h 语法错"
done
pass "4 个 hook 语法检查通过"

# ──────────────────────────────────────────────────────────────
# 6. kind 值与 hook 类型对齐（硬编码常量检查）
# ──────────────────────────────────────────────────────────────
grep -q "'kind': 'shell'"       "$HOOKS_DIR/shell-approve.sh"    || fail "shell-approve 的 kind 应为 'shell'"
grep -q "'kind': 'mcp'"         "$HOOKS_DIR/mcp-approve.sh"      || fail "mcp-approve 的 kind 应为 'mcp'"
grep -q "'kind': 'askQuestion'" "$HOOKS_DIR/pretool-approve.sh"  || fail "pretool-approve AskQuestion 的 kind 应为 'askQuestion'"
grep -q "'kind': 'switchMode'"  "$HOOKS_DIR/pretool-approve.sh"  || fail "pretool-approve SwitchMode 的 kind 应为 'switchMode'"
grep -q '"kind": "stop"'        "$HOOKS_DIR/on-stop.sh"          || fail "on-stop 的 kind 应为 'stop'"
pass "kind 取值与 hook 类型一致"

echo ""
echo -e "${GREEN}=== 全部通过 ===${NC}"
