package main

import (
	"strings"
	"sync"
	"testing"
	"time"
)

// newTestDaemon 构造一个裸 Daemon 用于 pending 单元测试：
// 不走 HTTP、不连 lark-cli，只初始化 pending map 以验证 snapshotPending
// 的正确性与并发安全性
func newTestDaemon() *Daemon {
	return &Daemon{
		pending: make(map[string]*pendingEntry),
	}
}

func TestSnapshotPendingEmpty(t *testing.T) {
	d := newTestDaemon()
	views := d.snapshotPending()
	if len(views) != 0 {
		t.Errorf("空 pending 应返回空切片，实际 %d 条", len(views))
	}
}

func TestSnapshotPendingCopiesMetadata(t *testing.T) {
	d := newTestDaemon()
	now := time.Now().Unix()
	d.pending["req-1"] = &pendingEntry{
		reply:     make(chan string, 1),
		id:        "req-1",
		kind:      "shell",
		summary:   "npm test",
		workspace: "myproject",
		agent:     "myproject · #abc",
		createdTS: now,
	}
	d.pending["req-2"] = &pendingEntry{
		reply:     make(chan string, 1),
		id:        "req-2",
		kind:      "ask",
		summary:   "choose option",
		createdTS: now,
	}

	views := d.snapshotPending()
	if len(views) != 2 {
		t.Fatalf("期望 2 条，实际 %d", len(views))
	}

	byID := map[string]PendingView{}
	for _, v := range views {
		byID[v.ID] = v
	}
	if v := byID["req-1"]; v.Kind != "shell" || v.Summary != "npm test" ||
		v.Workspace != "myproject" || v.Agent != "myproject · #abc" || v.CreatedTS != now {
		t.Errorf("req-1 快照字段错: %+v", v)
	}
	if v := byID["req-2"]; v.Kind != "ask" || v.Workspace != "" || v.Agent != "" {
		t.Errorf("req-2 快照字段错（应无 workspace/agent）: %+v", v)
	}
}

// 验证 PendingView 是值拷贝：改 view 不影响 daemon 内部的 pendingEntry
func TestSnapshotPendingIsReadOnly(t *testing.T) {
	d := newTestDaemon()
	d.pending["r"] = &pendingEntry{
		reply:   make(chan string, 1),
		id:      "r",
		kind:    "shell",
		summary: "a",
	}

	views := d.snapshotPending()
	if len(views) != 1 {
		t.Fatalf("期望 1 条，实际 %d", len(views))
	}
	views[0].Summary = "modified"
	if d.pending["r"].summary != "a" {
		t.Errorf("修改 view 不应影响原 pending entry，实际 %q", d.pending["r"].summary)
	}
}

// 验证读锁下能和注册/删除并发工作：stable 条目在压力下始终可见
func TestSnapshotPendingConcurrentWithRegister(t *testing.T) {
	d := newTestDaemon()
	for i := 0; i < 10; i++ {
		id := "stable-" + string(rune('0'+i))
		d.pending[id] = &pendingEntry{
			reply: make(chan string, 1),
			id:    id,
			kind:  "shell",
		}
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 50; i++ {
			id := "tmp-" + string(rune('A'+i%26))
			d.pendingMu.Lock()
			d.pending[id] = &pendingEntry{
				reply: make(chan string, 1),
				id:    id,
				kind:  "test",
			}
			d.pendingMu.Unlock()
			d.pendingMu.Lock()
			delete(d.pending, id)
			d.pendingMu.Unlock()
		}
	}()

	for i := 0; i < 50; i++ {
		views := d.snapshotPending()
		stable := 0
		for _, v := range views {
			if strings.HasPrefix(v.ID, "stable-") {
				stable++
			}
		}
		if stable != 10 {
			t.Errorf("snapshot 漏看了 stable 条目: %d/10", stable)
		}
	}
	wg.Wait()
}

// 验证多个 snapshotPending 可以并发执行（RWMutex 读锁共享语义）
func TestSnapshotPendingConcurrentReads(t *testing.T) {
	d := newTestDaemon()
	for i := 0; i < 5; i++ {
		id := "r-" + string(rune('0'+i))
		d.pending[id] = &pendingEntry{
			reply: make(chan string, 1),
			id:    id,
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				_ = d.snapshotPending()
			}
		}()
	}
	wg.Wait()
}

// 顺带验证 waitReply 注册的 pending 条目能被 snapshotPending 看到，
// 并且包含我们写入的 metadata（这是从 P2.1 起 pending map 的核心契约）
func TestWaitReplyPopulatesPendingView(t *testing.T) {
	d := newTestDaemon()

	done := make(chan struct{})
	go func() {
		defer close(done)
		// 短超时：本测试不关心回复内容，只关心 pending 条目注册期的快照
		_, _ = d.waitReply("stop-1", pendingMeta{
			kind:      "stop",
			summary:   "agent idle",
			workspace: "demo",
			agent:     "demo · #001",
		}, 200*time.Millisecond)
	}()

	// 等 waitReply 把条目注册进 map
	var view PendingView
	found := false
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		views := d.snapshotPending()
		if len(views) == 1 {
			view = views[0]
			found = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !found {
		t.Fatalf("500ms 内没看到 pending 条目")
	}
	if view.ID != "stop-1" || view.Kind != "stop" || view.Summary != "agent idle" ||
		view.Workspace != "demo" || view.Agent != "demo · #001" {
		t.Errorf("pending view 字段不匹配 meta: %+v", view)
	}
	if view.CreatedTS <= 0 {
		t.Errorf("CreatedTS 应为正整数 Unix 秒，实际 %d", view.CreatedTS)
	}

	<-done
	// waitReply defer 删除条目后，snapshot 应为空
	if left := len(d.snapshotPending()); left != 0 {
		t.Errorf("waitReply 超时后应清理 pending，实际仍剩 %d 条", left)
	}
}
