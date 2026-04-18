#!/bin/bash
# 测试 bridge.sh 的 read_pid_from_file 对 3 种输入的行为
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_SH="$REPO_ROOT/scripts/bridge.sh"

# 把 bridge.sh 的 read_pid_from_file 函数 source 出来需要整个脚本被 source
# 但 bridge.sh 末尾有 case 分发会按参数做事 —— 通过 RUNNING_AS_LIB 守门让 source 时跳过分发
# 这里简化：用 sed 抽函数定义独立到 tmp 文件，bash -c 调用

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 抽 read_pid_from_file 函数体（从定义到第一个独立 "}"）
awk '/^read_pid_from_file\(\)/,/^}/' "$BRIDGE_SH" > "$TMP_DIR/fn.sh"

if ! grep -q 'read_pid_from_file' "$TMP_DIR/fn.sh"; then
    echo "fail: 未从 bridge.sh 抽到 read_pid_from_file 定义"
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

echo "=== read_pid_from_file test ==="

# 1. JSON 格式
JSON_FILE="$TMP_DIR/json.pid"
echo '{"pid":12345,"start_ts":1710489600,"version":"v0.2.0","reconnect_count":3}' > "$JSON_FILE"
result=$(bash -c "source '$TMP_DIR/fn.sh'; read_pid_from_file '$JSON_FILE'")
[ "$result" = "12345" ] || fail "JSON 解析失败: expected 12345, got '$result'"
pass "JSON 读取 PID=12345"

# 2. legacy 单行 PID
PLAIN_FILE="$TMP_DIR/plain.pid"
echo "54321" > "$PLAIN_FILE"
result=$(bash -c "source '$TMP_DIR/fn.sh'; read_pid_from_file '$PLAIN_FILE'")
[ "$result" = "54321" ] || fail "单行 PID 解析失败: expected 54321, got '$result'"
pass "单行 PID 读取=54321"

# 3. 垃圾
GARBAGE_FILE="$TMP_DIR/garbage.pid"
echo "not a number" > "$GARBAGE_FILE"
result=$(bash -c "source '$TMP_DIR/fn.sh'; read_pid_from_file '$GARBAGE_FILE' 2>/dev/null" || true)
# 期望 fallback 走 head -1 + tr，会输出 "notanumber"；这个值 kill -0 会拒绝，不会误 kill
# 只要不是合法 PID 即可；严格点就应返回空
# 此处只断言不是合法正整数
if echo "$result" | grep -qE '^[0-9]+$'; then
    fail "垃圾输入被解为整数: $result"
fi
pass "垃圾输入没有被解为合法 PID (got '$result')"

# 4. 不存在文件
MISSING_FILE="$TMP_DIR/missing.pid"
result=$(bash -c "source '$TMP_DIR/fn.sh'; read_pid_from_file '$MISSING_FILE'" || true)
[ -z "$result" ] || fail "不存在文件应输出空，实际 '$result'"
pass "不存在文件返回空串"

# 5. 空文件
EMPTY_FILE="$TMP_DIR/empty.pid"
: > "$EMPTY_FILE"
result=$(bash -c "source '$TMP_DIR/fn.sh'; read_pid_from_file '$EMPTY_FILE'" || true)
if echo "$result" | grep -qE '^[0-9]+$'; then
    fail "空文件被解为整数: $result"
fi
pass "空文件没有被解为合法 PID (got '$result')"

echo ""
echo -e "${GREEN}=== 所有检查通过 ===${NC}"
