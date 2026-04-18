package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestStatusCommandMetadata(t *testing.T) {
	c := &statusCommand{}
	if c.Name() != "status" {
		t.Errorf("Name() = %q", c.Name())
	}
	aliases := c.Aliases()
	if len(aliases) != 1 || aliases[0] != "/状态" {
		t.Errorf("Aliases() = %v", aliases)
	}
	if !c.Match("status") {
		t.Errorf("Match(status) 应 true")
	}
	if !c.Match("状态") {
		t.Errorf("Match(状态) 应 true")
	}
	if c.Match("ping") {
		t.Errorf("Match(ping) 应 false")
	}
}

func TestKindIcon(t *testing.T) {
	cases := map[string]string{
		"shell":       "🖥️",
		"mcp":         "🔧",
		"ask":         "❓",
		"askQuestion": "❓",
		"switchMode":  "🔀",
		"mode_switch": "🔀",
		"stop":        "⏸",
		"unknown":     "📌",
		"":            "📌",
	}
	for kind, want := range cases {
		got := kindIcon(kind)
		if got != want {
			t.Errorf("kindIcon(%q) = %q, want %q", kind, got, want)
		}
	}
}

func TestFormatPendingLine(t *testing.T) {
	now := int64(1710489700)
	v := PendingView{
		ID:        "req-1",
		Kind:      "shell",
		Summary:   "npm test",
		Workspace: "myproject",
		Agent:     "myproject · #abc",
		CreatedTS: now - 90, // 等了 1m30s
	}
	line := formatPendingLine(v, now)
	// 必须包含 icon / summary / 等待时长 / workspace / agent
	for _, want := range []string{"🖥️", "**npm test**", "等待 1m30s", "[myproject]", "myproject · #abc"} {
		if !strings.Contains(line, want) {
			t.Errorf("line 缺 %q: %q", want, line)
		}
	}
}

func TestFormatPendingLineOptionalFields(t *testing.T) {
	now := int64(1710489700)
	v := PendingView{
		ID:        "req-2",
		Kind:      "ask",
		Summary:   "choose option",
		CreatedTS: now - 5,
	}
	line := formatPendingLine(v, now)
	if strings.Contains(line, "workspace") || strings.Contains(line, "[]") {
		t.Errorf("workspace 为空不应渲染: %q", line)
	}
	if !strings.Contains(line, "❓") {
		t.Errorf("ask 应用 ❓ 图标: %q", line)
	}
}

func TestBuildStatusCard_Empty(t *testing.T) {
	d := newTestDaemon()
	d.baseDir = t.TempDir() // 空 pid 文件 → readPIDFile 返回 nil
	jsonStr := buildStatusCard(d)

	var card map[string]interface{}
	if err := json.Unmarshal([]byte(jsonStr), &card); err != nil {
		t.Fatalf("卡片 JSON 无效: %v", err)
	}
	// header.template == blue
	hdr := card["header"].(map[string]interface{})
	if hdr["template"] != "blue" {
		t.Errorf("template = %v", hdr["template"])
	}
	// 标题含 version
	title := hdr["title"].(map[string]interface{})["content"].(string)
	if !strings.Contains(title, version) {
		t.Errorf("title 缺 version: %q", title)
	}
	// 空 pending 含 "当前无待处理操作"
	if !strings.Contains(jsonStr, "当前无待处理操作") {
		t.Errorf("空 pending 卡片缺提示: %q", jsonStr)
	}
}

func TestBuildStatusCard_WithPending(t *testing.T) {
	d := newTestDaemon()
	d.baseDir = t.TempDir()
	now := time.Now().Unix()
	d.pending["req-1"] = &pendingEntry{
		reply:     make(chan string, 1),
		id:        "req-1",
		kind:      "shell",
		summary:   "cd /proj && npm test",
		workspace: "myproject",
		createdTS: now - 120,
	}
	d.pending["req-2"] = &pendingEntry{
		reply:     make(chan string, 1),
		id:        "req-2",
		kind:      "mcp",
		summary:   "linear.list-issues",
		createdTS: now - 30,
	}
	jsonStr := buildStatusCard(d)

	// 按 createdTS 升序：req-1 应在 req-2 之前出现
	iReq1 := strings.Index(jsonStr, "cd /proj && npm test")
	iReq2 := strings.Index(jsonStr, "linear.list-issues")
	if iReq1 < 0 || iReq2 < 0 {
		t.Fatalf("卡片 missing 期望 summary: %q", jsonStr)
	}
	if iReq1 >= iReq2 {
		t.Errorf("req-1 (createdTS 更早) 应排在 req-2 前")
	}

	// 不应出现"当前无待处理操作"
	if strings.Contains(jsonStr, "当前无待处理操作") {
		t.Errorf("有 pending 时不应出现空提示")
	}

	// 两个 kind 图标都要在
	if !strings.Contains(jsonStr, "🖥️") || !strings.Contains(jsonStr, "🔧") {
		t.Errorf("缺 kind 图标: %q", jsonStr)
	}

	// 底部提示
	if !strings.Contains(jsonStr, "/stop 取消全部") {
		t.Errorf("缺底部 note: %q", jsonStr)
	}
}

func TestBuildStatusCard_Truncation(t *testing.T) {
	d := newTestDaemon()
	d.baseDir = t.TempDir()
	now := time.Now().Unix()
	// 12 条 pending
	for i := 0; i < 12; i++ {
		id := "req-" + string(rune('A'+i))
		d.pending[id] = &pendingEntry{
			reply:     make(chan string, 1),
			id:        id,
			kind:      "shell",
			summary:   "cmd " + id,
			createdTS: now - int64(12-i), // i=0 最早
		}
	}
	jsonStr := buildStatusCard(d)
	// 应含 "...还有 2 条"
	if !strings.Contains(jsonStr, "...还有 2 条") {
		t.Errorf("超 10 条时应截断: %q", jsonStr)
	}
	// 最前面 10 个（按 createdTS 升序的前 10 个）应该在，后 2 个不在
	for i := 0; i < 10; i++ {
		id := "req-" + string(rune('A'+i))
		if !strings.Contains(jsonStr, id) {
			t.Errorf("前 10 条应在卡片里: %s 缺失", id)
		}
	}
	for i := 10; i < 12; i++ {
		id := "req-" + string(rune('A'+i))
		if strings.Contains(jsonStr, id) {
			t.Errorf("第 %d 条应被截断: 实际出现", i)
		}
	}
}

// ── /stop ──

func TestStopCommandMetadata(t *testing.T) {
	c := &stopCommand{}
	if c.Name() != "stop" {
		t.Errorf("Name() = %q", c.Name())
	}
	aliases := c.Aliases()
	if len(aliases) != 1 || aliases[0] != "/停止" {
		t.Errorf("Aliases() = %v", aliases)
	}
	if !c.Match("stop") {
		t.Errorf("Match(stop) 应 true")
	}
	if !c.Match("停止") {
		t.Errorf("Match(停止) 应 true")
	}
	if c.Match("status") {
		t.Errorf("Match(status) 不应匹配到 stop")
	}
}

// 空 pending 时 stopAllPending 应返回 ([], 0)，不触发任何 send
func TestStopAllPendingEmpty(t *testing.T) {
	d := newTestDaemon()
	views, sent := d.stopAllPending()
	if len(views) != 0 {
		t.Errorf("空 pending 返回 views 应为空，实际 %d", len(views))
	}
	if sent != 0 {
		t.Errorf("空 pending 返回 sent 应为 0，实际 %d", sent)
	}
}

// 混合 kind 的 pending：shell/mcp 发 "deny"，stop 发 "skip"，全部成功
func TestStopAllPendingMixedKinds(t *testing.T) {
	d := newTestDaemon()
	now := time.Now().Unix()
	// 提前存 chan 引用，绕过 map 遍历顺序的不确定性
	entries := map[string]*pendingEntry{
		"s1": {reply: make(chan string, 1), id: "s1", kind: "shell", summary: "npm test", createdTS: now - 3},
		"s2": {reply: make(chan string, 1), id: "s2", kind: "shell", summary: "ls", createdTS: now - 2},
		"st": {reply: make(chan string, 1), id: "st", kind: "stop", summary: "idle", createdTS: now - 1},
		"m1": {reply: make(chan string, 1), id: "m1", kind: "mcp", summary: "tool.x", createdTS: now},
	}
	for id, e := range entries {
		d.pending[id] = e
	}

	views, sent := d.stopAllPending()
	if len(views) != 4 {
		t.Fatalf("views 长度应为 4，实际 %d", len(views))
	}
	if sent != 4 {
		t.Errorf("sent 应为 4（全部成功），实际 %d", sent)
	}

	// 按 createdTS 升序：s1 < s2 < st < m1
	wantOrder := []string{"s1", "s2", "st", "m1"}
	for i, id := range wantOrder {
		if views[i].ID != id {
			t.Errorf("views[%d].ID = %q, 期望 %q", i, views[i].ID, id)
		}
	}

	// 每条 chan 都应能读出对应 reply
	wantReply := map[string]string{
		"s1": "deny",
		"s2": "deny",
		"m1": "deny",
		"st": "skip",
	}
	for id, want := range wantReply {
		select {
		case got := <-entries[id].reply:
			if got != want {
				t.Errorf("entries[%s].reply = %q, 期望 %q", id, got, want)
			}
		default:
			t.Errorf("entries[%s].reply 应有值 %q，实际 chan 为空", id, want)
		}
	}
}

// race 场景：某条 reply chan 已被别的路径 send 过（容量 1 已满），
// stopAllPending 应走 default 分支跳过该条，其它条目仍正常 send
func TestStopAllPendingSkipsAlreadyFilled(t *testing.T) {
	d := newTestDaemon()
	now := time.Now().Unix()
	// 4 条条目，其中 s2 的 chan 预先 push "allow" 模拟 race
	entries := map[string]*pendingEntry{
		"s1": {reply: make(chan string, 1), id: "s1", kind: "shell", createdTS: now - 3},
		"s2": {reply: make(chan string, 1), id: "s2", kind: "shell", createdTS: now - 2},
		"st": {reply: make(chan string, 1), id: "st", kind: "stop", createdTS: now - 1},
		"m1": {reply: make(chan string, 1), id: "m1", kind: "mcp", createdTS: now},
	}
	for id, e := range entries {
		d.pending[id] = e
	}
	entries["s2"].reply <- "allow"

	views, sent := d.stopAllPending()
	if len(views) != 4 {
		t.Fatalf("views 长度应为 4，实际 %d", len(views))
	}
	if sent != 3 {
		t.Errorf("sent 应为 3（s2 被跳过），实际 %d", sent)
	}

	// s1/m1/st 仍能读出预期 reply
	wantReply := map[string]string{
		"s1": "deny",
		"m1": "deny",
		"st": "skip",
	}
	for id, want := range wantReply {
		select {
		case got := <-entries[id].reply:
			if got != want {
				t.Errorf("entries[%s].reply = %q, 期望 %q", id, got, want)
			}
		default:
			t.Errorf("entries[%s].reply 应有值 %q，实际 chan 为空", id, want)
		}
	}
	// s2 chan 里残留的应仍是预先塞入的 "allow"（stopAllPending 没覆盖它）
	select {
	case got := <-entries["s2"].reply:
		if got != "allow" {
			t.Errorf("s2.reply 应保留 race 原值 \"allow\"，实际 %q", got)
		}
	default:
		t.Errorf("s2.reply 应有原值 \"allow\"")
	}
}

func TestBuildStopCancelCard_Empty(t *testing.T) {
	jsonStr := buildStopCancelCard(nil, 0)

	var card map[string]interface{}
	if err := json.Unmarshal([]byte(jsonStr), &card); err != nil {
		t.Fatalf("卡片 JSON 无效: %v", err)
	}
	hdr := card["header"].(map[string]interface{})
	if hdr["template"] != "grey" {
		t.Errorf("template = %v，期望 grey", hdr["template"])
	}
	title := hdr["title"].(map[string]interface{})["content"].(string)
	if !strings.Contains(title, "ℹ️") {
		t.Errorf("空 views 时 title 应含 ℹ️: %q", title)
	}
	if !strings.Contains(jsonStr, "没有需要取消") {
		t.Errorf("空卡片 body 应含提示: %q", jsonStr)
	}
}

func TestBuildStopCancelCard_WithItems(t *testing.T) {
	now := time.Now().Unix()
	views := []PendingView{
		{ID: "req-1", Kind: "shell", Summary: "npm test", Workspace: "myproj", CreatedTS: now - 60},
		{ID: "req-2", Kind: "mcp", Summary: "linear.list-issues", CreatedTS: now - 10},
	}
	jsonStr := buildStopCancelCard(views, 2)

	var card map[string]interface{}
	if err := json.Unmarshal([]byte(jsonStr), &card); err != nil {
		t.Fatalf("卡片 JSON 无效: %v", err)
	}
	hdr := card["header"].(map[string]interface{})
	if hdr["template"] != "grey" {
		t.Errorf("template = %v，期望 grey", hdr["template"])
	}
	title := hdr["title"].(map[string]interface{})["content"].(string)
	if !strings.Contains(title, "🛑") {
		t.Errorf("有 views 时 title 应含 🛑: %q", title)
	}
	// 应含 summary 文字和 kind 图标
	for _, want := range []string{"npm test", "linear.list-issues", "🖥️", "🔧", "共 2 条", "已发送取消信号 2 条"} {
		if !strings.Contains(jsonStr, want) {
			t.Errorf("卡片应含 %q: %q", want, jsonStr)
		}
	}
	// sent == len(views) 时不应出现 race 提示
	if strings.Contains(jsonStr, "race 时可能已自行完成") {
		t.Errorf("sent == len 时不应出现 race 提示: %q", jsonStr)
	}
}

// 当 sent < len(views) 时卡片应额外提示 race 情况
func TestBuildStopCancelCard_RaceHint(t *testing.T) {
	now := time.Now().Unix()
	views := []PendingView{
		{ID: "req-1", Kind: "shell", Summary: "a", CreatedTS: now - 20},
		{ID: "req-2", Kind: "shell", Summary: "b", CreatedTS: now - 10},
	}
	jsonStr := buildStopCancelCard(views, 1)
	if !strings.Contains(jsonStr, "未发送的 1 条") {
		t.Errorf("卡片应含 race 提示: %q", jsonStr)
	}
}
