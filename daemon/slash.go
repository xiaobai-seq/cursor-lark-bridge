package main

import (
	"fmt"
	"strings"
	"time"
)

// SlashCommand 定义一个飞书斜杠命令的契约。
// 和普通文字回复不同：斜杠命令不会被注入到 pending 的回复通道，
// 而是由 daemon 直接用 lark-cli 回消息给用户。
type SlashCommand interface {
	// Name 是命令在帮助里显示的主名（不含前导斜杠）
	Name() string
	// Aliases 是可选别名（含前导斜杠 + 可为中文，例如 "/状态"）
	// Match 会把用户输入归一化后和 Name/Aliases 做精确比较
	Aliases() []string
	// Match 返回 true 时该命令接管；入参是已 trim + 去前导斜杠 + 小写（仅 ASCII）的输入
	// 实现方无需再 trim 或转小写
	Match(normalized string) bool
	// Execute 产出要回复给用户的消息。返回 nil 表示不回复。
	Execute(d *Daemon) SlashReply
}

// SlashReply 是命令的回复载体：text 非空就发文字、cardJSON 非空就发卡片。
// 允许都非空（先发卡片再发文字），但一般只用其一
type SlashReply struct {
	Text     string
	CardJSON string
}

// slashRegistry 是斜杠命令注册表，后续 P2.5/P2.6 继续 append 即可。
var slashRegistry = []SlashCommand{
	&pingCommand{},
	&statusCommand{},
}

// normalizeSlash 把输入文本归一化为斜杠命令形态：
//   - 去掉前导 `/` 或全角 `／`
//   - trim 空白
//   - 转小写（仅 ASCII；中文别名 ToLower 无效，保留原样）
//
// 返回 (normalized, isSlash)；isSlash=false 表示原文不是斜杠命令。
func normalizeSlash(text string) (string, bool) {
	trimmed := strings.TrimSpace(text)
	for _, prefix := range []string{"/", "／"} {
		if strings.HasPrefix(trimmed, prefix) {
			rest := strings.TrimPrefix(trimmed, prefix)
			rest = strings.TrimSpace(rest)
			return strings.ToLower(rest), true
		}
	}
	return "", false
}

// routeSlash 尝试用注册表处理一条消息。返回 true 表示已被斜杠命令接管，
// 调用方（handleMessageEvent）应直接 return，不再走 dispatchTextReply。
//
// 即使前导是 `/` 但无命令匹配，也会返回 true 并发一条"未识别"提示，
// 避免 `/xxx` 被当作普通文字回复误注入 pending FIFO。
func (d *Daemon) routeSlash(text string) bool {
	normalized, isSlash := normalizeSlash(text)
	if !isSlash {
		return false
	}
	for _, cmd := range slashRegistry {
		if cmd.Match(normalized) {
			logInfo("斜杠命令匹配: /%s", cmd.Name())
			reply := cmd.Execute(d)
			d.deliverSlashReply(reply)
			return true
		}
	}
	logInfo("未识别的斜杠命令: %q", text)
	d.deliverSlashReply(SlashReply{
		Text: fmt.Sprintf("未识别的命令：%s\n发送 /help 查看可用命令", text),
	})
	return true
}

// deliverSlashReply 按 reply 里填充的字段，依次发文字 / 卡片回复给当前配置的用户。
func (d *Daemon) deliverSlashReply(r SlashReply) {
	if r.Text != "" {
		if err := d.sendText(r.Text); err != nil {
			logErr("发送斜杠命令文字回复失败: %v", err)
		}
	}
	if r.CardJSON != "" {
		if err := d.sendCard(r.CardJSON); err != nil {
			logErr("发送斜杠命令卡片回复失败: %v", err)
		}
	}
}

// matchByNameOrAlias 是 SlashCommand.Match 的默认实现帮手：
// 把 Name() 和 Aliases() 归一化后和 normalized 精确比较。
// 注意：要求 normalized 已由 normalizeSlash 归一（trim + 小写）。
func matchByNameOrAlias(cmd SlashCommand, normalized string) bool {
	if normalized == strings.ToLower(cmd.Name()) {
		return true
	}
	for _, a := range cmd.Aliases() {
		// Aliases 可能含 `/` 或 `／` 前缀，也可能是中文
		alias := strings.TrimPrefix(strings.TrimPrefix(a, "/"), "／")
		// 英文 alias 小写归一；中文保留原样（ToLower 对中文无效所以无害）
		if strings.ToLower(alias) == normalized {
			return true
		}
	}
	return false
}

// ── /ping ──
// 最小的命令，验证整个框架通畅。
// 后续 /status /stop /help 在本 task 之后的 task 追加

type pingCommand struct{}

func (c *pingCommand) Name() string        { return "ping" }
func (c *pingCommand) Aliases() []string   { return nil }
func (c *pingCommand) Match(n string) bool { return matchByNameOrAlias(c, n) }
func (c *pingCommand) Execute(d *Daemon) SlashReply {
	up := d.uptime()
	upStr := formatDuration(up)
	return SlashReply{
		Text: fmt.Sprintf(
			"pong · version=%s · uptime=%s · reconnect=%d · subscribe_ok=%v",
			version, upStr, d.restartCount.Load(), d.subscribeOK.Load(),
		),
	}
}

// formatDuration 把 Duration 格式化为 "1h23m" / "1m30s" / "45s" 风格。
// 非正数（含 0 与负）统一返回 "?"，让上层拿不到 start_ts 时也能渲染。
func formatDuration(d time.Duration) string {
	if d <= 0 {
		return "?"
	}
	d = d.Round(time.Second)
	h := d / time.Hour
	m := (d % time.Hour) / time.Minute
	s := (d % time.Minute) / time.Second
	if h > 0 {
		return fmt.Sprintf("%dh%dm", h, m)
	}
	if m > 0 {
		return fmt.Sprintf("%dm%ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}
