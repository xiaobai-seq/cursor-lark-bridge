package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// PIDInfo 是 daemon.pid 的 JSON schema。
// 字段一旦发布只增不改；旧 daemon 读到未识别字段会 ignore（json.Unmarshal 默认宽松）。
type PIDInfo struct {
	PID            int    `json:"pid"`
	StartTS        int64  `json:"start_ts"` // Unix 秒
	Version        string `json:"version,omitempty"`
	ReconnectCount int64  `json:"reconnect_count"`
}

// pidFileMu 串行化 updatePIDFile 的读-改-写，避免 supervisor 多 goroutine 竞态
var pidFileMu sync.Mutex

// readPIDFile 读 $baseDir/daemon.pid。优先按 JSON 解析；
// 若失败（例如 legacy 单行 PID），fallback 为 PIDInfo{PID:<parsed>}。
// 不存在则返回 (nil, nil)。
func readPIDFile(baseDir string) (*PIDInfo, error) {
	p := filepath.Join(baseDir, pidFileName)
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return nil, nil
	}
	// 优先按 JSON 解析
	var info PIDInfo
	if err := json.Unmarshal(data, &info); err == nil && info.PID > 0 {
		return &info, nil
	}
	// Fallback：legacy 单行 PID（v0.1.x 写入格式）
	if pid, err := strconv.Atoi(trimmed); err == nil && pid > 0 {
		return &PIDInfo{PID: pid}, nil
	}
	return nil, fmt.Errorf("daemon.pid 格式不识别: %q", trimmed)
}

// writePIDFile 原子写入 pid 文件。用 write-to-tmp + rename，避免其它进程读到半截 JSON。
func writePIDFile(baseDir string, info *PIDInfo) error {
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		return err
	}
	p := filepath.Join(baseDir, pidFileName)
	data, err := json.Marshal(info)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(baseDir, ".daemon.pid.tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, p); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// acquirePIDLockV2 是 P0.3 版本：扩展读/写为 JSON 并判存活。
// 兼容老的单行 PID 文件（通过 readPIDFile fallback）。
// 成功后会把 pid 文件替换为当前进程的完整 PIDInfo。
func acquirePIDLockV2(baseDir string) error {
	pidFileMu.Lock()
	defer pidFileMu.Unlock()

	if info, err := readPIDFile(baseDir); err == nil && info != nil && info.PID > 0 && info.PID != os.Getpid() {
		if proc, err := os.FindProcess(info.PID); err == nil {
			// Signal(0) 探测存活，不真发信号
			if proc.Signal(syscall.Signal(0)) == nil {
				return fmt.Errorf("另一个 daemon 已在运行 (PID=%d)，请先 `fb kill` 再启动", info.PID)
			}
		}
	}

	info := &PIDInfo{
		PID:     os.Getpid(),
		StartTS: time.Now().Unix(),
		Version: version,
	}
	return writePIDFile(baseDir, info)
}

// removePIDV2：只有 pid 文件里记录的仍是自己时才删除，防止并发重启覆盖
// 同时兼容 legacy 单行 PID 文件
func removePIDV2(baseDir string) {
	pidFileMu.Lock()
	defer pidFileMu.Unlock()

	info, err := readPIDFile(baseDir)
	if err != nil || info == nil {
		// 读不到（不存在 / 格式垃圾）就尝试删一下，保守行为
		os.Remove(filepath.Join(baseDir, pidFileName))
		return
	}
	if info.PID != os.Getpid() {
		return // 别人的 pid 文件，不动
	}
	os.Remove(filepath.Join(baseDir, pidFileName))
}

// updatePIDFile 用 update 回调原子修改 pid 文件。
// 如果 pid 文件不存在 / 无效 / 不属于当前进程，直接返回 nil（不创建，避免 race）。
// 使用场景：supervisor 每次重连后把 reconnect_count+1 写回。
func updatePIDFile(baseDir string, update func(*PIDInfo)) error {
	pidFileMu.Lock()
	defer pidFileMu.Unlock()

	info, err := readPIDFile(baseDir)
	if err != nil {
		return err
	}
	if info == nil || info.PID != os.Getpid() {
		return nil // 不是自己的 pid 文件，silently skip
	}
	update(info)
	return writePIDFile(baseDir, info)
}
