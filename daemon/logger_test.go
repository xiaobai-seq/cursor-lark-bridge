package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeClock 生成可控时间源，供 dailyLogger / cleanupOldLogs 测试使用
type fakeClock struct {
	t time.Time
}

func (f *fakeClock) now() time.Time { return f.t }

func TestDailyLoggerRotatesAcrossDays(t *testing.T) {
	dir := t.TempDir()
	clk := &fakeClock{t: time.Date(2026, 4, 18, 10, 0, 0, 0, time.UTC)}
	dl := newDailyLogger(dir, clk.now)

	if _, err := dl.Write([]byte("line-day1\n")); err != nil {
		t.Fatalf("write day1: %v", err)
	}
	if _, err := dl.Write([]byte("line-day1-more\n")); err != nil {
		t.Fatalf("write day1 more: %v", err)
	}

	// 跨天
	clk.t = time.Date(2026, 4, 19, 1, 0, 0, 0, time.UTC)
	if _, err := dl.Write([]byte("line-day2\n")); err != nil {
		t.Fatalf("write day2: %v", err)
	}
	if err := dl.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	day1 := filepath.Join(dir, "daemon-2026-04-18.log")
	day2 := filepath.Join(dir, "daemon-2026-04-19.log")

	content1, err := os.ReadFile(day1)
	if err != nil {
		t.Fatalf("read day1: %v", err)
	}
	if !strings.Contains(string(content1), "line-day1\n") ||
		!strings.Contains(string(content1), "line-day1-more\n") {
		t.Errorf("day1 缺少预期内容: %q", content1)
	}
	if !strings.Contains(string(content1), "--- rotate to 2026-04-19 at") {
		t.Errorf("day1 缺少 rotate 标记: %q", content1)
	}

	content2, err := os.ReadFile(day2)
	if err != nil {
		t.Fatalf("read day2: %v", err)
	}
	if !strings.Contains(string(content2), "line-day2\n") {
		t.Errorf("day2 缺少预期内容: %q", content2)
	}
}

func TestDailyLoggerReopenSameDayAppends(t *testing.T) {
	dir := t.TempDir()
	clk := &fakeClock{t: time.Date(2026, 4, 18, 10, 0, 0, 0, time.UTC)}

	dl1 := newDailyLogger(dir, clk.now)
	if _, err := dl1.Write([]byte("session1\n")); err != nil {
		t.Fatalf("write1: %v", err)
	}
	dl1.Close()

	dl2 := newDailyLogger(dir, clk.now)
	if _, err := dl2.Write([]byte("session2\n")); err != nil {
		t.Fatalf("write2: %v", err)
	}
	dl2.Close()

	content, err := os.ReadFile(filepath.Join(dir, "daemon-2026-04-18.log"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	s := string(content)
	if !strings.Contains(s, "session1\n") || !strings.Contains(s, "session2\n") {
		t.Errorf("重启后应 append 不覆盖，实际: %q", s)
	}
}

func TestCleanupOldLogsKeepsRecentDeletesOld(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 4, 18, 12, 0, 0, 0, time.UTC)

	// 构造 10 个假日志文件：5 新 + 5 老
	oldFiles := []string{
		"daemon-2026-04-05.log",
		"daemon-2026-04-06.log",
		"daemon-2026-04-07.log",
		"daemon-2026-04-08.log",
		"daemon-2026-04-09.log",
	}
	recentFiles := []string{
		"daemon-2026-04-12.log",
		"daemon-2026-04-13.log",
		"daemon-2026-04-14.log",
		"daemon-2026-04-17.log",
		"daemon-2026-04-18.log",
	}
	unrelated := []string{
		"other.log",            // 非 daemon-*.log
		"daemon-legacy-xx.log", // 不应被 cleanup 动
	}

	writeWithMtime := func(name string, days int) {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0644); err != nil {
			t.Fatal(err)
		}
		mt := now.Add(-time.Duration(days) * 24 * time.Hour)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
	}

	for i, f := range oldFiles {
		writeWithMtime(f, 10+i) // 10-14 天前
	}
	for i, f := range recentFiles {
		writeWithMtime(f, 1+i) // 1-5 天前
	}
	for _, f := range unrelated {
		writeWithMtime(f, 100)
	}

	removed, err := cleanupOldLogs(dir, 7, now)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if len(removed) != len(oldFiles) {
		t.Errorf("期望删除 %d 个，实际 %d 个: %v", len(oldFiles), len(removed), removed)
	}

	// 老文件应都没了
	for _, f := range oldFiles {
		if _, err := os.Stat(filepath.Join(dir, f)); !os.IsNotExist(err) {
			t.Errorf("%s 应被删除", f)
		}
	}
	// 新文件应都在
	for _, f := range recentFiles {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s 应保留, err=%v", f, err)
		}
	}
	// 无关文件应都在
	for _, f := range unrelated {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s 应保留（非 daemon-*.log), err=%v", f, err)
		}
	}
}

func TestMigrateLegacyLog(t *testing.T) {
	base := t.TempDir()
	oldPath := filepath.Join(base, "daemon.log")
	if err := os.WriteFile(oldPath, []byte("ancient content\n"), 0644); err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 4, 18, 10, 30, 45, 0, time.UTC)
	newPath, err := migrateLegacyLog(base, now)
	if err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if newPath == "" {
		t.Fatal("期望返回新路径，实际空串")
	}
	if !strings.HasSuffix(newPath, "daemon-legacy-20260418-103045.log") {
		t.Errorf("新文件名不符合预期: %s", newPath)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Errorf("legacy 源文件应被移走")
	}
	content, err := os.ReadFile(newPath)
	if err != nil {
		t.Fatalf("读新文件: %v", err)
	}
	if string(content) != "ancient content\n" {
		t.Errorf("迁移后内容不一致: %q", content)
	}
}

func TestMigrateLegacyLogIdempotent(t *testing.T) {
	base := t.TempDir()
	now := time.Date(2026, 4, 18, 10, 30, 45, 0, time.UTC)
	// 不创建 daemon.log 直接调 migrate
	newPath, err := migrateLegacyLog(base, now)
	if err != nil {
		t.Fatalf("migrate on absent: %v", err)
	}
	if newPath != "" {
		t.Errorf("不存在 legacy 文件时应返回空串，实际 %q", newPath)
	}
}
