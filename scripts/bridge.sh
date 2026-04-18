#!/bin/bash
# cursor-lark-bridge 控制脚本
# 用法:
#   bridge.sh init    — 首次引导配置（open_id + hooks.json 合并）
#   bridge.sh start   — 启动 daemon 并激活远程模式
#   bridge.sh stop    — 关闭远程模式（daemon 保持运行）
#   bridge.sh kill    — 停止 daemon 进程
#   bridge.sh status  — 查看状态
#   bridge.sh restart — 重启 daemon
#   bridge.sh doctor  — 诊断冲突进程并可选一键修复
#   bridge.sh service {...} — 安装/管理 launchd service

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$HOME/.cursor/cursor-lark-bridge"
HOOKS_DIR="$HOME/.cursor/hooks/cursor-lark-bridge"
DAEMON_DIR="$BRIDGE_DIR/daemon"
DAEMON_BIN="$DAEMON_DIR/cursor-lark-bridge-daemon"
PID_FILE="$BRIDGE_DIR/daemon.pid"
DAEMON_ADDR="http://127.0.0.1:19836"
LOG_FILE="$BRIDGE_DIR/daemon.log"

# NOTE: ANSI-C quoting so \033 expands to a real ESC byte, which works
# consistently with echo, printf %s and heredoc-based output alike.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

is_daemon_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# list_matching_pids <regex>
# 返回 cmdline 匹配 <regex> 且确实是目标二进制（不是 shell 解释器）的 PID 列表
#
# 为什么需要这个：
#   pgrep -f 用整条 cmdline 匹配，所以当某个 bash 脚本的参数字符串里恰好包含
#   "feishu-bridge-daemon" 或 "lark-cli event +subscribe" 时，该 bash 进程
#   也会被 pgrep -f 命中——但它实际执行的是 /bin/bash，而不是目标程序。
#   这里通过 ps -p <pid> -o comm= 读取进程真正的 executable path，
#   排除 basename 在 shell 解释器白名单里的 PID。
#
# 输出：每行一个 PID；无匹配时输出为空
list_matching_pids() {
    local regex="$1"
    local candidates pid comm base
    candidates=$(pgrep -f "$regex" 2>/dev/null || true)
    [ -z "$candidates" ] && return 0
    for pid in $candidates; do
        [ "$pid" = "$$" ] && continue  # 别把自己算进去
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        [ -z "$comm" ] && continue
        base="${comm##*/}"
        case "$base" in
            bash|sh|zsh|fish|dash|ksh|pgrep|grep|ps|awk|sed|tr|wc|head|tail|xargs|cat|echo) continue ;;
        esac
        echo "$pid"
    done
}

# 清理可能残留的 lark-cli event +subscribe 进程（包括两个 node 层级）
# $1 可选 --verbose；无 verbose 时静默
cleanup_stale_lark_cli() {
    local verbose="${1:-}"
    local pids patterns=(
        'lark-cli.*event .subscribe'
        '@larksuite/cli.*event .subscribe'
    )
    local all_pids=""
    for p in "${patterns[@]}"; do
        pids=$(list_matching_pids "$p")
        [ -n "$pids" ] && all_pids+=" $pids"
    done
    all_pids=$(echo "$all_pids" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
    [ -z "$all_pids" ] && return 0
    local killed=0
    for pid in $all_pids; do
        if kill -9 "$pid" 2>/dev/null; then
            killed=1
        fi
    done
    if [ "$verbose" = "--verbose" ] && [ "$killed" = "1" ]; then
        echo -e "${YELLOW}已清理残留的 lark-cli event 订阅进程${NC}"
    fi
}

# 扫描旧版 feishu-bridge 残留（从 v0.1.0 之前的项目名遗留过来的）
# 候选正则故意宽松（捕获各种启动方式），最终判定靠 list_matching_pids 过滤 bash 解释器
LEGACY_FB_REGEX='feishu-bridge-daemon|feishu-bridge/daemon'

# 列出真正的老 daemon PID（每行一个）
list_legacy_feishu_bridge_pids() {
    list_matching_pids "$LEGACY_FB_REGEX"
}

# 返回 0：有老 daemon；返回 1：没有
detect_legacy_feishu_bridge() {
    [ -n "$(list_legacy_feishu_bridge_pids)" ]
}

build_daemon() {
    if [ ! -f "$DAEMON_BIN" ] || { [ -f "$DAEMON_DIR/main.go" ] && [ "$DAEMON_DIR/main.go" -nt "$DAEMON_BIN" ]; }; then
        if [ ! -f "$DAEMON_DIR/main.go" ]; then
            echo -e "${RED}daemon 二进制丢失（$DAEMON_BIN）${NC}"
            echo -e "请重新运行 install.sh 或 ${CYAN}BUILD_FROM_SOURCE=1 install.sh${NC}"
            exit 1
        fi
        echo -e "${BLUE}编译 daemon...${NC}"
        (cd "$DAEMON_DIR" && go build -ldflags="-X main.version=source-$(date +%Y%m%d)" \
            -o cursor-lark-bridge-daemon .) || {
            echo -e "${RED}编译失败${NC}"
            exit 1
        }
    fi
}

start_daemon() {
    if is_daemon_running; then
        echo -e "${YELLOW}daemon 已在运行 (PID=$(cat "$PID_FILE"))${NC}"
        return 0
    fi

    # 启动前硬性冲突检测：老版 feishu-bridge 会霸占同一 19836 端口，
    # 导致新 daemon 的 HTTP bind 失败但进程本身不会退出，造成虚假"运行中"的假象
    local legacy_pids
    legacy_pids=$(list_legacy_feishu_bridge_pids)
    if [ -n "$legacy_pids" ]; then
        echo -e "${RED}检测到老版 feishu-bridge 残留进程：${NC}"
        for pid in $legacy_pids; do
            ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/  /'
        done
        echo
        echo -e "${YELLOW}这是项目改名前的旧版本，会和 cursor-lark-bridge 抢占同一端口。${NC}"
        echo -e "请先运行 ${CYAN}fb doctor --fix${NC} 一键清理，或手动执行："
        echo -e "  ${CYAN}kill -9 $legacy_pids${NC}"
        echo -e "  ${CYAN}rm -rf ~/.cursor/feishu-bridge${NC}  # 可选，清理老目录"
        exit 1
    fi

    # 启动前清理可能遗留的 lark-cli event 孤儿（来自上一次 daemon 非正常退出）
    cleanup_stale_lark_cli --verbose

    build_daemon
    echo -e "${BLUE}启动 daemon...${NC}"
    mkdir -p "$BRIDGE_DIR"
    nohup "$DAEMON_BIN" >> "$LOG_FILE" 2>&1 &
    sleep 1
    if is_daemon_running; then
        echo -e "${GREEN}daemon 已启动 (PID=$(cat "$PID_FILE"))${NC}"
    else
        echo -e "${RED}daemon 启动失败，查看日志: $LOG_FILE${NC}"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
        exit 1
    fi
}

activate_remote() {
    resp=$(curl -s -X POST "$DAEMON_ADDR/mode" \
        -H "Content-Type: application/json" \
        -d '{"active":true}' 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}远程模式已激活${NC}"
        notify_payload=$(python3 -c "
import json
print(json.dumps({
    'title': '🟢 远程交互桥已就绪',
    'content': '''**Cursor Agent 现在通过本单聊与你协作 ✨**

📥 **会推送给你的事件**
🖥️  Shell 命令审批
🔧  MCP 工具调用授权
❓  Agent 提问 / 模式切换
⏸  Agent 暂停时的下一步指令

💬 **如何回复**
点击卡片按钮（推荐，最快）
或直接发送文字消息（自动作为下一条指令）''',
    'color': 'green',
    'context': '回到电脑后输入  fb stop  即可关闭',
}, ensure_ascii=False))
")
        curl -s -X POST "$DAEMON_ADDR/notify" \
            -H "Content-Type: application/json" \
            -d "$notify_payload" > /dev/null 2>&1
    else
        echo -e "${RED}激活失败，daemon 可能未运行${NC}"
        exit 1
    fi
}

deactivate_remote() {
    resp=$(curl -s -X POST "$DAEMON_ADDR/mode" \
        -H "Content-Type: application/json" \
        -d '{"active":false}' 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}远程模式已关闭${NC}"
        notify_payload=$(python3 -c "
import json
print(json.dumps({
    'title': '🌙 远程交互桥已关闭',
    'content': '''**远程接管已结束**

Cursor 后续交互将回到 IDE 内完成，本单聊不再推送审批与提问。

> 如需再次接管，运行  \`fb start\`''',
    'color': 'blue',
    'context': '通道关闭',
}, ensure_ascii=False))
")
        curl -s -X POST "$DAEMON_ADDR/notify" \
            -H "Content-Type: application/json" \
            -d "$notify_payload" > /dev/null 2>&1
    else
        echo -e "${YELLOW}关闭失败，daemon 可能未运行${NC}"
    fi
}

kill_daemon() {
    if is_daemon_running; then
        pid=$(cat "$PID_FILE")
        echo -e "${BLUE}停止 daemon (PID=$pid)...${NC}"
        # SIGTERM 给 daemon；daemon 的 signal handler 会对 lark-cli 子进程组
        # 发 SIGTERM→SIGKILL，正常情况下无孤儿遗留
        kill "$pid" 2>/dev/null
        # 等最多 5 秒让 daemon 优雅关闭（包括清理子进程）
        for _ in 1 2 3 4 5; do
            is_daemon_running || break
            sleep 1
        done
        if is_daemon_running; then
            echo -e "${YELLOW}daemon 优雅关闭超时，强制 kill...${NC}"
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        echo -e "${GREEN}daemon 已停止${NC}"
    else
        echo -e "${YELLOW}daemon 未在运行${NC}"
        rm -f "$PID_FILE"
    fi

    # 兜底清理：即使 daemon 已经干净退出，也再扫一次 lark-cli event 残留，
    # 防止历史孤儿（例如 daemon 曾经被 SIGKILL 或崩溃留下的）继续占"单订阅者"坑位
    cleanup_stale_lark_cli --verbose
}

show_status() {
    echo -e "${BLUE}=== cursor-lark-bridge 状态 ===${NC}"
    if is_daemon_running; then
        echo -e "Daemon:      ${GREEN}运行中${NC} (PID=$(cat "$PID_FILE"))"
    else
        echo -e "Daemon:      ${RED}未运行${NC}"
        return
    fi

    health=$(curl -s --connect-timeout 2 "$DAEMON_ADDR/health" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$health" ]; then
        echo -e "HTTP API:    ${RED}无法连接${NC}  (daemon 进程存在但 HTTP 未响应)"
        echo -e "             常见原因：端口 19836 被其它进程占用（老版 feishu-bridge？）"
        echo -e "             ${CYAN}fb doctor${NC} 可一键排查"
        return
    fi

    # 用单次 python3 调用解析全部字段，避免多次 subshell
    # 返回空行分隔的 6 个字段：active event_running subscribe_ok last_age_ms restart_count version
    read -r active event_running subscribe_ok last_age_ms restart_count ver < <(echo "$health" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('False False False -1 0 unknown'); sys.exit(0)
print(' '.join([
    str(d.get('active', False)),
    str(d.get('event_running', False)),
    str(d.get('subscribe_ok', False)),
    str(d.get('last_event_age_ms', -1)),
    str(d.get('restart_count', 0)),
    str(d.get('version', 'unknown')),
]))
" 2>/dev/null)

    echo -e "Version:     ${ver:-unknown}"

    if [ "$active" = "True" ]; then
        echo -e "远程模式:    ${GREEN}已激活${NC}"
    else
        echo -e "远程模式:    ${YELLOW}未激活${NC}"
    fi

    # 事件订阅的真实健康度综合判定：
    #   event_running=True 仅说明进程在跑（可能是刚起、也可能已被服务端拒绝）
    #   subscribe_ok=True 说明最近一次启动稳定超过 2 秒（真实订阅到了）
    #   last_age_ms 说明距离上次收到事件的毫秒数
    if [ "$event_running" != "True" ]; then
        echo -e "事件订阅:    ${RED}未运行${NC}  (lark-cli 子进程不存在)"
    elif [ "$subscribe_ok" != "True" ]; then
        echo -e "事件订阅:    ${YELLOW}不稳定${NC}  (正在重启，累计重启 ${restart_count} 次)"
        echo -e "             可能原因：有遗留订阅者占坑，跑 ${CYAN}fb doctor${NC} 排查"
    else
        if [ "$last_age_ms" = "-1" ]; then
            echo -e "事件订阅:    ${GREEN}健康${NC}  (暂未收到任何事件)"
        elif [ "$last_age_ms" -lt 60000 ] 2>/dev/null; then
            echo -e "事件订阅:    ${GREEN}健康${NC}  (最近事件 $((last_age_ms / 1000))s 前)"
        else
            echo -e "事件订阅:    ${GREEN}健康${NC}  (最近事件 $((last_age_ms / 60000)) 分钟前)"
        fi
    fi
}

# ─────────────────────────────────────────────
# doctor 子命令：诊断冲突进程并可选一键修复
# ─────────────────────────────────────────────
#
# 典型场景：
#   1) 老版 feishu-bridge daemon 从未清理，占用同一 19836 端口
#   2) 上一次 daemon 非正常退出（崩溃/SIGKILL）留下 lark-cli event 孤儿
#   3) PID 文件指向已死进程，bridge.sh 误判 daemon 在运行
#   4) Cursor hooks.json 里同时配了 feishu-bridge 和 cursor-lark-bridge 两份
#      → 每个交互会触发两次脚本，发两张卡片，第二张按钮因 Cursor 只 wait 首响应而失效
#
# 输出：
#   - 各类异常的清单 + 建议
#   - 带 --fix 时自动执行修复动作

# 扫描 hooks.json：返回 feishu-bridge/* 条目数；参数 --list 时打印每条 command
scan_duplicate_hooks() {
    local mode="${1:-count}"
    local hooks_json="$HOME/.cursor/hooks.json"
    [ ! -f "$hooks_json" ] && { [ "$mode" = "count" ] && echo 0; return; }

    python3 - "$hooks_json" "$mode" <<'PYEOF'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    if mode == 'count': print(0)
    sys.exit(0)

found = []
for event, entries in data.get('hooks', {}).items():
    if not isinstance(entries, list):
        continue
    for e in entries:
        if isinstance(e, dict):
            cmd = e.get('command', '')
            if 'hooks/feishu-bridge/' in cmd:
                found.append((event, cmd))

if mode == 'count':
    print(len(found))
else:
    for event, cmd in found:
        print(f'{event}: {cmd}')
PYEOF
}

# 从 hooks.json 中过滤所有 feishu-bridge/* 条目；先写备份再原子替换
clean_duplicate_hooks() {
    local hooks_json="$HOME/.cursor/hooks.json"
    [ ! -f "$hooks_json" ] && return 1
    local backup="${hooks_json}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$hooks_json" "$backup" || return 1

    python3 - "$hooks_json" >/dev/null <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
for event, entries in list(data.get('hooks', {}).items()):
    if not isinstance(entries, list): continue
    data['hooks'][event] = [
        e for e in entries
        if not (isinstance(e, dict) and 'hooks/feishu-bridge/' in e.get('command', ''))
    ]
with open(path, 'w') as f:
    json.dump(data, f, indent=2); f.write('\n')
PYEOF

    echo -e "  ${GREEN}✓${NC} 已清理 hooks.json 中的重复条目（备份: $backup）"
    local legacy_dir="$HOME/.cursor/hooks/feishu-bridge"
    if [ -d "$legacy_dir" ]; then
        rm -rf "$legacy_dir"
        echo -e "  ${GREEN}✓${NC} 已删除老目录 $legacy_dir"
    fi
}

cmd_doctor() {
    local auto_fix=0
    if [ "${1:-}" = "--fix" ] || [ "${1:-}" = "-f" ]; then
        auto_fix=1
    fi

    echo -e "${BLUE}=== cursor-lark-bridge doctor ===${NC}"
    echo ""

    local issues=0
    local fixes=()

    # 1. 老版 feishu-bridge 残留
    echo -e "${BLUE}[1/5] 扫描老版 feishu-bridge 残留进程...${NC}"
    local legacy_pids
    legacy_pids=$(list_legacy_feishu_bridge_pids)
    if [ -n "$legacy_pids" ]; then
        issues=$((issues + 1))
        echo -e "  ${RED}✗${NC} 检测到老版 feishu-bridge 进程："
        for pid in $legacy_pids; do
            ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/      /'
        done
        fixes+=("kill -9 $legacy_pids")
    else
        echo -e "  ${GREEN}✓${NC} 无老版残留"
    fi

    # 2. lark-cli event 订阅进程（检查孤儿/缺失）
    echo -e "${BLUE}[2/5] 扫描 lark-cli event 订阅进程...${NC}"
    local lark_pids lark_event_count
    lark_pids=$(list_matching_pids 'lark-cli.*event .subscribe')
    lark_event_count=$(echo -n "$lark_pids" | grep -c . || true)
    if [ "${lark_event_count:-0}" -gt 0 ]; then
        # 期待只有 2 个（node shebang + 真实 binary）归属于当前 daemon
        local expected=2
        if ! is_daemon_running; then
            expected=0
        fi
        if [ "$lark_event_count" -gt "$expected" ]; then
            issues=$((issues + 1))
            echo -e "  ${RED}✗${NC} 发现 $lark_event_count 个 lark-cli event 进程，超出预期（应为 $expected 个）"
            for pid in $lark_pids; do
                ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/      /'
            done
            fixes+=("kill -9 $lark_pids")
        else
            echo -e "  ${GREEN}✓${NC} 有 $lark_event_count 个 lark-cli event 进程（属于当前 daemon）"
        fi
    else
        if is_daemon_running; then
            issues=$((issues + 1))
            echo -e "  ${RED}✗${NC} daemon 在跑但未发现任何 lark-cli event 进程 — 订阅可能完全失败"
            fixes+=("fb restart")
        else
            echo -e "  ${GREEN}✓${NC} 无残留"
        fi
    fi

    # 3. PID 文件一致性
    echo -e "${BLUE}[3/5] 检查 PID 文件一致性...${NC}"
    if [ -f "$PID_FILE" ]; then
        local pid_in_file
        pid_in_file=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid_in_file" ] && ! kill -0 "$pid_in_file" 2>/dev/null; then
            issues=$((issues + 1))
            echo -e "  ${RED}✗${NC} PID 文件指向已死进程 ($pid_in_file) — bridge.sh 会误判 daemon 未运行"
            fixes+=("rm -f $PID_FILE")
        else
            local actual_daemon
            actual_daemon=$(pgrep -f 'cursor-lark-bridge-daemon' | head -1)
            if [ -n "$actual_daemon" ] && [ "$actual_daemon" != "$pid_in_file" ]; then
                issues=$((issues + 1))
                echo -e "  ${RED}✗${NC} PID 文件是 $pid_in_file 但实际 daemon 是 $actual_daemon"
                fixes+=("echo $actual_daemon > $PID_FILE")
            else
                echo -e "  ${GREEN}✓${NC} PID 文件与实际进程一致"
            fi
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} 无 PID 文件 (daemon 未运行或未曾成功启动)"
    fi

    # 4. 端口占用检测
    echo -e "${BLUE}[4/5] 检查 19836 端口占用...${NC}"
    local port_holder
    port_holder=$(lsof -iTCP:19836 -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR>1 {print $1"(PID="$2")"}' | head -1)
    if [ -n "$port_holder" ]; then
        # 合法占用者：cursor-lark-bridge-daemon（进程名可能被截断）
        if echo "$port_holder" | grep -qE 'cursor-la|cursor-lark-bridge'; then
            echo -e "  ${GREEN}✓${NC} 端口被合法 daemon 占用: $port_holder"
        else
            issues=$((issues + 1))
            echo -e "  ${RED}✗${NC} 端口被其它进程占用: $port_holder"
            fixes+=("# 请手动 kill 占用该端口的进程")
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} 端口空闲 (daemon 未运行)"
    fi

    # 5. hooks.json 里的重复条目（老 feishu-bridge + 新 cursor-lark-bridge 并存）
    echo -e "${BLUE}[5/5] 扫描 hooks.json 是否有老版 feishu-bridge 残留条目...${NC}"
    local dup_count
    dup_count=$(scan_duplicate_hooks count)
    if [ "${dup_count:-0}" -gt 0 ]; then
        issues=$((issues + 1))
        echo -e "  ${RED}✗${NC} hooks.json 中有 $dup_count 条老版 feishu-bridge hook 与新版并存："
        scan_duplicate_hooks list | sed 's/^/      /'
        echo -e "      ${YELLOW}每次 Cursor 触发交互都会发两张授权卡片，且第二张按钮点击无响应。${NC}"
        fixes+=("fb doctor --fix  # 将自动清理 hooks.json 与老 hooks 目录")
    else
        echo -e "  ${GREEN}✓${NC} hooks.json 无重复条目"
    fi

    # 汇总
    echo ""
    echo -e "${BLUE}── 汇总 ──${NC}"
    if [ "$issues" = "0" ]; then
        echo -e "${GREEN}✓ 未发现异常${NC}"
        return 0
    fi

    echo -e "${YELLOW}发现 $issues 处异常，建议执行：${NC}"
    for fix in "${fixes[@]}"; do
        echo -e "  ${CYAN}$fix${NC}"
    done

    if [ "$auto_fix" = "1" ]; then
        echo ""
        echo -e "${BLUE}── 正在一键修复（--fix）──${NC}"
        # 杀老版 feishu-bridge（基于过滤后的 PID 列表，避免误杀 shell 进程）
        local kill_pids
        kill_pids=$(list_legacy_feishu_bridge_pids)
        if [ -n "$kill_pids" ]; then
            for pid in $kill_pids; do kill -9 "$pid" 2>/dev/null || true; done
            echo -e "  ${GREEN}✓${NC} 已终止老版 feishu-bridge 进程 ($kill_pids)"
        fi
        # 杀所有 lark-cli event（同样过滤）
        kill_pids=$(list_matching_pids 'lark-cli.*event .subscribe')
        if [ -n "$kill_pids" ]; then
            for pid in $kill_pids; do kill -9 "$pid" 2>/dev/null || true; done
            echo -e "  ${GREEN}✓${NC} 已终止所有 lark-cli event 进程"
        fi
        # 清理过时 PID 文件
        if [ -f "$PID_FILE" ]; then
            local pid_in_file
            pid_in_file=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$pid_in_file" ] && ! kill -0 "$pid_in_file" 2>/dev/null; then
                rm -f "$PID_FILE"
                echo -e "  ${GREEN}✓${NC} 已删除过时 PID 文件"
            fi
        fi
        # 清理 hooks.json 中的重复/老版条目 + 老 hooks 目录
        if [ "$(scan_duplicate_hooks count)" -gt 0 ]; then
            clean_duplicate_hooks
        fi
        echo ""
        echo -e "${GREEN}修复完成。${NC}运行 ${CYAN}fb start${NC} 重新启动（若已运行则保持即可，Cursor 下次触发 hook 会读新 hooks.json）。"
    else
        echo ""
        echo -e "加 ${CYAN}fb doctor --fix${NC} 让脚本自动执行（除端口占用需手动处理外）"
    fi
}

# ─────────────────────────────────────────────
# service 子命令：launchd 托管
# ─────────────────────────────────────────────

LAUNCHD_LABEL="com.cursor.feishu-bridge"
PLIST_INSTALL_PATH="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# 定位 plist 模板（已安装路径优先，fallback 到仓库布局）
find_plist_template() {
    for candidate in \
        "$BRIDGE_DIR/launchd/${LAUNCHD_LABEL}.plist.template" \
        "$SCRIPT_DIR/../launchd/${LAUNCHD_LABEL}.plist.template"; do
        [ -f "$candidate" ] && { echo "$candidate"; return; }
    done
    return 1
}

render_plist() {
    local template="$1" dest="$2"
    # 替换 __HOME__ 为真实 $HOME；用 # 作为 sed 分隔符，避免路径里的 / 需要转义
    sed "s#__HOME__#${HOME}#g" "$template" > "$dest"
}

cmd_service_install() {
    local template
    template=$(find_plist_template) || {
        echo -e "${RED}找不到 plist 模板（期望在 $BRIDGE_DIR/launchd/ 或 $SCRIPT_DIR/../launchd/）${NC}"
        exit 1
    }

    mkdir -p "$HOME/Library/LaunchAgents" "$BRIDGE_DIR/logs"

    # 已安装则先备份
    if [ -f "$PLIST_INSTALL_PATH" ]; then
        local backup="${PLIST_INSTALL_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$PLIST_INSTALL_PATH" "$backup"
        echo -e "  ${YELLOW}⚠${NC} 已有 plist，备份到 $backup"
        # 先 unload 旧的（忽略失败）
        launchctl unload "$PLIST_INSTALL_PATH" 2>/dev/null || true
    fi

    render_plist "$template" "$PLIST_INSTALL_PATH"
    # 校验 plist 合法性，失败就回滚
    if ! plutil -lint "$PLIST_INSTALL_PATH" >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} 渲染后的 plist 校验失败，请检查模板"
        rm -f "$PLIST_INSTALL_PATH"
        exit 1
    fi

    # 如果当前有手工启动的 daemon，先停掉再交给 launchd（避免双实例被 PID lock 互相挡）
    if is_daemon_running; then
        echo -e "  ${YELLOW}⚠${NC} 检测到手工启动的 daemon，先停止再交给 launchd 接管"
        kill_daemon 2>/dev/null || true
    fi

    launchctl load "$PLIST_INSTALL_PATH"
    echo -e "  ${GREEN}✓${NC} 已加载 launchd service：$LAUNCHD_LABEL"
    echo -e "  ${GREEN}✓${NC} 开机自启 + 崩溃自恢复已生效"
    echo -e "  日志位置：$BRIDGE_DIR/logs/launchd-{stdout,stderr}.log"

    sleep 2
    if is_daemon_running; then
        echo -e "  ${GREEN}✓${NC} daemon 已通过 launchd 运行 (PID=$(cat "$PID_FILE" 2>/dev/null | head -1))"
    else
        echo -e "  ${YELLOW}⚠${NC} daemon 尚未启动，可通过 ${CYAN}fb service logs${NC} 查看 launchd 错误"
    fi
}

cmd_service_uninstall() {
    if [ ! -f "$PLIST_INSTALL_PATH" ]; then
        echo -e "${YELLOW}未安装 launchd service（$PLIST_INSTALL_PATH 不存在）${NC}"
        return 0
    fi
    launchctl unload "$PLIST_INSTALL_PATH" 2>/dev/null || true
    rm -f "$PLIST_INSTALL_PATH"
    echo -e "${GREEN}✓ 已卸载 launchd service${NC}"
    echo -e "  ${BLUE}说明${NC}：数据目录 $BRIDGE_DIR 保留；如需彻底清理请参考 install.sh --uninstall"
}

cmd_service_start() {
    if [ ! -f "$PLIST_INSTALL_PATH" ]; then
        echo -e "${RED}未安装 launchd service，请先运行 ${CYAN}fb service install${NC}"
        exit 1
    fi
    launchctl start "$LAUNCHD_LABEL"
    echo -e "${GREEN}✓ 已请求 launchd 启动 $LAUNCHD_LABEL${NC}"
}

cmd_service_stop() {
    if [ ! -f "$PLIST_INSTALL_PATH" ]; then
        echo -e "${YELLOW}未安装 launchd service${NC}"
        return 0
    fi
    launchctl stop "$LAUNCHD_LABEL"
    echo -e "${GREEN}✓ 已请求 launchd 停止 $LAUNCHD_LABEL${NC}"
    echo -e "  ${YELLOW}注意${NC}：plist 的 KeepAlive.Crashed=true，daemon 可能被再次拉起。彻底停止请用 ${CYAN}fb service uninstall${NC}"
}

cmd_service_status() {
    if [ ! -f "$PLIST_INSTALL_PATH" ]; then
        echo -e "launchd service: ${YELLOW}未安装${NC}"
        return 0
    fi
    if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then
        echo -e "launchd service: ${GREEN}已加载${NC}"
        launchctl list "$LAUNCHD_LABEL" | sed 's/^/  /'
    else
        echo -e "launchd service: ${YELLOW}已安装但未加载${NC}"
    fi
}

cmd_service_logs() {
    local which="${1:-out}" file
    case "$which" in
        out|stdout) file="$BRIDGE_DIR/logs/launchd-stdout.log" ;;
        err|stderr) file="$BRIDGE_DIR/logs/launchd-stderr.log" ;;
        *)
            echo "用法: fb service logs [out|err]  (默认 out)"
            return 1
            ;;
    esac
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}日志文件尚不存在：$file${NC}"
        return 0
    fi
    tail -n 50 "$file"
}

cmd_service() {
    local sub="${1:-}"
    case "$sub" in
        install)    cmd_service_install ;;
        uninstall)  cmd_service_uninstall ;;
        start)      cmd_service_start ;;
        stop)       cmd_service_stop ;;
        status)     cmd_service_status ;;
        logs)       shift; cmd_service_logs "$@" ;;
        ""|help|-h|--help)
            cat <<EOF
用法: fb service {install|uninstall|start|stop|status|logs [out|err]}

  install    将 daemon 注册为 launchd user agent（开机自启 + 崩溃恢复）
  uninstall  卸载 launchd service，保留数据目录
  start      请求 launchd 启动 daemon（已有 KeepAlive 通常不需要）
  stop       请求 launchd 停止 daemon（Crashed=true 可能立即重启）
  status     查看 launchd 加载状态
  logs [out|err]  打印 launchd stdout/stderr 日志最后 50 行
EOF
            ;;
        *)
            echo "未知 service 子命令: $sub"
            echo "运行 fb service help 查看用法"
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# init 子命令：交互引导配置
# ─────────────────────────────────────────────

cmd_init() {
    local open_id_flag='' merge_flag='ask' force=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --open-id)     open_id_flag="$2"; shift 2 ;;
            --merge-hooks) merge_flag="$2";   shift 2 ;;
            --force)       force=1;           shift ;;
            -h|--help)
                echo "用法: $0 init [--open-id OU_xxx] [--merge-hooks yes|no|ask] [--force]"
                exit 0
                ;;
            *) echo "未知参数: $1"; exit 1 ;;
        esac
    done

    mkdir -p "$BRIDGE_DIR"

    echo "👋 欢迎使用 cursor-lark-bridge"
    echo ""
    step_lark_cli_check
    step_collect_open_id "$open_id_flag" "$force"
    step_merge_hooks_json "$merge_flag"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🎉 配置完成！下一步：${NC}"
    echo ""
    echo -e "   ${CYAN}fb start${NC}   # 激活远程模式（会向飞书发送测试卡片）"
    echo -e "   ${CYAN}fb status${NC}  # 查看 daemon 状态"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

step_lark_cli_check() {
    echo -e "${BLUE}━ Step 1 / 3 · lark-cli 检查 ━━━━━━━━━━━━━━━${NC}"
    if command -v lark-cli >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} 找到 lark-cli: $(lark-cli --version 2>&1 | head -1)"
    else
        echo -e "  ${RED}✗${NC} 未找到 lark-cli"
        echo "    请先安装 lark-cli 并完成配置："
        echo -e "      ${CYAN}lark-cli config init${NC}"
        exit 1
    fi
    echo ""
}

step_collect_open_id() {
    local flag="$1" force="$2"
    local open_id="" user_name="" app_id=""

    echo -e "${BLUE}━ Step 2 / 3 · 配置接收消息的 open_id ━━━━━━━━${NC}"

    # 情形 A：已存在 config.json 且未 --force、未 --open-id ——保留不动
    if [ -z "$flag" ] && [ -f "$BRIDGE_DIR/config.json" ] && [ "$force" = "0" ]; then
        local current
        current=$(python3 -c "import json; print(json.load(open('$BRIDGE_DIR/config.json')).get('open_id','<empty>'))" 2>/dev/null || echo '<invalid>')
        echo -e "  ${YELLOW}⚠${NC} 已存在 config.json（当前 open_id: $current）"
        echo -e "     要覆盖请加 ${CYAN}--force${NC}"
        echo ""
        return 0
    fi

    # 情形 B：命令行直接指定 --open-id
    if [ -n "$flag" ]; then
        open_id="$flag"
        echo -e "  ${CYAN}ℹ${NC} 使用命令行指定的 open_id：$open_id"
    else
        # 情形 C：自动探测 lark-cli 当前身份 → 取 open_id
        echo "  尝试从 lark-cli 自动探测（保证 open_id 与 daemon 发消息用的应用一致，避免 'open_id cross app'）..."

        if command -v lark-cli >/dev/null 2>&1; then
            # 当前 lark-cli 绑定的应用 ID（非致命，取不到不阻断）
            app_id=$(lark-cli auth scopes 2>/dev/null | grep -oE 'cli_[a-z0-9]+' | head -1 || true)

            # 当前登录用户在这个应用下的 profile
            local profile
            profile=$(lark-cli contact +get-user 2>/dev/null || true)
            if [ -n "$profile" ]; then
                open_id=$(printf '%s' "$profile" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('data', {}).get('user', {}).get('open_id', ''))
except Exception:
    pass
" 2>/dev/null || true)
                user_name=$(printf '%s' "$profile" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    u = d.get('data', {}).get('user', {})
    print(u.get('name') or u.get('en_name') or '')
except Exception:
    pass
" 2>/dev/null || true)
            fi
        fi

        local auto_ok=0
        if [ -n "$open_id" ]; then
            auto_ok=1
            echo ""
            echo -e "  ${GREEN}✓${NC} 已探测到飞书身份："
            [ -n "$user_name" ] && echo -e "      姓名     : $user_name"
            echo -e "      open_id  : $open_id"
            [ -n "$app_id" ]   && echo -e "      所属应用 : $app_id"
            echo ""
            local yn
            read -r -p "? 使用这个 open_id 吗？[Y/n]: " yn
            case "$yn" in
                n|N|no|No|NO) open_id="" ;;  # 用户否决 → 回落到手工粘贴
            esac
        fi

        # 情形 D：自动失败 or 用户否决 → 手工粘贴
        if [ -z "$open_id" ]; then
            echo ""
            if [ "$auto_ok" = "1" ]; then
                echo -e "  ${CYAN}ℹ${NC} 已放弃自动探测结果，请手动粘贴一个 open_id："
            else
                echo -e "  ${YELLOW}⚠${NC} 无法自动探测（可能未跑过 ${CYAN}lark-cli auth login${NC}）。请手动粘贴："
                echo -e "     ${CYAN}lark-cli auth login${NC}                  # 第一次用需要 OAuth 登录"
                echo -e "     ${CYAN}lark-cli contact +get-user${NC}           # 输出 JSON 里 data.user.open_id 就是"
            fi
            echo ""
            read -r -p "? 粘贴你的 open_id: " open_id
        fi
    fi

    # 软校验（只警告不阻断）
    if ! echo "$open_id" | grep -qE '^ou_[a-f0-9]{32}$'; then
        echo -e "  ${YELLOW}⚠${NC} '$open_id' 不像标准的 ou_[32 hex] 格式，已保存但请核对"
    fi

    OPEN_ID="$open_id" python3 -c "
import json, os
json.dump({'open_id': os.environ['OPEN_ID']},
          open(os.environ['HOME'] + '/.cursor/cursor-lark-bridge/config.json', 'w'),
          indent=2)
" > /dev/null
    echo -e "  ${GREEN}✓${NC} 已保存到 $BRIDGE_DIR/config.json"
    echo ""
}

step_merge_hooks_json() {
    local merge_flag="$1"
    echo -e "${BLUE}━ Step 3 / 3 · Cursor hooks.json 合并 ━━━━━━━${NC}"

    # 定位 hooks-additions.json: 先找已安装路径，再 fallback 到仓库路径
    local additions=""
    for candidate in \
        "$BRIDGE_DIR/hooks-additions.json" \
        "$SCRIPT_DIR/../config/hooks-additions.json" \
        "$SCRIPT_DIR/hooks-additions.json"; do
        if [ -f "$candidate" ]; then
            additions="$candidate"
            break
        fi
    done
    if [ -z "$additions" ]; then
        echo -e "  ${RED}✗${NC} 找不到 hooks-additions.json（请检查安装完整性）"
        exit 1
    fi

    # 定位 hooks-merge.py
    local merger=""
    for candidate in \
        "$BRIDGE_DIR/hooks-merge.py" \
        "$SCRIPT_DIR/hooks-merge.py" \
        "$SCRIPT_DIR/../scripts/hooks-merge.py"; do
        if [ -f "$candidate" ]; then
            merger="$candidate"
            break
        fi
    done
    if [ -z "$merger" ]; then
        echo -e "  ${RED}✗${NC} 找不到 hooks-merge.py"
        exit 1
    fi

    local hooks_json="$HOME/.cursor/hooks.json"
    local suffix
    suffix=$(date +%Y-%m-%d-%H%M%S)

    case "$merge_flag" in
        yes|Y|y)
            python3 "$merger" --existing "$hooks_json" --additions "$additions" --backup-suffix "$suffix" --apply
            ;;
        no|N|n)
            echo "  已跳过。请手动将下列片段合并进 $hooks_json："
            echo ""
            cat "$additions"
            ;;
        ask|*)
            echo "下面是将要应用的变更（diff）："
            echo ""
            python3 "$merger" --existing "$hooks_json" --additions "$additions" --backup-suffix "$suffix" --show-diff
            echo ""
            read -r -p "? 应用？  [Y]是 / [n]否 / [s]跳过并打印片段 : " ans
            case "$ans" in
                ''|Y|y|Yes|yes)
                    python3 "$merger" --existing "$hooks_json" --additions "$additions" --backup-suffix "$suffix" --apply
                    ;;
                s|S|skip)
                    echo "  请手动合并以下片段到 $hooks_json："
                    echo ""
                    cat "$additions"
                    ;;
                *) echo "  已取消。" ;;
            esac
            ;;
    esac
}

# ─────────────────────────────────────────────
# 主分发
# ─────────────────────────────────────────────

case "${1:-}" in
    init)
        shift
        cmd_init "$@"
        ;;
    start)
        start_daemon
        activate_remote
        echo -e "\n${GREEN}你现在可以离开电脑了。所有 Cursor 交互将通过飞书完成。${NC}"
        echo -e "回来后运行: ${BLUE}fb stop${NC}"
        ;;
    stop)
        deactivate_remote
        ;;
    kill)
        deactivate_remote 2>/dev/null
        kill_daemon
        ;;
    restart)
        deactivate_remote 2>/dev/null
        kill_daemon
        start_daemon
        activate_remote
        ;;
    status)
        show_status
        ;;
    doctor)
        shift
        cmd_doctor "$@"
        ;;
    service)
        shift
        cmd_service "$@"
        ;;
    *)
        echo "用法: $0 {init|start|stop|kill|restart|status|doctor|service}"
        echo ""
        echo "  init    — 首次引导配置（open_id + hooks.json 合并）"
        echo "  start   — 启动 daemon 并激活远程模式"
        echo "  stop    — 关闭远程模式（daemon 保持运行）"
        echo "  kill    — 停止 daemon 进程"
        echo "  restart — 重启 daemon 并激活远程模式"
        echo "  status  — 查看当前状态"
        echo "  doctor  — 诊断冲突进程，加 --fix 可一键修复"
        echo "  service — 安装 launchd 自启 + 崩溃恢复，见 'fb service help'"
        exit 1
        ;;
esac
