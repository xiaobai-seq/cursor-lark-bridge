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
