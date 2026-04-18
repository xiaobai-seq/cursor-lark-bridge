package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// statusCommand 实现 /status 与中文别名 /状态。
// 渲染一张蓝色飞书卡片，总览 daemon 健康度 + 所有 pending。
type statusCommand struct{}

func (c *statusCommand) Name() string        { return "status" }
func (c *statusCommand) Aliases() []string   { return []string{"/状态"} }
func (c *statusCommand) Match(n string) bool { return matchByNameOrAlias(c, n) }
func (c *statusCommand) Execute(d *Daemon) SlashReply {
	return SlashReply{CardJSON: buildStatusCard(d)}
}

// buildStatusCard 把 daemon 健康度 + snapshot 渲染成一张蓝色卡片。
// 该函数不修改任何 daemon 状态，调用方应该已持有足够的数据（daemon 方法内部调）。
//
// 卡片结构（P2.4 Planner CP4）：
//   - header: blue 模板 + "🔎 飞书桥状态 · v{version}"
//   - div: Daemon 元信息（PID / Uptime / Reconnect / Event 订阅 / 最后事件时长）
//   - hr
//   - div: pending 列表（按 createdTS 升序；>10 条时截断；为空时提示"无待处理操作"）
//   - hr
//   - note: 底部命令提示
func buildStatusCard(d *Daemon) string {
	// info 可能为 nil（pid 文件被清掉或临时性 race）；下文兼容
	info, _ := readPIDFile(d.baseDir)
	var pid int
	var reconnect int64
	if info != nil {
		pid = info.PID
		reconnect = info.ReconnectCount
	}

	uptime := formatDuration(d.uptime())
	eventStatus := "❌ 未订阅"
	if d.subscribeOK.Load() {
		eventStatus = "✅ 已订阅"
	}
	lastAgo := "从未"
	if last := d.lastEventAt.Load(); last > 0 {
		delta := time.Since(time.UnixMilli(last))
		lastAgo = formatDuration(delta) + "前"
	}

	headerLine := fmt.Sprintf(
		"**Daemon**\nPID: %d · Uptime: %s · Reconnect: %d\nEvent: %s · 最后事件: %s",
		pid, uptime, reconnect, eventStatus, lastAgo,
	)

	// pending 段：按 createdTS 升序（等待最久的排前面），最多展示 10 条
	views := d.snapshotPending()
	sort.Slice(views, func(i, j int) bool {
		return views[i].CreatedTS < views[j].CreatedTS
	})

	var pendingBlock string
	if len(views) == 0 {
		pendingBlock = "✅ 当前无待处理操作"
	} else {
		const maxShow = 10
		shown := views
		truncated := 0
		if len(views) > maxShow {
			shown = views[:maxShow]
			truncated = len(views) - maxShow
		}
		lines := make([]string, 0, len(shown)+1)
		now := time.Now().Unix()
		for _, v := range shown {
			lines = append(lines, formatPendingLine(v, now))
		}
		if truncated > 0 {
			lines = append(lines, fmt.Sprintf("...还有 %d 条", truncated))
		}
		pendingBlock = strings.Join(lines, "\n")
	}

	card := map[string]interface{}{
		"config": map[string]interface{}{"wide_screen_mode": true},
		"header": map[string]interface{}{
			"title":    map[string]interface{}{"tag": "plain_text", "content": fmt.Sprintf("🔎 飞书桥状态 · %s", version)},
			"template": "blue",
		},
		"elements": []interface{}{
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": headerLine}},
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": pendingBlock}},
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{
				"tag": "note",
				"elements": []interface{}{
					map[string]interface{}{
						"tag":     "plain_text",
						"content": "💬 /stop 取消全部 · /help 查看命令",
					},
				},
			},
		},
	}
	// 用 encoder + SetEscapeHTML(false)，避免 summary 里出现的 `&` `<` `>` 被
	// 转成 \u0026 \u003c \u003e。飞书客户端能渲染，但日志/测试断言可读性变差
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(card)
	// json.Encoder 会在结尾追加一个换行符，去掉
	return strings.TrimRight(buf.String(), "\n")
}

// formatPendingLine 渲染单个 pending 的一行 lark_md。
// 样式：{icon} **{summary}** · 等待 {duration} · `[{workspace}]` · _{agent}_
// workspace / agent 为空时省略对应段。
func formatPendingLine(v PendingView, nowUnix int64) string {
	icon := kindIcon(v.Kind)
	summary := v.Summary
	if summary == "" {
		summary = "(无摘要)"
	}
	waited := time.Duration(nowUnix-v.CreatedTS) * time.Second
	line := fmt.Sprintf("%s **%s** · 等待 %s", icon, summary, formatDuration(waited))
	if v.Workspace != "" {
		line += fmt.Sprintf(" · `[%s]`", v.Workspace)
	}
	if v.Agent != "" {
		line += fmt.Sprintf(" · _%s_", v.Agent)
	}
	return line
}

// kindIcon 把 pending 的 kind 映射为 emoji，用于 /status 卡片里分类展示。
// 未知 kind 或空串回退为 📌，避免 UI 上出现空格。
func kindIcon(kind string) string {
	switch kind {
	case "shell":
		return "🖥️"
	case "mcp":
		return "🔧"
	case "ask", "askQuestion":
		return "❓"
	case "switchMode", "mode_switch":
		return "🔀"
	case "stop":
		return "⏸"
	default:
		return "📌"
	}
}
