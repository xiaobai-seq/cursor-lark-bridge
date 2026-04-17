#!/usr/bin/env bash
# cursor-lark-bridge installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
#
# Environment knobs:
#   VERSION=v0.1.0            # pin a specific release tag (default: latest)
#   BUILD_FROM_SOURCE=1       # skip release download, clone repo & go build
#   INSTALL_PREFIX=~/.local   # where to place `fb` symlink (default: ~/.local/bin)
#   GITHUB_USER=xiaobai-seq   # override the repo owner (for forks)
#   GITHUB_REPO=cursor-lark-bridge
#
# Subcommands:
#   ./install.sh                 # install
#   ./install.sh --uninstall     # remove everything

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-xiaobai-seq}"
GITHUB_REPO="${GITHUB_REPO:-cursor-lark-bridge}"
VERSION="${VERSION:-}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"

BRIDGE_DIR="$HOME/.cursor/cursor-lark-bridge"
DAEMON_DIR="$BRIDGE_DIR/daemon"
HOOKS_DIR="$HOME/.cursor/hooks/cursor-lark-bridge"
FB_BIN="$INSTALL_PREFIX/bin/fb"

# NOTE: use ANSI-C quoting ($'...') so \033 becomes the real ESC byte.
# Otherwise heredoc-based banners would print the literal string \033[...
RED=$'\033[0;31m';  GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m';   NC=$'\033[0m'

log()  { printf '%b\n' "$*"; }
step() { printf "\n${BLUE}▶ %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; }
die()  { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ─────────────────────────────────────────────
# uninstall
# ─────────────────────────────────────────────

do_uninstall() {
    step "Uninstalling cursor-lark-bridge"

    if command -v fb >/dev/null 2>&1; then
        fb stop 2>/dev/null || true
        fb kill 2>/dev/null || true
    fi

    [ -L "$FB_BIN" ] && rm -f "$FB_BIN" && ok "removed $FB_BIN"
    if [ -d "$BRIDGE_DIR" ]; then
        rm -rf "$BRIDGE_DIR" && ok "removed $BRIDGE_DIR"
    fi
    if [ -d "$HOOKS_DIR" ]; then
        rm -rf "$HOOKS_DIR" && ok "removed $HOOKS_DIR"
    fi

    warn "~/.cursor/hooks.json may still contain cursor-lark-bridge entries."
    warn "Inspect and remove them manually if desired:"
    log  "    grep cursor-lark-bridge ~/.cursor/hooks.json"
    log  ""
    ok "uninstall complete"
    exit 0
}

# ─────────────────────────────────────────────
# prerequisites
# ─────────────────────────────────────────────

check_prereqs() {
    step "Checking prerequisites"
    local missing=0
    for bin in bash curl python3 tar; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            die "$bin not found (please install it first)"
        fi
        ok "$bin present"
    done

    if ! command -v lark-cli >/dev/null 2>&1; then
        warn "lark-cli not found — required at runtime (daemon uses it to talk to Feishu)."
        warn "see: https://github.com/larksuite/lark-cli"
        missing=1
    else
        ok "lark-cli present: $(lark-cli --version 2>&1 | head -1)"
    fi

    if [ "$BUILD_FROM_SOURCE" = "1" ]; then
        if ! command -v go >/dev/null 2>&1; then
            die "BUILD_FROM_SOURCE=1 requires Go toolchain (https://go.dev/dl/)"
        fi
        ok "go present: $(go version | awk '{print $3}')"
    fi

    if [ "$missing" = "1" ]; then
        warn "continuing anyway — you can install lark-cli later"
    fi
}

# 检测老版 feishu-bridge 残留（项目 v0.1.0 之前叫这个名字）
# 不做自动清理，避免误伤用户手动维护的老进程；给出明确指引后让用户决定
#
# 关键细节：pgrep -f 会匹配整条 cmdline，当某个 shell 脚本的参数里恰好带有
# "feishu-bridge-daemon" 字符串（比如本脚本自己）时也会被命中——所以需要通过
# ps -o comm= 过滤掉 basename 是 bash/sh/zsh 等解释器的候选 PID。
check_legacy_feishu_bridge() {
    step "Checking for legacy feishu-bridge (pre-rename) residue"

    local candidates real_pids="" pid comm base
    candidates=$(pgrep -f 'feishu-bridge-daemon|feishu-bridge/daemon' 2>/dev/null || true)
    for pid in $candidates; do
        [ "$pid" = "$$" ] && continue
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        [ -z "$comm" ] && continue
        base="${comm##*/}"
        case "$base" in
            bash|sh|zsh|fish|dash|ksh|pgrep|grep|ps|awk|sed|tr|wc|head|tail|xargs|cat|echo|curl) continue ;;
        esac
        real_pids+="${real_pids:+ }$pid"
    done

    local has_proc=0 has_dir=0
    [ -n "$real_pids" ] && has_proc=1
    [ -d "$HOME/.cursor/feishu-bridge" ] && has_dir=1

    if [ "$has_proc" = "0" ] && [ "$has_dir" = "0" ]; then
        ok "no legacy feishu-bridge residue"
        return
    fi

    warn "Detected leftover from the old 'feishu-bridge' project (renamed to cursor-lark-bridge)."
    if [ "$has_proc" = "1" ]; then
        printf "    legacy process(es):\n"
        for pid in $real_pids; do
            ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/      /'
        done
    fi
    if [ "$has_dir" = "1" ]; then
        printf "    legacy directory: %s\n" "$HOME/.cursor/feishu-bridge"
    fi
    echo
    warn "These will collide with cursor-lark-bridge on port 19836 and silently break it."
    warn "Please clean up BEFORE continuing:"
    [ "$has_proc" = "1" ] && log  "    ${CYAN}kill -9 $real_pids${NC}"
    [ "$has_dir" = "1" ] && log  "    ${CYAN}rm -rf ~/.cursor/feishu-bridge${NC}    # optional"
    echo
    if [ -t 0 ] && [ -z "${CI:-}" ]; then
        # 终端交互：给用户机会决定是否继续
        printf "${YELLOW}Continue installation anyway? [y/N] ${NC}"
        local ans=""
        read -r ans || true
        if [ "${ans:-n}" != "y" ] && [ "${ans:-n}" != "Y" ]; then
            die "aborted by user"
        fi
    else
        warn "not running interactively — will continue, but expect port-bind conflicts"
    fi
}

# ─────────────────────────────────────────────
# platform detection
# ─────────────────────────────────────────────

detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) die "unsupported arch: $arch (only amd64 / arm64 are supported)" ;;
    esac
    case "$os" in
        darwin|linux) : ;;
        *) die "unsupported os: $os (only darwin / linux are supported)" ;;
    esac
    PLATFORM_OS="$os"
    PLATFORM_ARCH="$arch"
    ok "platform: ${os}_${arch}"
}

# ─────────────────────────────────────────────
# fetch latest version
# ─────────────────────────────────────────────

resolve_version() {
    if [ -n "$VERSION" ]; then
        ok "pinned version: $VERSION"
        return
    fi
    step "Resolving latest release"
    local api="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/releases/latest"
    VERSION=$(curl -fsSL "$api" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)
    if [ -z "$VERSION" ]; then
        warn "could not determine latest release (no releases yet?)"
        warn "→ falling back to build-from-source"
        BUILD_FROM_SOURCE=1
        return
    fi
    ok "latest version: $VERSION"
}

# ─────────────────────────────────────────────
# download + extract release archive
# ─────────────────────────────────────────────

download_release() {
    step "Downloading release archive"
    local ver_trimmed="${VERSION#v}"
    local archive="${GITHUB_REPO}_${ver_trimmed}_${PLATFORM_OS}_${PLATFORM_ARCH}.tar.gz"
    local url="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${VERSION}/${archive}"
    local sumurl="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/download/${VERSION}/checksums.txt"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT

    log "  URL: $url"
    if ! curl -fsSL "$url" -o "$tmp/$archive"; then
        warn "download failed (is the release published for this platform?)"
        warn "→ falling back to build-from-source"
        BUILD_FROM_SOURCE=1
        return
    fi
    ok "downloaded $archive"

    # checksum is best-effort
    if curl -fsSL "$sumurl" -o "$tmp/checksums.txt" 2>/dev/null; then
        if (cd "$tmp" && grep -F "$archive" checksums.txt | shasum -a 256 -c - >/dev/null 2>&1); then
            ok "checksum verified"
        else
            warn "checksum mismatch or shasum missing — proceeding anyway"
        fi
    fi

    tar -xzf "$tmp/$archive" -C "$tmp"
    EXTRACTED_DIR="$tmp"
}

# ─────────────────────────────────────────────
# build from source (fallback)
# ─────────────────────────────────────────────

build_from_source() {
    step "Building from source"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT

    log "  cloning https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
    if ! git clone --depth 1 "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "$tmp/src" 2>&1; then
        die "git clone failed"
    fi
    log "  compiling daemon (go build)"
    (cd "$tmp/src/daemon" \
        && go build -ldflags="-X main.version=source-$(date +%Y%m%d)" \
             -o cursor-lark-bridge-daemon .) \
        || die "go build failed"

    EXTRACTED_DIR="$tmp/src"
    # move the just-built binary into the archive layout for deploy_files to find it
    cp "$tmp/src/daemon/cursor-lark-bridge-daemon" "$tmp/cursor-lark-bridge-daemon"
    ok "built cursor-lark-bridge-daemon"
}

# ─────────────────────────────────────────────
# deploy files onto the host
# ─────────────────────────────────────────────

deploy_files() {
    step "Deploying files"
    mkdir -p "$BRIDGE_DIR" "$DAEMON_DIR" "$HOOKS_DIR" "$INSTALL_PREFIX/bin"

    # daemon binary — look in two well-known spots left by download_release / build_from_source
    local bin_src=""
    for c in "$EXTRACTED_DIR/cursor-lark-bridge-daemon" "$EXTRACTED_DIR/daemon/cursor-lark-bridge-daemon"; do
        if [ -f "$c" ]; then bin_src="$c"; break; fi
    done
    [ -n "$bin_src" ] || die "daemon binary not found inside archive"
    install -m 0755 "$bin_src" "$DAEMON_DIR/cursor-lark-bridge-daemon"
    ok "installed daemon → $DAEMON_DIR/cursor-lark-bridge-daemon"

    # scripts
    install -m 0755 "$EXTRACTED_DIR/scripts/bridge.sh"       "$BRIDGE_DIR/bridge.sh"
    install -m 0755 "$EXTRACTED_DIR/scripts/hooks-merge.py"  "$BRIDGE_DIR/hooks-merge.py"
    ok "installed bridge.sh + hooks-merge.py"

    # hooks-additions.json (used later by `fb init`)
    install -m 0644 "$EXTRACTED_DIR/config/hooks-additions.json" "$BRIDGE_DIR/hooks-additions.json"
    ok "installed hooks-additions.json"

    # hook scripts
    for f in "$EXTRACTED_DIR"/hooks/*.sh "$EXTRACTED_DIR"/hooks/*.py; do
        [ -f "$f" ] || continue
        install -m 0755 "$f" "$HOOKS_DIR/$(basename "$f")"
    done
    ok "installed $(ls "$HOOKS_DIR" | wc -l | tr -d ' ') hook scripts → $HOOKS_DIR"

    # config.json — never overwrite user's data; just place an example
    if [ -f "$BRIDGE_DIR/config.json" ]; then
        warn "existing config.json preserved"
    else
        install -m 0600 "$EXTRACTED_DIR/config/config.json.example" "$BRIDGE_DIR/config.json.example"
        ok "placed config template → $BRIDGE_DIR/config.json.example"
    fi

    # fb symlink
    ln -sfn "$BRIDGE_DIR/bridge.sh" "$FB_BIN"
    ok "linked $FB_BIN → $BRIDGE_DIR/bridge.sh"

    # warn if INSTALL_PREFIX not on PATH
    case ":$PATH:" in
        *":$INSTALL_PREFIX/bin:"*) : ;;
        *) warn "$INSTALL_PREFIX/bin is NOT on your PATH — add it so \`fb\` is reachable."
           log  "    echo 'export PATH=\"$INSTALL_PREFIX/bin:\$PATH\"' >> ~/.bashrc" ;;
    esac
}

# ─────────────────────────────────────────────
# final banner
# ─────────────────────────────────────────────

print_next_steps() {
    cat <<BANNER

${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}${BOLD}  Installation complete${NC}
${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

Next steps:

  1. Configure: ${CYAN}fb init${NC}
     (will ask for your Feishu open_id and merge Cursor hooks.json)

  2. Activate:  ${CYAN}fb start${NC}
     (sends an activation card to your Feishu chat)

  3. Check:     ${CYAN}fb status${NC}

Uninstall later with:

  ${CYAN}$FB_BIN --uninstall${NC}    # or re-run install.sh --uninstall

BANNER
}

# ─────────────────────────────────────────────
# main
# ─────────────────────────────────────────────

main() {
    if [ "${1:-}" = "--uninstall" ]; then
        do_uninstall
    fi

    log "${BOLD}cursor-lark-bridge installer${NC}  (repo: ${GITHUB_USER}/${GITHUB_REPO})"
    check_prereqs
    check_legacy_feishu_bridge
    detect_platform

    if [ "$BUILD_FROM_SOURCE" = "0" ]; then
        resolve_version
        if [ "$BUILD_FROM_SOURCE" = "0" ]; then
            download_release
        fi
    fi
    if [ "$BUILD_FROM_SOURCE" = "1" ]; then
        build_from_source
    fi

    deploy_files
    print_next_steps
}

main "$@"
