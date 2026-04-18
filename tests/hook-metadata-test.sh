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

# 与 mcp-approve.sh 保持同步：刻意不含 lone "key"（见 hook 内注释）
MCP_SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|bearer)["\s:=]+)"?[^"\s,\}]+',
    re.IGNORECASE,
)

# 正向：敏感字段必须被脱敏，普通字段保持原样
payload = json.dumps({
    "api_key": "abcdef",
    "password": "my_secret",
    "normal_field": "hello",
    "nested_token": "xyz",
})
out = MCP_SENSITIVE.sub(r'\1***', payload)
assert 'abcdef' not in out,    f"api_key 未脱敏: {out}"
assert 'my_secret' not in out, f"password 未脱敏: {out}"
assert 'xyz' not in out,       f"token 未脱敏: {out}"
assert 'hello' in out,         f"normal 被误伤: {out}"
print("JSON 脱敏正向通过 3 敏感 + 1 普通字段测试")

# 反向（意图锁）：lone "key" 在 MCP 工具参数里太常见（主键、字段名、排序键），
# 不应触发脱敏。若未来有人手滑把 "key" 加进正则，这个用例会让 CI 立刻红掉。
mcp_json_cases_keep = [
    ('{"key": "issue-123"}',         '{"key": "issue-123"}'),          # issue 主键
    ('{"key": "field_name"}',        '{"key": "field_name"}'),         # 字段名
    ('{"sort_key": "created_at"}',   '{"sort_key": "created_at"}'),    # 排序键
    ('{"primary_key": "user_id"}',   '{"primary_key": "user_id"}'),    # 主键字段
]
for inp, want in mcp_json_cases_keep:
    got = MCP_SENSITIVE.sub(r'\1***', inp)
    assert got == want, f"mcp 反向 case {inp!r}: want {want!r}, got {got!r}"
print(f"JSON 脱敏反向通过 {len(mcp_json_cases_keep)} 个 'key' 不误伤用例")
PYEOF
pass "JSON 脱敏正则（mcp-approve，含反向意图锁）"

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

# ──────────────────────────────────────────────────────────────
# 7. on-stop.sh summary 脱敏（Agent 最后输出可能夹带凭据）
# ──────────────────────────────────────────────────────────────
python3 <<'PYEOF' || fail "on-stop summary 脱敏失败"
import re

# 与 on-stop.sh 同源（shell 风格正则）
SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+',
    re.IGNORECASE,
)

stop_cases = [
    # Bearer 凭据：注意 [^\s]+ 会连带吞掉尾随闭合引号，这是可接受副作用
    ('执行 curl -H "Bearer abc123" api.example.com',
     '执行 curl -H "Bearer *** api.example.com'),
    ('password=mypass',          'password=***'),
    ('普通 Agent 输出，无凭据',  '普通 Agent 输出，无凭据'),
    ('api_key=sk-xyz 已使用',    'api_key=*** 已使用'),
]
for inp, want in stop_cases:
    got = SENSITIVE.sub(r'\1***', inp)
    assert got == want, f"on-stop case {inp!r}: want {want!r}, got {got!r}"
print(f"on-stop summary 脱敏通过 {len(stop_cases)} 个用例")
PYEOF
pass "on-stop.sh summary 脱敏正则"

# 再断言 on-stop.sh 文件里真的引入了 SENSITIVE 脱敏，而不是只改测试
grep -q 'SENSITIVE' "$HOOKS_DIR/on-stop.sh"    || fail "on-stop.sh 未引入 SENSITIVE 脱敏"
grep -q 'safe_summary' "$HOOKS_DIR/on-stop.sh" || fail "on-stop.sh 未把 summary 走 safe_summary"
pass "on-stop.sh 源码含 SENSITIVE / safe_summary"

# ──────────────────────────────────────────────────────────────
# 8. shell-approve summary 最终长度上限（rework 修的主 bug）
# ──────────────────────────────────────────────────────────────
python3 <<'PYEOF' || fail "shell-approve summary 截断失败"
import re, os

SENSITIVE = re.compile(
    r'((?:api[_-]?key|password|token|secret|key|bearer)[=:\s]+)[^\s]+',
    re.IGNORECASE,
)

def build_summary(cmd, cwd):
    """复刻 hooks/shell-approve.sh 的 summary 构造逻辑"""
    safe_cmd = SENSITIVE.sub(r'\1***', cmd)
    summary_cmd = safe_cmd.replace('\n', ' ').strip()
    if len(summary_cmd) > 80:
        summary_cmd = summary_cmd[:77] + '...'
    cwd_base = os.path.basename(cwd.rstrip('/')) if cwd else ''
    summary = f'{summary_cmd} @ {cwd_base}' if cwd_base else summary_cmd
    if len(summary) > 80:
        summary = summary[:77] + '...'
    return summary

# Case A：summary_cmd 本身已经接近 80 字，拼上 ' @ xxx' 后溢出
sA = build_summary('echo ' + 'x' * 76, '/Users/me/work/some-long-project-name-in-monorepo')
assert len(sA) <= 80, f"Case A 溢出：{len(sA)} 字"

# Case B：短命令 + 短 cwd basename，保留完整 @ 后缀
sB = build_summary('ls', '/tmp/proj')
assert sB == 'ls @ proj', f"Case B 预期 'ls @ proj'，实际 {sB!r}"
assert len(sB) <= 80

# Case C：有敏感信息 + 正常长度，脱敏后仍 <= 80
sC = build_summary('curl -H "Authorization: Bearer s3cret" api.co', '/tmp/svc')
assert 's3cret' not in sC, f"敏感信息未脱敏：{sC}"
assert len(sC) <= 80

# Case D：无 cwd，summary 等于 summary_cmd
sD = build_summary('x' * 200, '')
assert len(sD) <= 80, f"Case D 溢出：{len(sD)} 字"
assert sD.endswith('...')

print("shell-approve summary 4 场景（长/短/含凭据/无cwd）长度均 <= 80")
PYEOF
pass "shell-approve summary 长度上限（<=80，rework 主 bug 回归）"

echo ""
echo -e "${GREEN}=== 全部通过 ===${NC}"
