package main

import (
	"strings"
	"testing"
)

// TestHelpCommandMetadata 校验 helpCommand 的 Name / Aliases / Match / Description。
func TestHelpCommandMetadata(t *testing.T) {
	c := &helpCommand{}
	if c.Name() != "help" {
		t.Errorf("Name() = %q", c.Name())
	}
	aliases := c.Aliases()
	if len(aliases) != 2 {
		t.Fatalf("期望 2 个别名，实际 %d", len(aliases))
	}
	if !c.Match("help") || !c.Match("帮助") || !c.Match("指令") {
		t.Errorf("Match 缺路径")
	}
	if c.Match("ping") {
		t.Errorf("Match(ping) 应 false")
	}
	if c.Description() == "" {
		t.Errorf("Description 不应为空")
	}
}

// TestAllCommandsHaveDescription 保证 slashRegistry 里每条命令都填了 Description，
// 否则 /help 卡片会出现空行导致渲染混乱
func TestAllCommandsHaveDescription(t *testing.T) {
	for _, cmd := range slashRegistry {
		if desc := cmd.Description(); desc == "" {
			t.Errorf("命令 /%s 缺 Description", cmd.Name())
		}
	}
}

// TestBuildHelpCardContent 验证渲染出的卡片 JSON 覆盖所有 Name / alias / Description，
// 并使用蓝色 template
func TestBuildHelpCardContent(t *testing.T) {
	cardJSON := buildHelpCard(slashRegistry)
	for _, want := range []string{"/ping", "/status", "/stop", "/help"} {
		if !strings.Contains(cardJSON, want) {
			t.Errorf("帮助卡片缺命令 %q", want)
		}
	}
	for _, want := range []string{"/状态", "/停止", "/帮助", "/指令"} {
		if !strings.Contains(cardJSON, want) {
			t.Errorf("帮助卡片缺别名 %q", want)
		}
	}
	if !strings.Contains(cardJSON, `"template":"blue"`) {
		t.Errorf("帮助卡片应蓝色")
	}
	for _, cmd := range slashRegistry {
		if !strings.Contains(cardJSON, cmd.Description()) {
			t.Errorf("帮助卡片缺 /%s 的 Description", cmd.Name())
		}
	}
}

// TestHelpExecuteReturnsCard 确保 Execute 只返卡片、不回文字（避免双份发送）。
func TestHelpExecuteReturnsCard(t *testing.T) {
	cmd := &helpCommand{}
	reply := cmd.Execute(newTestDaemon())
	if reply.CardJSON == "" {
		t.Errorf("helpCommand.Execute 应返回 CardJSON")
	}
	if reply.Text != "" {
		t.Errorf("helpCommand.Execute 不应返回 Text")
	}
}
