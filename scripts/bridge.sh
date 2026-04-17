#!/bin/bash
# cursor-lark-bridge 控制脚本
# 用法:
#   bridge.sh init    — 首次引导配置（open_id + hooks.json 合并）
#   bridge.sh start   — 启动 daemon 并激活远程模式
#   bridge.sh stop    — 关闭远程模式（daemon 保持运行）
#   bridge.sh kill    — 停止 daemon 进程
#   bridge.sh status  — 查看状态
#   bridge.sh restart — 重启 daemon

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
    else
        build_daemon
        echo -e "${BLUE}启动 daemon...${NC}"
        mkdir -p "$BRIDGE_DIR"
        nohup "$DAEMON_BIN" >> "$LOG_FILE" 2>&1 &
        sleep 1
        if is_daemon_running; then
            echo -e "${GREEN}daemon 已启动 (PID=$(cat "$PID_FILE"))${NC}"
        else
            echo -e "${RED}daemon 启动失败，查看日志: $LOG_FILE${NC}"
            exit 1
        fi
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
    # 清理可能残留的 lark-cli event +subscribe 进程
    pkill -f "lark-cli event .subscribe.*--as bot" 2>/dev/null

    if is_daemon_running; then
        pid=$(cat "$PID_FILE")
        echo -e "${BLUE}停止 daemon (PID=$pid)...${NC}"
        kill "$pid" 2>/dev/null
        sleep 1
        if is_daemon_running; then
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        echo -e "${GREEN}daemon 已停止${NC}"
    else
        echo -e "${YELLOW}daemon 未在运行${NC}"
        rm -f "$PID_FILE"
    fi
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
    if [ $? -eq 0 ] && [ -n "$health" ]; then
        active=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',False))" 2>/dev/null)
        event_running=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('event_running',False))" 2>/dev/null)
        ver=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null)
        echo -e "Version:     $ver"
        if [ "$active" = "True" ]; then
            echo -e "远程模式:    ${GREEN}已激活${NC}"
        else
            echo -e "远程模式:    ${YELLOW}未激活${NC}"
        fi
        if [ "$event_running" = "True" ]; then
            echo -e "事件订阅:    ${GREEN}运行中${NC}"
        else
            echo -e "事件订阅:    ${RED}未运行${NC}"
        fi
    else
        echo -e "HTTP API:    ${RED}无法连接${NC}"
    fi
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
    *)
        echo "用法: $0 {init|start|stop|kill|restart|status}"
        echo ""
        echo "  init    — 首次引导配置（open_id + hooks.json 合并）"
        echo "  start   — 启动 daemon 并激活远程模式"
        echo "  stop    — 关闭远程模式（daemon 保持运行）"
        echo "  kill    — 停止 daemon 进程"
        echo "  restart — 重启 daemon 并激活远程模式"
        echo "  status  — 查看当前状态"
        exit 1
        ;;
esac
