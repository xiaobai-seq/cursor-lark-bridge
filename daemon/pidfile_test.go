package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestReadPIDFile_JSON(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, pidFileName)
	if err := os.WriteFile(p, []byte(`{"pid":42,"start_ts":1710489600,"version":"v0.1.5","reconnect_count":3}`), 0644); err != nil {
		t.Fatal(err)
	}
	info, err := readPIDFile(dir)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if info == nil || info.PID != 42 || info.StartTS != 1710489600 || info.Version != "v0.1.5" || info.ReconnectCount != 3 {
		t.Errorf("解析结果错: %+v", info)
	}
}

func TestReadPIDFile_LegacyPlain(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, pidFileName)
	if err := os.WriteFile(p, []byte("12345\n"), 0644); err != nil {
		t.Fatal(err)
	}
	info, err := readPIDFile(dir)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if info == nil || info.PID != 12345 {
		t.Errorf("期望 PID=12345，实际 %+v", info)
	}
	if info.StartTS != 0 || info.Version != "" || info.ReconnectCount != 0 {
		t.Errorf("legacy 读取其它字段应为零值，实际 %+v", info)
	}
}

func TestReadPIDFile_NotExist(t *testing.T) {
	info, err := readPIDFile(t.TempDir())
	if err != nil {
		t.Fatalf("not-exist 应返回 nil err，实际 %v", err)
	}
	if info != nil {
		t.Errorf("not-exist 应返回 nil info，实际 %+v", info)
	}
}

func TestReadPIDFile_Garbage(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, pidFileName)
	if err := os.WriteFile(p, []byte("abc def\n"), 0644); err != nil {
		t.Fatal(err)
	}
	info, err := readPIDFile(dir)
	if err == nil {
		t.Fatalf("垃圾内容应返回 err，实际 info=%+v", info)
	}
	if !strings.Contains(err.Error(), "格式不识别") {
		t.Errorf("错误消息应包含 '格式不识别'，实际 %v", err)
	}
}

func TestWritePIDFile_Atomic(t *testing.T) {
	dir := t.TempDir()
	info := &PIDInfo{PID: 99, StartTS: 1710489600, Version: "test", ReconnectCount: 2}
	if err := writePIDFile(dir, info); err != nil {
		t.Fatalf("write: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(dir, pidFileName))
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	var got PIDInfo
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got != *info {
		t.Errorf("写回内容不一致: %+v vs %+v", got, *info)
	}
	// 临时文件应已清理（rename 走成功路径不应留 .daemon.pid.tmp-*）
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".daemon.pid.tmp") {
			t.Errorf("临时文件未清理: %s", e.Name())
		}
	}
}

func TestUpdatePIDFile_OnlyOwnPID(t *testing.T) {
	dir := t.TempDir()
	// 写入一个 "别人" 的 pid 文件
	other := &PIDInfo{PID: os.Getpid() + 9999, StartTS: 100, Version: "other"}
	if err := writePIDFile(dir, other); err != nil {
		t.Fatal(err)
	}
	// update 应 no-op（不是自己的）
	if err := updatePIDFile(dir, func(i *PIDInfo) {
		i.ReconnectCount += 5
	}); err != nil {
		t.Fatalf("update: %v", err)
	}
	back, _ := readPIDFile(dir)
	if back.ReconnectCount != 0 {
		t.Errorf("update 应 no-op（文件不属于自己），实际 reconnect=%d", back.ReconnectCount)
	}
}

func TestUpdatePIDFile_IncrementReconnect(t *testing.T) {
	dir := t.TempDir()
	self := &PIDInfo{PID: os.Getpid(), StartTS: 100, Version: "v-test", ReconnectCount: 0}
	if err := writePIDFile(dir, self); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if err := updatePIDFile(dir, func(info *PIDInfo) {
			info.ReconnectCount++
		}); err != nil {
			t.Fatalf("update iter %d: %v", i, err)
		}
	}
	back, _ := readPIDFile(dir)
	if back.ReconnectCount != 3 {
		t.Errorf("期望 ReconnectCount=3，实际 %d", back.ReconnectCount)
	}
	if back.PID != os.Getpid() {
		t.Errorf("PID 不应变化: %d", back.PID)
	}
}

func TestAcquirePIDLockV2_WritesJSON(t *testing.T) {
	dir := t.TempDir()
	if err := acquirePIDLockV2(dir); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	info, err := readPIDFile(dir)
	if err != nil {
		t.Fatalf("readback: %v", err)
	}
	if info.PID != os.Getpid() || info.StartTS == 0 {
		t.Errorf("acquire 后 PIDInfo 不完整: %+v", info)
	}
	// 清理
	removePIDV2(dir)
	if _, err := os.Stat(filepath.Join(dir, pidFileName)); !os.IsNotExist(err) {
		t.Errorf("removePIDV2 应删掉自己的 pid 文件")
	}
}

func TestAcquirePIDLockV2_BlocksWhenLegacyPIDAlive(t *testing.T) {
	dir := t.TempDir()
	// 写一个老格式 PID 文件指向"当前测试进程的父进程"（go test 本身也在运行，用 PPID 保证存活）
	ppid := os.Getppid()
	if ppid <= 1 {
		t.Skip("PPID 不可用")
	}
	if err := os.WriteFile(filepath.Join(dir, pidFileName), []byte(strconv.Itoa(ppid)), 0644); err != nil {
		t.Fatal(err)
	}
	err := acquirePIDLockV2(dir)
	if err == nil {
		t.Errorf("应被已存活的 legacy PID 挡住")
	} else if !strings.Contains(err.Error(), "另一个 daemon 已在运行") {
		t.Errorf("错误消息不符合预期: %v", err)
	}
}
