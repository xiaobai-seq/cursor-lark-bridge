#!/bin/bash
# 离线生成 4 张 V2 斜杠命令卡片样例 JSON。
# 输出到 tests/slash-samples/，供 CP5 用户用飞书"卡片预览"工具可视化。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/slash-samples"
DAEMON_DIR="$REPO_ROOT/daemon"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
die()  { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 用一次性 go test 文件触发 buildXxxCard 并把结果 WriteFile 到 OUT_DIR
TMP_TEST="$DAEMON_DIR/zz_sample_cards_test.go"
trap 'rm -f "$TMP_TEST"' EXIT

cat > "$TMP_TEST" <<'EOF'
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 这个 test 文件由 tests/p2-slash-card-sample.sh 临时放置，跑完就删
// 用 go test 的正常机制来触发 buildXxxCard 并 dump JSON
func TestDumpSlashSamples(t *testing.T) {
	outDir := os.Getenv("SLASH_SAMPLES_OUT")
	if outDir == "" {
		t.Skip("SLASH_SAMPLES_OUT 未设置，跳过样例生成")
	}
	d := newTestDaemon()
	d.baseDir = t.TempDir()

	// 样例 1: 空 /status
	writeSample(t, outDir, "status-empty.json", buildStatusCard(d))

	// 样例 2: /status 有 3 条 pending
	now := time.Now().Unix()
	d.pending["p1"] = &pendingEntry{
		reply: make(chan string, 1), id: "p1", kind: "shell",
		summary: "npm test", workspace: "myapp",
		agent: "myapp · #ab12cd34", createdTS: now - 120,
	}
	d.pending["p2"] = &pendingEntry{
		reply: make(chan string, 1), id: "p2", kind: "mcp",
		summary: "linear.list-issues", workspace: "myapp",
		agent: "myapp · #ab12cd34", createdTS: now - 45,
	}
	d.pending["p3"] = &pendingEntry{
		reply: make(chan string, 1), id: "p3", kind: "ask",
		summary:   "选择一个选项",
		createdTS: now - 5,
	}
	writeSample(t, outDir, "status-with-pending.json", buildStatusCard(d))

	// 样例 3: /stop 取消 3 条
	views, sent := d.stopAllPending()
	writeSample(t, outDir, "stop-cancelled.json", buildStopCancelCard(views, sent))

	// 样例 4: /help
	writeSample(t, outDir, "help.json", buildHelpCard(slashRegistry))
}

func writeSample(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content+"\n"), 0644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}
EOF

echo "生成斜杠卡片样例 → $OUT_DIR/"
(cd "$DAEMON_DIR" && SLASH_SAMPLES_OUT="$OUT_DIR" go test -run TestDumpSlashSamples -count=1 ./...) >/dev/null || die "go test 生成样例失败"

# 清理临时 test 文件（trap 会兜底，但显式 rm 更快）
rm -f "$TMP_TEST"
trap - EXIT

ls -1 "$OUT_DIR"/*.json > /dev/null 2>&1 || die "未生成样例文件"

for f in "$OUT_DIR"/*.json; do
    python3 -c "import json,sys; json.loads(open('$f').read())" \
        || die "$f 不是合法 JSON"
    ok "$(basename "$f") ($(wc -c <"$f" | tr -d ' ') 字节)"
done

echo ""
echo "下一步：用飞书开发者后台的 \"卡片搭建工具\" 打开 tests/slash-samples/*.json 可视化预览"
