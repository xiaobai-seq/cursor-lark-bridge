package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// version 由 goreleaser 通过 -ldflags 注入；本地 go build 时保持 "dev"
var version = "dev"

const (
	listenAddr     = "127.0.0.1:19836"
	stateFileName  = "state.json"
	pidFileName    = "daemon.pid"
	approveTimeout = 10 * time.Minute
)

// ── 配置 & 状态 ──

type Config struct {
	OpenID string `json:"open_id"`
}

type State struct {
	Active bool `json:"active"`
}

// ── Daemon ──

// pendingEntry 把等待回复的 channel 和发起请求的 Agent 标识绑在一起，
// 方便按钮回执卡片上也能正确显示 Agent 身份
type pendingEntry struct {
	reply chan string
	agent string
}

type Daemon struct {
	baseDir   string
	config    *Config
	state     *State
	stateMu   sync.RWMutex
	pending   map[string]*pendingEntry
	pendingMu sync.Mutex
	reqSeq    atomic.Int64

	// 事件订阅子进程（lark-cli event +subscribe）相关状态
	// eventCmdMu 保护 eventCmd 的并发读写，避免 HTTP handler / 订阅循环之间踩踏
	eventCmdMu   sync.Mutex
	eventCmd     *exec.Cmd
	lastEventAt  atomic.Int64 // UnixMilli，最近一次收到事件流输出的时间
	subscribeOK  atomic.Bool  // 当前 lark-cli 子进程是否成功稳定订阅（启动后 2s 仍未退出即视为 OK）
	restartCount atomic.Int64 // 累计的 lark-cli 重启次数（诊断用）
}

// ── 事件解析 ──

// 文字消息事件（compact 格式）
type MessageEvent struct {
	Type     string `json:"type"`
	Content  string `json:"content"`
	ChatType string `json:"chat_type"`
	SenderID string `json:"sender_id"`
}

// 卡片按钮点击事件（compact 格式）
type CardActionEvent struct {
	Type      string          `json:"type"`
	OpenID    string          `json:"open_id"`
	Action    json.RawMessage `json:"action"`
	RawAction struct {
		Value json.RawMessage `json:"value"`
	}
}

// 按钮 value 结构
type ButtonValue struct {
	Action    string `json:"action"`
	RequestID string `json:"request_id"`
	Label     string `json:"label"`
}

// ── HTTP 请求/响应 ──

type ApproveRequest struct {
	Type    string `json:"type"`
	Title   string `json:"title"`
	Content string `json:"content"`
	Context string `json:"context"`
	Agent   string `json:"agent"` // Agent 标识（项目名 · #id），用于多会话并行时区分
}

type ApproveResponse struct {
	Decision string `json:"decision"`
	Reply    string `json:"reply"`
}

type AskRequest struct {
	Question string   `json:"question"`
	Options  []string `json:"options"`
	Context  string   `json:"context"`
	Agent    string   `json:"agent"` // Agent 标识
}

type AskResponse struct {
	Reply string `json:"reply"`
}

type NotifyRequest struct {
	Title   string `json:"title"`
	Content string `json:"content"`
	Color   string `json:"color"`
	Context string `json:"context"`
	Agent   string `json:"agent"` // Agent 标识（可空）
}

// Agent 停止 hook 的请求体：展示 Agent 最后输出，等待用户决定是否继续
type StopRequest struct {
	Status    string `json:"status"`     // completed / aborted / error
	Summary   string `json:"summary"`    // Agent 最后输出摘要
	LoopCount int    `json:"loop_count"` // stop hook 的循环计数
	Agent     string `json:"agent"`      // Agent 标识
}

// Agent 停止 hook 的响应体
type StopResponse struct {
	Reply string `json:"reply"` // 空或 "skip" 表示不继续；其它文字注入为 followup_message
}

type ModeRequest struct {
	Active bool `json:"active"`
}

type ModeResponse struct {
	Active bool `json:"active"`
}

// HealthResponse 暴露 daemon 的真实健康度
//   - EventRunning: lark-cli 子进程当前是否存活（仅证明进程在跑，不保证订阅健康）
//   - SubscribeOK:  本次 lark-cli 启动是否稳定订阅上（成功超过 2s 视为 OK）
//   - LastEventAgeMs: 距离上一次收到事件流输出的毫秒数；-1 表示启动至今未收到任何事件
//   - RestartCount: 累计 lark-cli 重启次数，持续增长说明在无限重启循环
type HealthResponse struct {
	Status         string `json:"status"`
	Active         bool   `json:"active"`
	EventRunning   bool   `json:"event_running"`
	SubscribeOK    bool   `json:"subscribe_ok"`
	LastEventAgeMs int64  `json:"last_event_age_ms"`
	RestartCount   int64  `json:"restart_count"`
	Version        string `json:"version,omitempty"`
}

// ── 初始化 ──

func newDaemon() *Daemon {
	baseDir := filepath.Join(homeDir(), ".cursor", "cursor-lark-bridge")
	return &Daemon{
		baseDir: baseDir,
		config:  loadConfig(baseDir),
		state:   loadState(baseDir),
		pending: make(map[string]*pendingEntry),
	}
}

func homeDir() string {
	h, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("无法获取 home 目录: %v", err)
	}
	return h
}

func loadConfig(baseDir string) *Config {
	p := filepath.Join(baseDir, "config.json")
	data, err := os.ReadFile(p)
	if err != nil {
		log.Fatalf("未找到 config.json（%s），请先运行 fb init", p)
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil || c.OpenID == "" {
		log.Fatalf("config.json 格式不合法或缺少 open_id 字段: %s", p)
	}
	return &c
}

func loadState(baseDir string) *State {
	data, err := os.ReadFile(filepath.Join(baseDir, stateFileName))
	if err != nil {
		return &State{}
	}
	var s State
	json.Unmarshal(data, &s)
	return &s
}

func (d *Daemon) saveState() {
	d.stateMu.RLock()
	data, _ := json.Marshal(d.state)
	d.stateMu.RUnlock()
	os.WriteFile(filepath.Join(d.baseDir, stateFileName), data, 0644)
}

// acquirePIDLock 检查是否已有活 daemon，没有则写入自己的 PID
// 返回非 nil error 时 daemon 必须退出，防止并发启动互相踩（例如同时启动会清理对方的 lark-cli 子进程）
func (d *Daemon) acquirePIDLock() error {
	p := filepath.Join(d.baseDir, pidFileName)
	if data, err := os.ReadFile(p); err == nil {
		pidStr := strings.TrimSpace(string(data))
		if pidStr != "" {
			if pid, err := strconv.Atoi(pidStr); err == nil && pid > 0 && pid != os.Getpid() {
				if proc, err := os.FindProcess(pid); err == nil {
					// Signal(0) 不实际发信号，仅探测进程是否存活
					if proc.Signal(syscall.Signal(0)) == nil {
						return fmt.Errorf("另一个 daemon 已在运行 (PID=%d)，请先 `fb kill` 再启动", pid)
					}
				}
			}
		}
	}
	// 写入当前 PID；目录不存在时先创建，避免 PID 文件写入失败
	if err := os.MkdirAll(d.baseDir, 0755); err != nil {
		return fmt.Errorf("创建 %s 失败: %w", d.baseDir, err)
	}
	return os.WriteFile(p, []byte(strconv.Itoa(os.Getpid())), 0644)
}

func (d *Daemon) removePID() {
	// 仅在 PID 文件里记录的仍是自己时才删除，防止并发重启下覆盖掉后来者的 PID
	p := filepath.Join(d.baseDir, pidFileName)
	if data, err := os.ReadFile(p); err == nil {
		if pidStr := strings.TrimSpace(string(data)); pidStr != "" {
			if pid, err := strconv.Atoi(pidStr); err == nil && pid != os.Getpid() {
				return
			}
		}
	}
	os.Remove(p)
}

func (d *Daemon) nextRequestID(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, d.reqSeq.Add(1))
}

func (d *Daemon) isActive() bool {
	d.stateMu.RLock()
	defer d.stateMu.RUnlock()
	return d.state.Active
}

// ── 事件订阅：同时监听消息 + 卡片按钮点击 ──
//
// 设计要点（v0.1.5 起）：
//  1. 子进程放进独立 process group（Setpgid=true），daemon 退出时对整个 pgroup
//     发 SIGTERM→SIGKILL，避免 lark-cli 的 node 父壳死了、孙子进程被 launchd 收养
//     变成收黑洞事件的孤儿。
//  2. daemon 启动前先 best-effort 清理一遍可能遗留的 lark-cli event 进程，
//     防止上一次非正常退出留下的孤儿霸占"单 app 单订阅者"坑位。
//  3. stderr 通过 pipe 同时写到 os.Stderr 和一个小内存 buffer；子进程退出后
//     回看 stderr，如果是 "another event +subscribe instance is already running"
//     这类冲突，就主动 pkill 一次再重启。
//  4. 子进程启动后 2s 内未退出则 subscribeOK=true，用于 /health 真实健康判定。

func (d *Daemon) startEventSubscription(ctx context.Context) {
	// daemon 冷启动时先清一遍可能遗留的 lark-cli event 孤儿
	cleanupStaleLarkCLIEvent("startup")

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			d.runOneSubscription(ctx)
			sleepCtx(ctx, 3*time.Second)
		}
	}()
}

// runOneSubscription 启动一次 lark-cli event +subscribe 子进程并阻塞到它退出
func (d *Daemon) runOneSubscription(ctx context.Context) {
	logInfo("启动 lark-cli event +subscribe ...")
	cmd := exec.CommandContext(ctx, "lark-cli", "event", "+subscribe",
		"--event-types", "im.message.receive_v1,card.action.trigger",
		"--compact", "--quiet", "--as", "bot")

	// 独立 process group，daemon 退出时可以通过负 PID 一次端掉整条链
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		logErr("创建 stdout pipe 失败: %v", err)
		return
	}
	// stderr 旁路到内存 buffer，退出后用来做错误分类
	var stderrBuf bytes.Buffer
	cmd.Stderr = io.MultiWriter(os.Stderr, newCappedWriter(&stderrBuf, 8*1024))

	if err := cmd.Start(); err != nil {
		logErr("启动 lark-cli 失败: %v", err)
		return
	}
	pid := cmd.Process.Pid
	logInfo("lark-cli event +subscribe 已启动 (PID=%d)", pid)

	d.eventCmdMu.Lock()
	d.eventCmd = cmd
	d.eventCmdMu.Unlock()
	d.subscribeOK.Store(false)
	d.restartCount.Add(1)

	// 启动 2s 仍没退出，认为订阅已稳定建立（lark-cli 如果被服务端拒绝会立刻退出）
	stableTimer := time.AfterFunc(2*time.Second, func() {
		// 只在进程仍然活着时才标记 OK
		if cmd.ProcessState == nil {
			d.subscribeOK.Store(true)
		}
	})

	d.readEvents(ctx, stdout)
	cmd.Wait()
	stableTimer.Stop()
	d.subscribeOK.Store(false)

	// 出错分类：冲突类错误需要主动清理再重试，否则纯死循环无意义
	stderrStr := stderrBuf.String()
	if strings.Contains(stderrStr, "already running") ||
		strings.Contains(stderrStr, "Only one subscriber") {
		logErr("检测到 lark-cli event 冲突（有遗留订阅者），主动清理后重试...")
		cleanupStaleLarkCLIEvent("conflict")
	}

	logInfo("lark-cli event +subscribe 已退出，3 秒后重启...")
}

// cleanupStaleLarkCLIEvent 尽力清理可能遗留的 lark-cli event +subscribe 进程
// reason 仅用于日志区分是启动清理还是冲突清理
func cleanupStaleLarkCLIEvent(reason string) {
	patterns := []string{
		"lark-cli.*event .subscribe",
		"@larksuite/cli.*event .subscribe",
	}
	cleaned := false
	for _, p := range patterns {
		// -9 保证即使子进程在 uninterruptible sleep / sigterm 被忽略时也能被清
		if err := exec.Command("pkill", "-9", "-f", p).Run(); err == nil {
			cleaned = true
		}
	}
	if cleaned {
		logInfo("[cleanup:%s] 已清理残留的 lark-cli event 进程", reason)
	}
}

// killEventSubprocess 对 lark-cli 子进程组发 SIGTERM，3s 仍未退出则 SIGKILL
// 用于 daemon 优雅退出路径，避免孤儿
func (d *Daemon) killEventSubprocess() {
	d.eventCmdMu.Lock()
	cmd := d.eventCmd
	d.eventCmdMu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	// 负 PID 向整个 process group 发信号；Setpgid 时 pgid == pid
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	// 冗余一次向直接子进程发 SIGTERM，兼容 Setpgid 失败的场景
	_ = syscall.Kill(pid, syscall.SIGTERM)

	done := make(chan struct{})
	go func() {
		// cmd.Wait 可能已被订阅循环调用，这里再 Wait 会返回 "Wait was already called"，
		// 所以用轮询 Process.Signal(0) 判断进程是否消失
		for {
			if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
				close(done)
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
}

// cappedWriter 限制 buffer 最多 max 字节，防止 stderr 无限增长吃内存
type cappedWriter struct {
	buf *bytes.Buffer
	max int
}

func newCappedWriter(buf *bytes.Buffer, max int) io.Writer {
	return &cappedWriter{buf: buf, max: max}
}

func (c *cappedWriter) Write(p []byte) (int, error) {
	if c.buf.Len() >= c.max {
		return len(p), nil
	}
	room := c.max - c.buf.Len()
	if len(p) <= room {
		return c.buf.Write(p)
	}
	c.buf.Write(p[:room])
	return len(p), nil
}

func (d *Daemon) readEvents(ctx context.Context, r io.Reader) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 256*1024), 256*1024)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
		}
		line := scanner.Text()
		if line == "" {
			continue
		}

		// 任何事件进入都更新时间戳，用于 /health 的真实健康探针
		d.lastEventAt.Store(time.Now().UnixMilli())

		// 先解析 type 字段判断事件类型
		var base struct {
			Type string `json:"type"`
		}
		if json.Unmarshal([]byte(line), &base) != nil {
			logErr("解析事件 type 失败: raw=%s", truncate(line, 200))
			continue
		}

		switch base.Type {
		case "im.message.receive_v1":
			d.handleMessageEvent(line)
		case "card.action.trigger":
			d.handleCardActionEvent(line)
		default:
			logInfo("忽略事件类型: %s", base.Type)
		}
	}
}

func (d *Daemon) handleMessageEvent(line string) {
	var ev MessageEvent
	if json.Unmarshal([]byte(line), &ev) != nil {
		return
	}
	if ev.ChatType != "p2p" {
		return
	}
	if d.config.OpenID != "" && ev.SenderID != d.config.OpenID {
		return
	}
	text := strings.TrimSpace(ev.Content)
	if text == "" {
		return
	}
	logInfo("收到文字回复: %s", truncate(text, 100))
	d.dispatchTextReply(text)
}

func (d *Daemon) handleCardActionEvent(line string) {
	// compact 格式可能有不同字段结构，直接解析为 map 再提取
	var raw map[string]interface{}
	if json.Unmarshal([]byte(line), &raw) != nil {
		logErr("解析卡片事件失败: %s", truncate(line, 200))
		return
	}

	// 提取 action.value
	var bv ButtonValue
	if action, ok := raw["action"].(map[string]interface{}); ok {
		if value, ok := action["value"].(map[string]interface{}); ok {
			if a, ok := value["action"].(string); ok {
				bv.Action = a
			}
			if rid, ok := value["request_id"].(string); ok {
				bv.RequestID = rid
			}
			if label, ok := value["label"].(string); ok {
				bv.Label = label
			}
		}
	}

	if bv.RequestID == "" {
		logInfo("卡片点击无 request_id，忽略")
		return
	}

	replyText := bv.Action
	if replyText == "" {
		replyText = bv.Label
	}
	logInfo("收到按钮点击: request_id=%s action=%s", bv.RequestID, replyText)
	d.dispatchButtonReply(bv.RequestID, replyText)
}

// ── 回复分发 ──

// 按钮点击：精确匹配 requestID，成功后发确认回执
func (d *Daemon) dispatchButtonReply(requestID, text string) {
	d.pendingMu.Lock()
	defer d.pendingMu.Unlock()

	if entry, ok := d.pending[requestID]; ok {
		select {
		case entry.reply <- text:
			agent := entry.agent
			delete(d.pending, requestID)
			// 异步发送确认回执，保留原请求的 Agent 标识
			go d.sendConfirmation(text, agent)
		default:
		}
		return
	}
	logInfo("按钮 request_id=%s 无匹配请求，丢弃", requestID)
}

func (d *Daemon) sendConfirmation(action, agent string) {
	// 根据 action 类别选择回执样式
	var emoji, label, color, content string
	switch action {
	case "allow":
		emoji, label, color = "✅", "已授权", "green"
		content = "操作已授权，Cursor 将继续执行。"
	case "deny":
		emoji, label, color = "⛔", "已拒绝", "red"
		content = "操作已拒绝，Cursor 将跳过该步骤。"
	case "skip":
		emoji, label, color = "🛑", "已结束会话", "grey"
		content = "本轮会话已结束，Agent 不会再继续。"
	case "继续":
		emoji, label, color = "▶️", "已继续执行", "green"
		content = "Agent 已收到「继续」指令，即将继续执行。"
	default:
		// 带序号的选项或其它 action：统一呈现
		emoji, label, color = "📥", "已收到回复", "blue"
		content = fmt.Sprintf("回复内容：**%s**，Cursor 将据此继续。", action)
	}

	card := buildNotifyCard(NotifyRequest{
		Title:   fmt.Sprintf("%s %s", emoji, label),
		Content: content,
		Color:   color,
		Context: "操作回执",
		Agent:   agent,
	})
	if err := d.sendCard(card); err != nil {
		logErr("发送确认回执失败: %v", err)
	}
}

// 文字回复：FIFO 分发到最早的等待请求
func (d *Daemon) dispatchTextReply(text string) {
	d.pendingMu.Lock()
	defer d.pendingMu.Unlock()

	// map 遍历顺序不保证，多请求并存时可能派发到任意一个；
	// 多 Agent 并行场景建议使用按钮回复以精确定位
	for id, entry := range d.pending {
		select {
		case entry.reply <- text:
			delete(d.pending, id)
			return
		default:
		}
	}
	logInfo("无等待中的请求，丢弃回复: %s", truncate(text, 50))
}

func (d *Daemon) waitReply(requestID, agent string, timeout time.Duration) (string, error) {
	entry := &pendingEntry{
		reply: make(chan string, 1),
		agent: agent,
	}
	d.pendingMu.Lock()
	d.pending[requestID] = entry
	d.pendingMu.Unlock()

	defer func() {
		d.pendingMu.Lock()
		delete(d.pending, requestID)
		d.pendingMu.Unlock()
	}()

	select {
	case reply := <-entry.reply:
		return reply, nil
	case <-time.After(timeout):
		return "", fmt.Errorf("等待回复超时 (%v)", timeout)
	}
}

// ── lark-cli 发消息 ──

func (d *Daemon) sendCard(cardJSON string) error {
	cmd := exec.Command("lark-cli", "im", "+messages-send",
		"--user-id", d.config.OpenID,
		"--msg-type", "interactive",
		"--content", cardJSON,
		"--as", "bot")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("lark-cli 发消息失败: %v, output=%s", err, truncate(string(out), 300))
	}
	return nil
}

// ── HTTP API ──

func (d *Daemon) setupRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", d.handleHealth)
	mux.HandleFunc("/mode", d.handleMode)
	mux.HandleFunc("/approve", d.handleApprove)
	mux.HandleFunc("/ask", d.handleAsk)
	mux.HandleFunc("/notify", d.handleNotify)
	mux.HandleFunc("/stop", d.handleStop)
	return mux
}

func (d *Daemon) handleHealth(w http.ResponseWriter, r *http.Request) {
	d.stateMu.RLock()
	active := d.state.Active
	d.stateMu.RUnlock()

	d.eventCmdMu.Lock()
	cmd := d.eventCmd
	d.eventCmdMu.Unlock()
	eventRunning := cmd != nil && cmd.Process != nil && cmd.ProcessState == nil

	lastAgeMs := int64(-1)
	if last := d.lastEventAt.Load(); last > 0 {
		lastAgeMs = time.Now().UnixMilli() - last
	}

	writeJSON(w, HealthResponse{
		Status:         "ok",
		Active:         active,
		EventRunning:   eventRunning,
		SubscribeOK:    d.subscribeOK.Load(),
		LastEventAgeMs: lastAgeMs,
		RestartCount:   d.restartCount.Load(),
		Version:        version,
	})
}

func (d *Daemon) handleMode(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		d.stateMu.RLock()
		active := d.state.Active
		d.stateMu.RUnlock()
		writeJSON(w, ModeResponse{Active: active})
		return
	}
	var req ModeRequest
	if readJSON(r, &req) != nil {
		httpErr(w, "invalid request", http.StatusBadRequest)
		return
	}
	d.stateMu.Lock()
	d.state.Active = req.Active
	d.stateMu.Unlock()
	d.saveState()
	logInfo("远程模式已 %s", boolStr(req.Active, "激活", "关闭"))
	writeJSON(w, ModeResponse{Active: req.Active})
}

func (d *Daemon) handleApprove(w http.ResponseWriter, r *http.Request) {
	if !d.isActive() {
		writeJSON(w, ApproveResponse{Decision: "allow"})
		return
	}
	var req ApproveRequest
	if readJSON(r, &req) != nil {
		httpErr(w, "invalid request", http.StatusBadRequest)
		return
	}

	requestID := d.nextRequestID("approve")
	cardJSON := buildApproveCard(req, requestID)
	if err := d.sendCard(cardJSON); err != nil {
		logErr("发送审批卡片失败: %v", err)
		writeJSON(w, ApproveResponse{Decision: "allow"})
		return
	}

	reply, err := d.waitReply(requestID, req.Agent, approveTimeout)
	if err != nil {
		logErr("等待审批回复失败: %v", err)
		writeJSON(w, ApproveResponse{Decision: "allow"})
		return
	}

	decision := parseDecision(reply)
	writeJSON(w, ApproveResponse{Decision: decision, Reply: reply})
}

func (d *Daemon) handleAsk(w http.ResponseWriter, r *http.Request) {
	if !d.isActive() {
		httpErr(w, "remote mode not active", http.StatusServiceUnavailable)
		return
	}
	var req AskRequest
	if readJSON(r, &req) != nil {
		httpErr(w, "invalid request", http.StatusBadRequest)
		return
	}

	requestID := d.nextRequestID("ask")
	cardJSON := buildAskCard(req, requestID)
	if err := d.sendCard(cardJSON); err != nil {
		logErr("发送提问卡片失败: %v", err)
		httpErr(w, "failed to send card", http.StatusInternalServerError)
		return
	}

	reply, err := d.waitReply(requestID, req.Agent, approveTimeout)
	if err != nil {
		logErr("等待提问回复失败: %v", err)
		httpErr(w, "timeout", http.StatusGatewayTimeout)
		return
	}

	writeJSON(w, AskResponse{Reply: reply})
}

func (d *Daemon) handleNotify(w http.ResponseWriter, r *http.Request) {
	if !d.isActive() {
		w.WriteHeader(http.StatusOK)
		return
	}
	var req NotifyRequest
	if readJSON(r, &req) != nil {
		httpErr(w, "invalid request", http.StatusBadRequest)
		return
	}
	if err := d.sendCard(buildNotifyCard(req)); err != nil {
		logErr("发送通知卡片失败: %v", err)
		httpErr(w, "failed to send card", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// handleStop：Agent 停止时发送"已暂停"卡片，等待用户回复文字或点击按钮
func (d *Daemon) handleStop(w http.ResponseWriter, r *http.Request) {
	if !d.isActive() {
		writeJSON(w, StopResponse{Reply: "skip"})
		return
	}
	var req StopRequest
	if readJSON(r, &req) != nil {
		httpErr(w, "invalid request", http.StatusBadRequest)
		return
	}

	requestID := d.nextRequestID("stop")
	cardJSON := buildStopCard(req, requestID)
	if err := d.sendCard(cardJSON); err != nil {
		logErr("发送停止卡片失败: %v", err)
		// fail-open：卡片发送失败直接跳过，避免阻塞 Agent
		writeJSON(w, StopResponse{Reply: "skip"})
		return
	}

	reply, err := d.waitReply(requestID, req.Agent, approveTimeout)
	if err != nil {
		// 超时当作"结束会话"，不注入 followup
		logInfo("stop hook 等待回复超时，按结束处理")
		writeJSON(w, StopResponse{Reply: "skip"})
		return
	}

	writeJSON(w, StopResponse{Reply: reply})
}

// ── 卡片构建 ──

// buildNoteElement 统一生成卡片底部 note：第一行是操作上下文，第二行是 Agent 标识（非空才显示）
func buildNoteElement(contextNote, agent string) map[string]interface{} {
	elements := []interface{}{
		map[string]interface{}{
			"tag":     "plain_text",
			"content": fmt.Sprintf("📎 %s", contextNote),
		},
	}
	if strings.TrimSpace(agent) != "" {
		elements = append(elements, map[string]interface{}{
			"tag":     "plain_text",
			"content": fmt.Sprintf("🆔 %s", agent),
		})
	}
	return map[string]interface{}{
		"tag":      "note",
		"elements": elements,
	}
}

// 审批卡片：带 ✅ ❌ 按钮
func buildApproveCard(req ApproveRequest, requestID string) string {
	title := req.Title
	if title == "" {
		title = "操作待授权"
	}
	color := "orange"
	if req.Type == "mcp" {
		color = "purple"
	} else if req.Type == "mode_switch" {
		color = "blue"
	}
	contextNote := req.Context
	if contextNote == "" {
		contextNote = "Cursor Agent 请求"
	}

	card := map[string]interface{}{
		"config": map[string]interface{}{"wide_screen_mode": true},
		"header": map[string]interface{}{
			"title":    map[string]interface{}{"tag": "plain_text", "content": title},
			"template": color,
		},
		"elements": []interface{}{
			map[string]interface{}{
				"tag":  "div",
				"text": map[string]interface{}{"tag": "lark_md", "content": req.Content},
			},
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{
				"tag": "action",
				"actions": []interface{}{
					map[string]interface{}{
						"tag":  "button",
						"text": map[string]interface{}{"tag": "plain_text", "content": "✅ 授权"},
						"type": "primary",
						"value": map[string]interface{}{
							"action":     "allow",
							"request_id": requestID,
						},
					},
					map[string]interface{}{
						"tag":  "button",
						"text": map[string]interface{}{"tag": "plain_text", "content": "❌ 拒绝"},
						"type": "danger",
						"value": map[string]interface{}{
							"action":     "deny",
							"request_id": requestID,
						},
					},
				},
			},
			buildNoteElement(contextNote, req.Agent),
		},
	}
	data, _ := json.Marshal(card)
	return string(data)
}

// 提问卡片：有选项时加选项按钮，始终支持文字回复
func buildAskCard(req AskRequest, requestID string) string {
	content := fmt.Sprintf("**问题**\n%s", req.Question)
	contextNote := req.Context
	if contextNote == "" {
		contextNote = "Cursor Agent 提问"
	}

	elements := []interface{}{
		map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": content},
		},
		map[string]interface{}{"tag": "hr"},
	}

	// 有选项时添加选项按钮
	if len(req.Options) > 0 {
		buttons := make([]interface{}, 0, len(req.Options))
		for i, opt := range req.Options {
			buttons = append(buttons, map[string]interface{}{
				"tag":  "button",
				"text": map[string]interface{}{"tag": "plain_text", "content": fmt.Sprintf("%d. %s", i+1, opt)},
				"type": "default",
				"value": map[string]interface{}{
					"action":     fmt.Sprintf("%d", i+1),
					"request_id": requestID,
					"label":      opt,
				},
			})
		}
		elements = append(elements, map[string]interface{}{
			"tag":     "action",
			"actions": buttons,
		})
		elements = append(elements, buildNoteElement(
			fmt.Sprintf("%s（点击按钮或直接发消息回复）", contextNote),
			req.Agent,
		))
	} else {
		elements = append(elements, buildNoteElement(
			fmt.Sprintf("%s（请直接发消息回复）", contextNote),
			req.Agent,
		))
	}

	card := map[string]interface{}{
		"config": map[string]interface{}{"wide_screen_mode": true},
		"header": map[string]interface{}{
			"title":    map[string]interface{}{"tag": "plain_text", "content": "❓ 需要您的回复"},
			"template": "blue",
		},
		"elements": elements,
	}
	data, _ := json.Marshal(card)
	return string(data)
}

// Agent 停止卡片：展示 Agent 最后输出摘要，提供继续/结束按钮和文字回复入口
func buildStopCard(req StopRequest, requestID string) string {
	title := "⏸ Agent 已暂停"
	color := "orange"
	switch req.Status {
	case "error":
		title = "⚠️ Agent 出错停止"
		color = "red"
	case "aborted":
		title = "🛑 Agent 已中止"
		color = "grey"
	}

	summary := strings.TrimSpace(req.Summary)
	if summary == "" {
		summary = "_(Agent 没有最终输出)_"
	} else if len(summary) > 800 {
		// 仅截尾部，保留最新信息
		summary = "…" + summary[len(summary)-800:]
	}

	contentBody := fmt.Sprintf("**Agent 最后的输出：**\n%s", summary)

	elements := []interface{}{
		map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": contentBody},
		},
		map[string]interface{}{"tag": "hr"},
	}

	// 仅 completed 状态提供继续按钮；aborted/error 只允许结束
	actions := []interface{}{
		map[string]interface{}{
			"tag":  "button",
			"text": map[string]interface{}{"tag": "plain_text", "content": "🛑 结束会话"},
			"type": "danger",
			"value": map[string]interface{}{
				"action":     "skip",
				"request_id": requestID,
			},
		},
	}
	if req.Status == "completed" {
		// "继续" 按钮放在前面，默认主按钮
		actions = append([]interface{}{
			map[string]interface{}{
				"tag":  "button",
				"text": map[string]interface{}{"tag": "plain_text", "content": "▶️ 继续执行"},
				"type": "primary",
				"value": map[string]interface{}{
					"action":     "继续",
					"request_id": requestID,
				},
			},
		}, actions...)
	}

	elements = append(elements, map[string]interface{}{
		"tag":     "action",
		"actions": actions,
	})

	tip := "💬 **直接发消息** → 作为下一条指令发给 Agent\n🛑 **结束会话** → 停止本轮对话"
	if req.Status == "completed" {
		tip = "▶️ **继续执行** → 让 Agent 按默认继续\n💬 **直接发消息** → 自定义下一条指令\n🛑 **结束会话** → 停止本轮对话"
	}
	elements = append(elements, map[string]interface{}{
		"tag":  "div",
		"text": map[string]interface{}{"tag": "lark_md", "content": tip},
	})

	elements = append(elements, buildNoteElement(
		fmt.Sprintf("Agent 停止 · loop=%d · 10 分钟未回复自动结束", req.LoopCount),
		req.Agent,
	))

	card := map[string]interface{}{
		"config": map[string]interface{}{"wide_screen_mode": true},
		"header": map[string]interface{}{
			"title":    map[string]interface{}{"tag": "plain_text", "content": title},
			"template": color,
		},
		"elements": elements,
	}
	data, _ := json.Marshal(card)
	return string(data)
}

// 通知卡片（无按钮）
func buildNotifyCard(req NotifyRequest) string {
	color := req.Color
	if color == "" {
		color = "green"
	}
	title := req.Title
	if title == "" {
		title = "通知"
	}
	contextNote := req.Context
	if contextNote == "" {
		contextNote = "Cursor Agent"
	}

	card := map[string]interface{}{
		"config": map[string]interface{}{"wide_screen_mode": true},
		"header": map[string]interface{}{
			"title":    map[string]interface{}{"tag": "plain_text", "content": title},
			"template": color,
		},
		"elements": []interface{}{
			map[string]interface{}{
				"tag":  "div",
				"text": map[string]interface{}{"tag": "lark_md", "content": req.Content},
			},
			map[string]interface{}{"tag": "hr"},
			buildNoteElement(contextNote, req.Agent),
		},
	}
	data, _ := json.Marshal(card)
	return string(data)
}

// ── 决策解析 ──

func parseDecision(reply string) string {
	r := strings.TrimSpace(strings.ToLower(reply))
	for _, kw := range []string{"allow", "✅", "确认", "approve", "yes", "y", "ok", "执行", "run"} {
		if r == kw || strings.HasPrefix(r, kw) {
			return "allow"
		}
	}
	for _, kw := range []string{"deny", "❌", "拒绝", "reject", "no", "n", "跳过", "skip"} {
		if r == kw || strings.HasPrefix(r, kw) {
			return "deny"
		}
	}
	return "allow"
}

// ── 工具函数 ──

func readJSON(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func boolStr(b bool, t, f string) string {
	if b {
		return t
	}
	return f
}

func logInfo(format string, args ...interface{}) {
	log.Printf("[INFO] %s", fmt.Sprintf(format, args...))
}

func logErr(format string, args ...interface{}) {
	log.Printf("[ERROR] %s", fmt.Sprintf(format, args...))
}

func sleepCtx(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// ── main ──

func main() {
	logInfo("cursor-lark-bridge daemon 启动中... (version=%s)", version)
	d := newDaemon()
	if err := d.acquirePIDLock(); err != nil {
		logErr("%v", err)
		os.Exit(1)
	}
	defer d.removePID()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	d.startEventSubscription(ctx)

	server := &http.Server{Addr: listenAddr, Handler: d.setupRoutes()}
	go func() {
		logInfo("HTTP API 监听: %s", listenAddr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logErr("HTTP 服务错误: %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	logInfo("收到信号 %v，正在关闭...", sig)

	// 先显式端掉 lark-cli 子进程组，避免 daemon 被 SIGKILL 时留下孤儿
	// （SIGTERM 路径 ctx cancel 后 Go 也会 Kill 直接子进程，但对孙子进程不生效）
	d.killEventSubprocess()

	cancel()
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutCancel()
	server.Shutdown(shutCtx)
	logInfo("daemon 已停止")
}
