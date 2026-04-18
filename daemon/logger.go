package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	logDirName        = "logs"
	dailyLogPrefix    = "daemon-"
	dailyLogSuffix    = ".log"
	legacyLogName     = "daemon.log"
	legacyFilePrefix  = "daemon-legacy-"        // 迁移后的文件名前缀
	legacyMigratedFmt = "daemon-legacy-%s.log"  // timestamp YYYYMMDD-HHMMSS
	logRetentionDays  = 7
)

// dailyLogger 实现 io.Writer，按当前日期把日志写入 logs/daemon-YYYY-MM-DD.log。
// 跨天时自动关闭旧文件、打开新文件。
// clock 字段可注入假时间供单测，生产代码用 time.Now。
type dailyLogger struct {
	mu    sync.Mutex
	dir   string
	clock func() time.Time
	file  *os.File
	date  string // 当前打开的文件对应的 YYYY-MM-DD
}

func newDailyLogger(dir string, clock func() time.Time) *dailyLogger {
	if clock == nil {
		clock = time.Now
	}
	return &dailyLogger{dir: dir, clock: clock}
}

func (l *dailyLogger) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	today := l.clock().Format("2006-01-02")
	if l.file == nil || l.date != today {
		if err := l.rotateLocked(today); err != nil {
			return 0, err
		}
	}
	return l.file.Write(p)
}

// rotateLocked 在持锁情况下关闭旧文件并打开新文件；调用方必须已持 l.mu
func (l *dailyLogger) rotateLocked(targetDate string) error {
	if err := os.MkdirAll(l.dir, 0755); err != nil {
		return fmt.Errorf("创建日志目录失败: %w", err)
	}
	if l.file != nil {
		// 关闭前写一行 rotate 标记，便于 grep 排查日志断点
		fmt.Fprintf(l.file, "--- rotate to %s at %s ---\n",
			targetDate, l.clock().Format(time.RFC3339))
		_ = l.file.Close()
	}
	path := filepath.Join(l.dir, dailyLogPrefix+targetDate+dailyLogSuffix)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("打开日志文件失败 %s: %w", path, err)
	}
	l.file = f
	l.date = targetDate
	return nil
}

// Close 关闭当前文件（测试/优雅退出时调用）
func (l *dailyLogger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}

// cleanupOldLogs 扫描 dir 里按天滚动的 daemon-YYYY-MM-DD.log，删除 mtime
// 超过 keepDays 天的。返回被删除的文件名列表（供调用方日志）。
//
// legacy 迁移文件 daemon-legacy-*.log 故意不在此处清理：迁移是一次性事件，
// 用户可能需要翻查老 daemon 的历史，等确认无用后手动删除即可。
func cleanupOldLogs(dir string, keepDays int, now time.Time) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	cutoff := now.Add(-time.Duration(keepDays) * 24 * time.Hour)
	var removed []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, dailyLogPrefix) || !strings.HasSuffix(name, dailyLogSuffix) {
			continue
		}
		// 跳过 legacy 迁移备份，避免把用户老日志一起清掉
		if strings.HasPrefix(name, legacyFilePrefix) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			full := filepath.Join(dir, name)
			if err := os.Remove(full); err == nil {
				removed = append(removed, name)
			}
		}
	}
	return removed, nil
}

// migrateLegacyLog 把老的 $baseDir/daemon.log 搬到 $baseDir/logs/daemon-legacy-<timestamp>.log。
// 幂等：若 daemon.log 不存在则直接返回 nil。
// 返回搬过去的新文件路径（空串表示没有要搬的）。
func migrateLegacyLog(baseDir string, now time.Time) (string, error) {
	oldPath := filepath.Join(baseDir, legacyLogName)
	if _, err := os.Stat(oldPath); err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	logsDir := filepath.Join(baseDir, logDirName)
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		return "", err
	}
	newName := fmt.Sprintf(legacyMigratedFmt, now.Format("20060102-150405"))
	newPath := filepath.Join(logsDir, newName)
	if err := os.Rename(oldPath, newPath); err != nil {
		return "", err
	}
	return newPath, nil
}

// setupLogging 在 daemon main() 开头调用：
//  1. 迁移 legacy daemon.log（如存在）
//  2. 启动 dailyLogger 并替换标准 log 包的输出
//  3. 清理超过 7 天的旧 daemon-*.log
//
// 返回 dailyLogger 供调用方在 shutdown 时 Close。
func setupLogging(baseDir string) (*dailyLogger, error) {
	now := time.Now()
	logsDir := filepath.Join(baseDir, logDirName)

	if newPath, err := migrateLegacyLog(baseDir, now); err != nil {
		// 迁移失败只打 stderr 不致命；日志系统未就位时 log 包还在走 stderr
		fmt.Fprintf(os.Stderr, "[WARN] 迁移 legacy daemon.log 失败: %v\n", err)
	} else if newPath != "" {
		fmt.Fprintf(os.Stderr, "[INFO] 迁移老版 daemon.log -> %s\n", newPath)
	}

	dl := newDailyLogger(logsDir, nil)
	// 触发一次 Write 测试写路径，失败的话返回错误让 daemon 整体退出
	if _, err := dl.Write([]byte{}); err != nil {
		return nil, fmt.Errorf("初始化日志失败: %w", err)
	}

	if removed, err := cleanupOldLogs(logsDir, logRetentionDays, now); err == nil && len(removed) > 0 {
		fmt.Fprintf(os.Stderr, "[INFO] 清理过期日志 (>%d天): %v\n", logRetentionDays, removed)
	}

	return dl, nil
}

// attachStandardLog 用给定的 Writer 替换 log 包默认输出。
// 真正的挂接在 main.go 里做：log.SetOutput(io.MultiWriter(os.Stderr, dl))，
// 此函数保留便于后续在不引入循环依赖的前提下扩展行为。
func attachStandardLog(w io.Writer) {
	_ = w
}
