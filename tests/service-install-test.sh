#!/bin/bash
# P0.1 local test: plist 模板能正确渲染出合法 XML，不触及真实 launchctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/launchd/com.cursor.feishu-bridge.plist.template"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

echo "=== P0.1 service-install-test ==="

# 1. 模板存在
[ -f "$TEMPLATE" ] || fail "plist 模板不存在: $TEMPLATE"
pass "模板存在"

# 2. 模板包含 __HOME__ 占位符
grep -q '__HOME__' "$TEMPLATE" || fail "模板缺少 __HOME__ 占位符"
pass "模板含 __HOME__ 占位"

# 3. sed 渲染
FAKE_HOME="/Users/test-user"
RENDERED="$TMP_DIR/rendered.plist"
sed "s#__HOME__#${FAKE_HOME}#g" "$TEMPLATE" > "$RENDERED"
pass "sed 渲染成功"

# 4. 渲染后没有残留 __HOME__
if grep -q '__HOME__' "$RENDERED"; then
    fail "渲染后仍有 __HOME__ 残留"
fi
pass "渲染后 __HOME__ 已全部替换"

# 5. plutil 校验（macOS 原生）
if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$RENDERED" >/dev/null; then
        pass "plutil 校验通过"
    else
        fail "plutil 校验失败，plist XML 不合法"
    fi
else
    pass "plutil 不存在（非 macOS），跳过校验"
fi

# 6. 渲染后的内容包含预期字段
for key in Label ProgramArguments RunAtLoad KeepAlive ThrottleInterval StandardOutPath StandardErrorPath; do
    grep -q "<key>$key</key>" "$RENDERED" || fail "渲染后缺少 <key>$key</key>"
done
pass "渲染后包含全部关键字段"

# 7. ThrottleInterval 值确实是 10
grep -A1 '<key>ThrottleInterval</key>' "$RENDERED" | grep -q '<integer>10</integer>' || fail "ThrottleInterval 不是 10"
pass "ThrottleInterval=10 正确"

# 8. KeepAlive.Crashed=true
python3 -c "
import plistlib, sys
with open('$RENDERED', 'rb') as f:
    d = plistlib.load(f)
assert d['KeepAlive']['Crashed'] is True, 'KeepAlive.Crashed should be True'
assert d['KeepAlive']['SuccessfulExit'] is False, 'KeepAlive.SuccessfulExit should be False'
assert d['RunAtLoad'] is True, 'RunAtLoad should be True'
print('  KeepAlive.Crashed=True, SuccessfulExit=False, RunAtLoad=True')
" || fail "KeepAlive 字段不符合预期"
pass "KeepAlive 字段检查通过"

# 9. bridge.sh 的 service 子命令存在
BRIDGE_SH="$REPO_ROOT/scripts/bridge.sh"
grep -q 'cmd_service_install' "$BRIDGE_SH" || fail "bridge.sh 缺少 cmd_service_install 函数"
grep -q 'cmd_service_uninstall' "$BRIDGE_SH" || fail "bridge.sh 缺少 cmd_service_uninstall 函数"
grep -qE '^\s*service\)' "$BRIDGE_SH" || fail "bridge.sh 的 case 分发缺少 service) 分支"
pass "bridge.sh 含 service 子命令"

# 10. bridge.sh 语法检查
bash -n "$BRIDGE_SH" || fail "bridge.sh 语法错误"
pass "bridge.sh 语法检查通过"

echo ""
echo -e "${GREEN}=== 所有检查通过 ===${NC}"
