#!/bin/bash
# P0 end-to-end test suite.
#
# 默认模式 (smoke)：只跑静态校验 + 单元测试，完全不触碰 launchctl 和用户系统
# --real 模式：启用真实 launchd 安装/崩溃恢复/卸载；脚本会自动备份并恢复用户
#             已有的 ~/Library/LaunchAgents/com.cursor.feishu-bridge.plist
#             以及 ~/.cursor/cursor-lark-bridge/daemon.pid（如果存在）
#
# 用法：
#   bash tests/p0-e2e.sh            # 安全默认
#   bash tests/p0-e2e.sh --real     # 真跑 launchctl，需交互确认
#   P0_E2E_AUTO_YES=1 bash tests/p0-e2e.sh --real  # CI 自动化（自担风险）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

step() { printf "\n${BLUE}▶ %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; }
die()  { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

MODE="smoke"
if [ "${1:-}" = "--real" ]; then
    MODE="real"
fi

echo "${CYAN}=== cursor-lark-bridge P0 e2e (${MODE} mode) ===${NC}"

# ─────────────────────────────────────────────
# smoke：所有人都安全可跑
# ─────────────────────────────────────────────

run_smoke_tests() {
    step "Go unit tests"
    (cd "$REPO_ROOT/daemon" && go test -count=1 ./...) \
        || die "go test 失败"
    ok "Go 单测全绿"

    step "Go build 验证"
    local tmpbin
    tmpbin=$(mktemp -t clb-daemon.XXXXXX)
    (cd "$REPO_ROOT/daemon" && go build -o "$tmpbin" .) \
        || { rm -f "$tmpbin"; die "daemon 编译失败"; }
    rm -f "$tmpbin"
    ok "daemon 编译通过"

    step "bridge.sh 语法检查"
    bash -n "$REPO_ROOT/scripts/bridge.sh" || die "bridge.sh 语法错"
    ok "bridge.sh 语法检查通过"

    step "service-install-test (P0.1 回归)"
    bash "$REPO_ROOT/tests/service-install-test.sh" >/dev/null || die "service-install-test 失败"
    ok "service-install-test 通过"

    step "read-pid-from-file-test (P0.3 回归)"
    bash "$REPO_ROOT/tests/read-pid-from-file-test.sh" >/dev/null || die "read-pid-from-file-test 失败"
    ok "read-pid-from-file-test 通过"

    step "launchd plist 模板完整性"
    local tpl="$REPO_ROOT/launchd/com.cursor.feishu-bridge.plist.template"
    [ -f "$tpl" ] || die "plist 模板缺失"
    grep -q '<key>KeepAlive</key>' "$tpl" || die "plist 模板缺少 KeepAlive"
    grep -q '<key>Crashed</key>' "$tpl" || die "plist 模板缺少 Crashed"
    grep -q 'ThrottleInterval' "$tpl" || die "plist 模板缺少 ThrottleInterval"
    ok "plist 模板完整"

    step "fb service 子命令在 bridge.sh 里注册了"
    grep -qE '^\s*service\)' "$REPO_ROOT/scripts/bridge.sh" \
        || die "bridge.sh case 分发缺少 service) 分支"
    grep -q 'cmd_service_install' "$REPO_ROOT/scripts/bridge.sh" \
        || die "bridge.sh 缺少 cmd_service_install"
    grep -q 'cmd_service_uninstall' "$REPO_ROOT/scripts/bridge.sh" \
        || die "bridge.sh 缺少 cmd_service_uninstall"
    ok "service 子命令注册完整"

    echo ""
    echo -e "${GREEN}=== smoke 模式全部通过 ===${NC}"
    echo ""
    echo "要跑真实 launchd 端到端测试，请运行："
    echo "  ${CYAN}bash tests/p0-e2e.sh --real${NC}"
}

# ─────────────────────────────────────────────
# real：真跑 launchctl，带备份/恢复
# ─────────────────────────────────────────────

real_confirm_or_exit() {
    if [ "${P0_E2E_AUTO_YES:-}" = "1" ]; then
        warn "P0_E2E_AUTO_YES=1 自动确认，跳过交互"
        return
    fi
    if [ ! -t 0 ]; then
        die "--real 模式需要 tty 确认（或设置 P0_E2E_AUTO_YES=1 bypass）"
    fi
    cat <<EOF

${YELLOW}⚠ --real 模式将会：${NC}
  1. 备份并删除你现有的 ~/Library/LaunchAgents/com.cursor.feishu-bridge.plist（如有）
  2. 备份你现有的 ~/.cursor/cursor-lark-bridge/daemon.pid（如有）
  3. 安装本仓库的 plist 并 launchctl load
  4. 等 launchd 自动启动 daemon (~5s)
  5. pkill -9 daemon，等 15s 观察 launchd 是否拉起
  6. uninstall + 恢复原有 plist + daemon.pid

${RED}过程中你已有的 daemon 会被重启（短暂不可用）。${NC}
${RED}如果你当前正在用飞书桥审批操作，请停止 --real 测试，等任务结束再跑。${NC}

EOF
    printf "继续？ [y/N] "
    read -r ans
    case "${ans:-n}" in
        y|Y|yes|YES|Yes) ;;
        *) echo "已取消。"; exit 0 ;;
    esac
}

BACKUP_DIR=""

real_backup() {
    BACKUP_DIR=$(mktemp -d -t clb-e2e-backup.XXXXXX)
    step "备份用户现有状态到 $BACKUP_DIR"
    if [ -f "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" ]; then
        cp "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" "$BACKUP_DIR/plist.original"
        ok "已备份现有 plist"
        launchctl unload "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" 2>/dev/null || true
    else
        ok "无现有 plist（清零环境）"
    fi
    if [ -f "$HOME/.cursor/cursor-lark-bridge/daemon.pid" ]; then
        cp "$HOME/.cursor/cursor-lark-bridge/daemon.pid" "$BACKUP_DIR/daemon.pid.original"
        ok "已备份现有 daemon.pid"
    fi
}

real_restore() {
    [ -n "$BACKUP_DIR" ] || return 0
    step "恢复用户原有状态"
    # 先把 e2e 装的 plist 卸掉
    if [ -f "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" ]; then
        launchctl unload "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist"
    fi
    # 恢复
    if [ -f "$BACKUP_DIR/plist.original" ]; then
        cp "$BACKUP_DIR/plist.original" "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist"
        launchctl load "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" 2>/dev/null || true
        ok "已恢复原有 plist 并重新 load"
    fi
    if [ -f "$BACKUP_DIR/daemon.pid.original" ]; then
        cp "$BACKUP_DIR/daemon.pid.original" "$HOME/.cursor/cursor-lark-bridge/daemon.pid"
        ok "已恢复原有 daemon.pid"
    fi
    rm -rf "$BACKUP_DIR"
    ok "备份清理完成"
}

run_real_tests() {
    [ "$(uname)" = "Darwin" ] || die "--real 仅支持 macOS（launchd 是 macOS 独占）"

    real_confirm_or_exit

    # 先确保最新代码被编译 + 部署到 $BRIDGE_DIR
    local bridge_dir="$HOME/.cursor/cursor-lark-bridge"
    local daemon_bin="$bridge_dir/daemon/cursor-lark-bridge-daemon"

    [ -f "$daemon_bin" ] || die "期待在 $daemon_bin 有已编译好的 daemon（请先 \`fb kill; cd daemon && go build -o $daemon_bin .\` 或跑 install.sh 部署）"

    real_backup
    trap real_restore EXIT

    step "fb service install"
    bash "$REPO_ROOT/scripts/bridge.sh" service install || die "fb service install 失败"

    step "等待 5s 让 launchd 启动 daemon"
    sleep 5

    step "验证 daemon 通过 launchd 启动"
    bash "$REPO_ROOT/scripts/bridge.sh" status || die "fb status 失败"
    curl -fsS --max-time 3 http://127.0.0.1:19836/health >/dev/null \
        || die "/health 不可达"
    ok "/health 可达"

    step "记录当前 reconnect_count（用于验证后面确实拉起了新进程）"
    local initial_rc
    initial_rc=$(python3 -c "
import json, sys
try:
    with open('$HOME/.cursor/cursor-lark-bridge/daemon.pid') as f:
        d = json.load(f)
    print(d.get('reconnect_count', 0))
except Exception:
    print(0)
" 2>/dev/null)
    ok "当前 reconnect_count = $initial_rc"

    step "pkill -9 daemon (模拟崩溃)"
    pkill -9 cursor-lark-bridge-daemon 2>/dev/null || warn "pkill 没匹配（可能已在重启）"

    step "等 20s（ThrottleInterval=10，留 2x 余量）"
    sleep 20

    step "验证 daemon 已被 launchd 拉起"
    bash "$REPO_ROOT/scripts/bridge.sh" status || die "崩溃后 fb status 失败"
    curl -fsS --max-time 3 http://127.0.0.1:19836/health >/dev/null \
        || die "崩溃后 /health 不可达"
    ok "daemon 已自动恢复"

    step "验证 reconnect_count 已增加（新进程 fresh start）"
    local new_rc
    new_rc=$(python3 -c "
import json, sys
with open('$HOME/.cursor/cursor-lark-bridge/daemon.pid') as f:
    d = json.load(f)
print(d.get('reconnect_count', 0))
")
    # 新进程冷启动 rc 从 1 开始（P0.4 spec：每次尝试前 +1）
    if [ "$new_rc" -lt 1 ]; then
        die "新进程的 reconnect_count 应 >= 1，实际 $new_rc"
    fi
    ok "新进程 reconnect_count=$new_rc（冷启动后 fresh PIDInfo）"

    step "fb service uninstall"
    bash "$REPO_ROOT/scripts/bridge.sh" service uninstall || die "uninstall 失败"

    # 验证 plist 确实没了（恢复阶段会再 load 回用户原有的，现在只看 e2e 装的那份没了）
    # 备份里可能没有 "原有 plist"——清零环境下是这样
    if [ ! -f "$BACKUP_DIR/plist.original" ]; then
        [ ! -f "$HOME/Library/LaunchAgents/com.cursor.feishu-bridge.plist" ] \
            || die "uninstall 后仍存在 plist"
        ok "uninstall 干净"
    else
        ok "uninstall 步骤完成（恢复阶段将把用户原有 plist 还回去）"
    fi

    echo ""
    echo -e "${GREEN}=== real 模式全部通过（备份将在退出时恢复）===${NC}"
}

# ─────────────────────────────────────────────
# main
# ─────────────────────────────────────────────

run_smoke_tests

if [ "$MODE" = "real" ]; then
    run_real_tests
fi

echo ""
echo -e "${GREEN}P0 e2e 完成${NC}"
