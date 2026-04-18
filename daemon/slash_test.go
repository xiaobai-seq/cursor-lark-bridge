package main

import (
	"testing"
	"time"
)

func TestNormalizeSlash(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		isSlash bool
	}{
		{"/ping", "ping", true},
		{"/PING", "ping", true},
		{"  /ping  ", "ping", true},
		{"／ping", "ping", true},                     // 全角斜杠
		{"／状态", "状态", true},                         // 全角 + 中文
		{"/状态", "状态", true},
		{"hello world", "", false},
		{"", "", false},
		{"/", "", true},                              // 只有一个斜杠也算 slash，交给 router 处理
		{"/status   extra", "status   extra", true}, // P2.4 可能需要解析参数；目前保留完整
	}
	for _, c := range cases {
		got, isSlash := normalizeSlash(c.in)
		if got != c.want || isSlash != c.isSlash {
			t.Errorf("normalizeSlash(%q) = (%q, %v), want (%q, %v)",
				c.in, got, isSlash, c.want, c.isSlash)
		}
	}
}

func TestMatchByNameOrAlias(t *testing.T) {
	cmd := &mockCmd{name: "status", aliases: []string{"/状态"}}
	cases := []struct {
		normalized string
		want       bool
	}{
		{"status", true},
		{"STATUS", false}, // Match 要求入参已归一化（小写）；Router 入口会帮忙
		{"状态", true},
		{"sta", false},
		{"", false},
	}
	for _, c := range cases {
		got := matchByNameOrAlias(cmd, c.normalized)
		if got != c.want {
			t.Errorf("matchByNameOrAlias(%q) = %v, want %v", c.normalized, got, c.want)
		}
	}
}

func TestPingCommand(t *testing.T) {
	cmd := &pingCommand{}
	if cmd.Name() != "ping" {
		t.Errorf("Name() = %q, want ping", cmd.Name())
	}
	if !cmd.Match("ping") {
		t.Errorf("Match(ping) = false")
	}
	if cmd.Match("status") {
		t.Errorf("ping Match(status) 应为 false")
	}

	d := newTestDaemon()
	d.restartCount.Store(3)
	d.subscribeOK.Store(true)
	reply := cmd.Execute(d)
	if reply.Text == "" {
		t.Fatal("ping 应返回非空 Text")
	}
	// 字段应该含 version、reconnect=3、subscribe_ok=true 等
	for _, want := range []string{"pong", "reconnect=3", "subscribe_ok=true"} {
		if !contains(reply.Text, want) {
			t.Errorf("ping 回复缺 %q: %q", want, reply.Text)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	cases := []struct {
		in   time.Duration
		want string
	}{
		{0, "?"},
		{-1 * time.Second, "?"},
		{5 * time.Second, "5s"},
		{90 * time.Second, "1m30s"},
		{3661 * time.Second, "1h1m"},
		{24 * time.Hour, "24h0m"},
	}
	for _, c := range cases {
		got := formatDuration(c.in)
		if got != c.want {
			t.Errorf("formatDuration(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

// ── 测试辅助 ──

type mockCmd struct {
	name    string
	aliases []string
}

func (m *mockCmd) Name() string                 { return m.name }
func (m *mockCmd) Aliases() []string            { return m.aliases }
func (m *mockCmd) Match(n string) bool          { return matchByNameOrAlias(m, n) }
func (m *mockCmd) Execute(d *Daemon) SlashReply { return SlashReply{} }

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (len(sub) == 0 || indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
