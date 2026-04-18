# Changelog

本项目采用 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 规范。版本遵循 [SemVer 2.0](https://semver.org/lang/zh-CN/)。

## [0.2.0] - 2026-04-18

运维硬化 + 飞书斜杠命令。整体保持 v0.1.x 的 Hook 模型不变（现有 `~/.cursor/hooks/cursor-lark-bridge/` 全部保留），所有升级都在 daemon 和 `bridge.sh` 内部完成，无需修改 `hooks.json`。

### Added

- **launchd 自启**：新子命令 `fb service {install|uninstall|start|stop|status|logs}`，把 daemon 注册为 User LaunchAgent。开机自启、崩溃 10 秒内自恢复（`KeepAlive.Crashed=true` + `ThrottleInterval=10`），plist 模板见 `launchd/com.cursor.feishu-bridge.plist.template`。
- **按天滚动日志**：daemon 写入 `~/.cursor/cursor-lark-bridge/logs/daemon-YYYY-MM-DD.log`，跨天自动 rotate，启动时清理 7 天前的历史日志；legacy `daemon.log` 首次启动会迁移到 `logs/daemon-legacy-<ts>.log` 保留查询。
- **supervisor 指数退避**：lark-cli 事件订阅子进程从固定 3s 重试改为 2s→4s→…→5 分钟封顶，收到首条事件后自动重置回 2s。每次重连在 `daemon.pid` 的 `reconnect_count` 上 +1。
- **飞书斜杠命令**：在飞书单聊里直接发指令操作 daemon。支持 ASCII `/` 和全角 `／`，命令不区分大小写：
  - `/ping` — 探活 + 版本/uptime/reconnect/订阅状态
  - `/status`（中文别名 `/状态`）— 蓝色卡片：daemon 健康度 + 所有 pending（workspace、等待时长、agent 标识、kind 图标）
  - `/stop`（中文别名 `/停止`）— 灰色卡片：批量取消所有 pending（Shell/MCP/Ask 收 deny，Agent 停止收 skip）
  - `/help`（中文别名 `/帮助` `/指令`）— 命令清单卡片
- **斜杠卡片离线样例**：`tests/slash-samples/*.json` 4 份样例 JSON 可直接粘进飞书 [卡片搭建工具](https://open.feishu.cn/cardkit) 预览。

### Changed

- **`daemon.pid` 升级为 JSON**：原单行 PID → `{pid, start_ts, version, reconnect_count}`。`bridge.sh` 侧新增 `read_pid_from_file` helper 处理新旧格式，旧单行 PID 文件仍被认读（升级期零风险）。
- **`fb status` 增强**：在原有 daemon running / event subscribe / active 三行上新增 `Uptime` 和 `Reconnects` 两行（当 daemon.pid 是新 JSON 格式时显示）。
- **启动日志重定向**：`fb start` 的 nohup 输出从 `daemon.log` 改到 `logs/launchd-stderr.log`，与 launchd 托管场景对齐。daemon 启动失败时 `fb status` 会按 `今日 daemon-*.log → launchd-stderr.log → 历史 daemon.log` 顺序智能 tail。
- **Cursor hook 补全 metadata**：`shell-approve.sh` / `mcp-approve.sh` / `pretool-approve.sh` / `on-stop.sh` 向 daemon 传 `kind` / `summary` / `workspace` 字段供 `/status` 展示。所有 summary 在 hook 层就做脱敏（`api[_-]?key` / `password` / `token` / `secret` / `bearer` → `***`），`on-stop` 的 Agent 输出也补上了同级脱敏。
- **`pendingEntry` 加元信息字段**：`id` / `kind` / `summary` / `workspace` / `createdTS`；`pendingMu` 从 `sync.Mutex` 升级为 `RWMutex`，`/status` 的 snapshot 用读锁不阻塞正常审批路径。

### Fixed

- **`fb kill` / `fb doctor --fix` 在 JSON PID 格式下不再误删活 daemon**：rework 补齐 `bridge.sh` 里 6 处 `cat "$PID_FILE"` 为 `read_pid_from_file`，`cmd_doctor --fix` 修复指令从“写单行 PID”改为“运行 `fb restart` 让 daemon 自己重写 JSON”。
- **shell-approve summary 长度**：拼上 `@ <cwd basename>` 后再做 80 字截断，之前边界场景会超出给 `/status` 卡片带来溢出。

### Internal

- **测试覆盖**：daemon 单测 47 个（含 `-race` 并发检查），覆盖 rolling-log / PID JSON / supervisor backoff / pending snapshot / 4 条斜杠命令。
- **bash 测试**：`tests/service-install-test.sh`（launchd plist 本地渲染 + `plutil -lint`）、`tests/read-pid-from-file-test.sh`（JSON/单行/垃圾/空/不存在 5 类输入）、`tests/hook-metadata-test.sh`（脱敏 + workspace + 字段存在性）、`tests/p0-e2e.sh`（smoke 默认 + `--real` 带备份恢复）、`tests/p2-e2e.sh`（综合 smoke + 卡片样例生成）。
- **Go 模块**：`daemon/` 继续零第三方依赖（纯标准库）；二进制体积约 8.4 MB。
- **SlashCommand 接口**：`Name() / Aliases() / Match() / Execute() / Description()`；新命令只需 append 到 `slashRegistry`，`/help` 自动感知。
- **开发流程**：本版本通过 Planner / Generator / Evaluator 三 subagent 协作在独立 git worktree（`feat/v2-ops-and-slash`）上完成，每个 task 带 spec 合规 + 代码质量两阶段审查，详见 `docs/plans/2026-04-18-v2-ops-and-slash.md`。

### 向前兼容

- **Hook 契约**：`hooks/*.sh` 发给 daemon 的 JSON 字段全部 `omitempty`；旧 hook 不发新字段 daemon 仍能工作，反之新 daemon 收到老字段也认。
- **PID 文件**：新 daemon 读旧单行 PID；旧 daemon 无法读新 JSON —— 升级时 daemon 重启一次即可全部齐活（launchd 或 `fb restart` 都会触发）。
- **launchd 可选**：`fb service install` 是可选动作，不跑也能继续用 v0.1.x 的 `fb start` 风格手动启动；建议打开以获得开机自启。

## [0.1.5] - 2026-04-17

历史版本见 `git log --oneline 89b9ede^..89b9ede`。

---

[0.2.0]: https://github.com/xiaobai-seq/cursor-lark-bridge/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/xiaobai-seq/cursor-lark-bridge/releases/tag/v0.1.5
