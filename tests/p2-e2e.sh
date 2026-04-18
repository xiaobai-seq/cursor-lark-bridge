#!/bin/bash
# P2 综合 smoke：把所有 Go 和 Bash 测试跑一遍
# 不带 --real 模式（真正的飞书事件流需要 CP5 用户手动在飞书里验）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
step() { printf "\n${BLUE}▶ %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
die()  { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

echo "${CYAN}=== cursor-lark-bridge P2 e2e (smoke) ===${NC}"

step "Go 单测 + race detector"
(cd "$REPO_ROOT/daemon" && go test -race -count=1 ./...) || die "go test -race 失败"
ok "go test -race 全绿"

step "daemon 编译"
tmpbin=$(mktemp -t clb-p2.XXXXXX)
(cd "$REPO_ROOT/daemon" && go build -o "$tmpbin" .) || { rm -f "$tmpbin"; die "编译失败"; }
rm -f "$tmpbin"
ok "daemon 编译通过"

step "bridge.sh 语法"
bash -n "$REPO_ROOT/scripts/bridge.sh" || die "bridge.sh 语法错"
ok "bridge.sh 语法通过"

step "service-install-test（P0.1 回归）"
bash "$REPO_ROOT/tests/service-install-test.sh" >/dev/null || die "service-install-test 失败"
ok "service-install-test 通过"

step "read-pid-from-file-test（P0.3 回归）"
bash "$REPO_ROOT/tests/read-pid-from-file-test.sh" >/dev/null || die "read-pid-from-file-test 失败"
ok "read-pid-from-file-test 通过"

step "hook-metadata-test（P2.2 回归）"
bash "$REPO_ROOT/tests/hook-metadata-test.sh" >/dev/null || die "hook-metadata-test 失败"
ok "hook-metadata-test 通过"

step "斜杠卡片样例生成（P2.4-P2.6）"
bash "$REPO_ROOT/tests/p2-slash-card-sample.sh" >/dev/null || die "斜杠卡片样例生成失败"
ok "4 张斜杠卡片样例已生成到 tests/slash-samples/"

step "daemon 二进制冒烟：--version 可识别（若支持）"
# 当前 daemon 不支持 --version flag；跳过，但留此 section 以便 P3 添加后顺理成章
# 如果未来加了 flag，这里改成真正检查
ok "（skipped）daemon --version 当前未实装"

step "slash 命令注册完整性（静态）"
grep -q '&helpCommand{}' "$REPO_ROOT/daemon/slash.go" || die "slash.go 缺 helpCommand 注册"
grep -q '&statusCommand{}' "$REPO_ROOT/daemon/slash.go" || die "slash.go 缺 statusCommand 注册"
grep -q '&stopCommand{}' "$REPO_ROOT/daemon/slash.go" || die "slash.go 缺 stopCommand 注册"
grep -q '&pingCommand{}' "$REPO_ROOT/daemon/slash.go" || die "slash.go 缺 pingCommand 注册"
ok "4 个斜杠命令均已注册进 slashRegistry"

echo ""
echo -e "${GREEN}=== P2 e2e smoke 全部通过 ===${NC}"
echo ""
echo "真正的飞书事件流 e2e 由 CP5 用户手动验收："
echo "  1. bash scripts/bridge.sh service install（启动 daemon）"
echo "  2. 在飞书单聊里依次发送：/ping  /status  /stop  /help  /状态  /停止  /帮助  /指令"
echo "  3. 观察每条指令是否都返回对应卡片或文字，并且卡片样式与 tests/slash-samples/ 下样例一致"
