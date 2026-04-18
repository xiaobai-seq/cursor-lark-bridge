# cursor-lark-bridge

> 让你的 Cursor Agent 在你离开电脑时，通过飞书完成审批、提问、模式切换和停-继续交互。

[English](./README.md) · **简体中文**

`cursor-lark-bridge` 把 Cursor Agent 的每一个交互提示（Shell 审批、MCP 工具授权、`AskQuestion`、`SwitchMode`、stop hook 等）转发到你的**飞书单聊**里，你可以点卡片按钮或者直接发文字回复。Agent 在你坐地铁、开会、喝咖啡的时候继续干活。

---

## 为什么需要它

Cursor hooks 很强，但只在本地起作用。一旦你离开电脑，任何交互提示都会把 Agent 卡住。这个桥接器塞了一个小小的 Go daemon 到 Cursor hook 体系里，通过 `lark-cli` 跟飞书说话，把所有提示远程解决掉——有完整日志，每张卡片都带 Agent 标识，并发多会话也不会串台。

## 能干什么

- **覆盖 5 个 Cursor hook** – `beforeShellExecution`、`beforeMCPExecution`、`preToolUse`（`AskQuestion` / `SwitchMode`）、`afterAgentResponse`、`stop`。
- **卡片 + 文字双通道** – 点按钮 `✅ 批准` / `❌ 拒绝`，或者直接发消息。
- **并行会话安全** – 每张卡片带短标识（`项目名 · #abcd123`），可用 `FEISHU_BRIDGE_AGENT_LABEL=...` 覆盖。
- **daemon 自愈** – PID 锁杜绝多实例并存，子 `lark-cli` 独立进程组随 daemon 一起退出，stderr 驱动的冲突自动恢复，三档真实健康度探针（`subscribe_ok` / `last_event_age_ms` / `restart_count`）。
- **内置诊断器** – `fb doctor [--fix]` 覆盖 5 类真实故障（老版残留进程、lark-cli 孤儿、PID 漂移、19836 端口占用、hooks 重复），可一键自愈。
- **幂等安装器** – `install.sh` 可重复执行，`fb init` 合并到 `~/.cursor/hooks.json` 时会展示 diff 并备份原文件。
- **Go daemon 零第三方依赖** – 纯标准库，二进制 < 6 MB。
- **本地闭环** – 除了 daemon 主动发给飞书的消息，没有任何数据离开你的机器。

## 前置条件

| 工具 | 用途 |
|---|---|
| `bash`、`curl`、`python3`、`tar` | 安装器 + 运行时 |
| [`lark-cli`](https://github.com/larksuite/lark-cli) | daemon 用它发卡片、订阅事件 |
| Cursor IDE 且已启用 hooks | 这工具的运行基础 |
| `go` 1.22+ | **仅在**你选择从源码编译时需要 |

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

指定版本：

```bash
VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

没有匹配你平台的预编译二进制？从源码构建（需要 Go）：

```bash
BUILD_FROM_SOURCE=1 curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

## 首次配置

```bash
fb init
```

会带你过三步：

1. **lark-cli 检查** – 确认你已能跟飞书通信。
2. **open_id 自动探测** – `fb init` 会自动调 `lark-cli contact +get-user`，
   展示你的姓名 / `open_id` / 所属应用 ID，让你 `[Y/n]` 确认。这样可以保证
   `open_id` 和 daemon 发消息用的是**同一个应用**，从源头避免
   `open_id cross app` 报错。

   前置条件：你已经跑过 `lark-cli auth login` 完成 OAuth 登录。如果自动探测
   失败（未登录、网络异常等），会降级到手工粘贴。也可以直接命令行传入：

   ```bash
   fb init --open-id ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --force
   ```
3. **合并 hooks.json** – 展示 diff，备份原文件，把新的 hook 条目写进 `~/.cursor/hooks.json`。你已有的 hook 会原样保留。

## 日常使用

```bash
fb start              # 激活远程模式（会发一张激活卡片到飞书）
fb status             # 查看 daemon / 事件订阅 / 远程模式状态 + 版本号
fb stop               # 关闭远程模式，daemon 继续运行
fb kill               # 彻底停 daemon 进程
fb restart            # 重启 daemon 并重新激活
fb doctor             # 诊断常见故障（进程残留、端口占用、hooks 重复等）
fb doctor --fix       # 上面所有检查出来的问题一键自动修复（含 hooks.json 去重）
```

**远程模式激活**时，每一个 Cursor hook 都会路由到飞书。**关闭**时，hook 直接放行，Cursor 恢复正常。

`fb status` 会给出三档真实健康度：**健康**（订阅稳定超过 2 秒且最近有事件/心跳）、**不稳定**（在反复重启，通常意味着有冲突订阅者占坑）、**未运行**（lark-cli 子进程不存在）。出现非"健康"状态时请直接跑 `fb doctor`。

## 开机自启 + 崩溃自恢复（launchd）

v0.2 起 daemon 可以注册为 **User LaunchAgent**，开机自动启动 + 崩溃 10 秒内自动拉起。

```bash
fb service install     # 安装 plist 并 launchctl load
fb service status      # 查看 launchd 加载状态
fb service logs        # 打印 launchd stdout 日志尾部（加 err 看 stderr）
fb service uninstall   # 卸载，数据目录保留
```

安装后：

- **日志**落到 `~/.cursor/cursor-lark-bridge/logs/daemon-YYYY-MM-DD.log`（按天滚动，保留 7 天）
- launchd 的 stdout/stderr 另存 `logs/launchd-{stdout,stderr}.log`
- `fb start` 仍然有效：只激活"远程模式"，daemon 本身由 launchd 管着
- `fb kill` 会停 daemon，但 launchd 在 `ThrottleInterval=10` 秒后会再拉起 —— 想彻底停请用 `fb service uninstall`

首次开机或系统重启后，daemon 无需任何操作即可恢复服务。

## 飞书斜杠命令（远程查状态 + 批量取消）

v0.2 起你可以在飞书单聊里发**斜杠命令**给桥接器的 bot，快速查询或操作 daemon 状态。支持 ASCII `/` 和全角 `／`，命令不区分大小写。

| 命令 | 中文别名 | 功能 |
|---|---|---|
| `/ping` | — | 探活：返回 version · uptime · reconnect · 订阅状态 |
| `/status` | `/状态` | 蓝色卡片：daemon 健康度 + 所有待处理 pending（含 workspace + 等待时长） |
| `/stop` | `/停止` | 灰色卡片：批量取消所有 pending — Shell/MCP/Ask 收 deny，Agent 停止收 skip |
| `/help` | `/帮助` `/指令` | 列出所有可用命令 + 一句话说明 |

### 使用场景

- 离开电脑时飞书看到一张"Shell 授权"卡没注意响应了 `⏰ 超时`，想看看当前还有几条没处理 → `/status`
- 3 条长命令排队都不想再跑了 → `/stop`（同时取消待审批 + 待 AskQuestion 回复 + 待 stop hook）
- 忘了命令名 → `/帮助`

### 安全边界

- 斜杠命令**不走 pending FIFO**：即使并行发了 `/status`，当前正在等的审批也不会被错乱
- 群聊里不响应（daemon 只认配置里的单聊 `open_id`）
- `/stop` 的 `deny` 只会让 hook 返回"拒绝"，**不**杀任何进程 —— 想彻底停 daemon 请 `fb service stop`（launchd 10 秒内会再拉起）或 `fb service uninstall`

### 卡片样式预览

项目 `tests/slash-samples/` 目录下的 JSON 文件就是 4 张卡片的离线样例（`/status` 空 / `/status` 3 条 pending / `/stop` 取消 3 条 / `/help`）。用飞书开发者后台的[卡片搭建工具](https://open.feishu.cn/cardkit) 粘贴内容即可可视化。

## 并行多个 Cursor Agent

每个 hook 自动在卡片上打上短标识，类似 `my-project · #dfc1e56a`（由 workspace 路径 + 会话 ID 派生）。想要个更直观的名字：

```bash
export FEISHU_BRIDGE_AGENT_LABEL="🔥 线上热修复"
```

## 卸载

```bash
fb --uninstall
# 或者：
bash <(curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh) --uninstall
```

安装器会移除 daemon、hook 脚本、`fb` 软链接，并提醒你去 `~/.cursor/hooks.json` 里手动清理相关条目（如果你不想留的话）。

## 仓库目录

```
cursor-lark-bridge/
├── install.sh                  # 一键安装器
├── daemon/                     # Go HTTP daemon（纯标准库）
│   └── main.go
├── scripts/
│   ├── bridge.sh               # fb 命令的入口
│   └── hooks-merge.py          # 安全合并 ~/.cursor/hooks.json
├── hooks/                      # Cursor hook 脚本（bash）
│   ├── shell-approve.sh
│   ├── mcp-approve.sh
│   ├── pretool-approve.sh
│   ├── agent-response.sh
│   ├── on-stop.sh
│   └── agent-label.py
├── config/
│   ├── hooks-additions.json    # 标准 hook 条目定义
│   └── config.json.example     # open_id 模板（不含任何密钥）
└── tests/
    └── hooks-merge-test.sh
```

运行时安装器会在这些位置落地：

```
~/.cursor/cursor-lark-bridge/        # 二进制、config、日志
~/.cursor/hooks/cursor-lark-bridge/  # 被 hooks.json 引用的 hook 脚本
~/.local/bin/fb                      # 软链接 → bridge.sh
```

## 故障排查

**遇到怪问题，第一反应先跑 `fb doctor`。** 下面这张表列的每一种症状，基本都能被它一次性定位并用 `fb doctor --fix` 自愈。

| 现象 | 根因 | 处置 |
|---|---|---|
| `fb start` 报 `未找到 config.json` | 从没跑过初始化 | `fb init` |
| 飞书收不到卡片 | 事件订阅没跑起来 | `fb status`；若"事件订阅"为 `未运行` / `不稳定`，跑 `fb doctor --fix`；若 `lark-cli` 本身没登录，跑 `lark-cli auth login` |
| **电脑息屏一段时间后，消息就收不到了** | 上一次 daemon 非正常退出留下了 `lark-cli event +subscribe` 孤儿，霸占"一个 app 只能一个订阅者"的坑位，新启动的订阅始终拿不到 WebSocket | `fb doctor --fix`（会精确识别并清理孤儿，daemon 自动重连） |
| **一次交互收到两张授权卡片，第二张的按钮点了没反应** | `~/.cursor/hooks.json` 里同时保留了老版 `hooks/feishu-bridge/*` 和新版 `hooks/cursor-lark-bridge/*` 条目，每次交互被触发两次；而 Cursor 只 wait **第一个**返回的 hook 结果，第二张卡片的按钮事件被丢弃 | `fb doctor --fix`（会备份 hooks.json，过滤掉老条目，删掉老目录） |
| `daemon.log` 里出现 `HTTP 400: open_id cross app` | `config.json` 里的 `open_id` 和 `lark-cli` 当前绑定的应用不是同一个 | `fb init --force` 重新自动探测 |
| 卡片到了但按钮点了没反应（**只有一张卡片**的情况） | 多半是 lark-cli scope / 权限问题 | 看 `~/.cursor/cursor-lark-bridge/daemon.log`；确认机器人/应用开了 `im:message:send_as_bot` 等发消息作用域 |
| `fb status` 显示"事件订阅: 不稳定（正在重启，累计重启 N 次）" | 有进程在抢同一个订阅（常见：老版 daemon 还活着 / 上轮孤儿没清干净） | `fb doctor --fix` |
| `fb` 命令找不到 | `PATH` 里没有 `~/.local/bin` | 把 `~/.local/bin` 加到 `PATH` |
| `command not found: lark-cli` | 还没装 lark-cli | [安装 lark-cli](https://github.com/larksuite/lark-cli) |

完整日志：`~/.cursor/cursor-lark-bridge/daemon.log`。

### `fb doctor` 都检查什么

```text
[1/5] 老版 feishu-bridge 残留进程        → 会抢 19836 端口，必须清
[2/5] lark-cli event 订阅进程数         → 应当恰好是 2 个（node 壳 + 真二进制），多则为孤儿
[3/5] PID 文件一致性                    → 防止 `fb` 误判 daemon 状态
[4/5] 19836 端口谁在监听                → 非本 daemon 占用会让新 daemon bind 失败
[5/5] hooks.json 是否有老版 feishu-bridge 条目  → 造成"两张卡片第二张无效"
```

进程层面的扫描使用 `ps -o comm=` 过滤掉 `bash / sh / zsh` 等解释器，所以即便这个脚本自己的 `cmdline` 字面含 `feishu-bridge-daemon` 字符串，也不会误伤自己。

### 升级到新版本

`install.sh` 是幂等的：可以重复跑，daemon 二进制 / bridge.sh / hook 脚本会被覆盖，`config.json` 被保留。但**老 daemon 进程不会被自动停**，所以重装后必须自己 `fb restart`（或 `fb kill && fb start`）才能真正用上新二进制。根据你的起点选对应路径：

#### 情况 A：从旧版 `cursor-lark-bridge` 升级（v0.1.x → 最新）

包名、配置结构、hooks 路径都没变，只换二进制：

```bash
fb status                                                                           # 确认当前版本
fb kill                                                                             # 停老 daemon
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb start                                                                            # 启新 daemon
fb doctor                                                                           # 自检（无需 --fix）
```

**不用**再跑 `fb init` —— `open_id` 和 `~/.cursor/hooks.json` 都复用。

#### 情况 B：从重命名前的 `feishu-bridge` 项目升级

本项目早期叫 `feishu-bridge`，v0.1.0 重命名为 `cursor-lark-bridge`。如果你是从这个老项目升上来的，**需要额外一步 `fb doctor --fix` 清老残留**：

```bash
pkill -9 -f feishu-bridge-daemon || true                                            # 停老 daemon（老项目没 fb kill）
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb init                                                                             # 首次配置（新 open_id + 新 hooks 路径）
fb doctor --fix                                                                     # 一键清：老进程 / hooks.json 重复条目 / 老脚本目录
fb start
```

`fb doctor --fix` 会做：

1. 杀掉还活着的老 `feishu-bridge-daemon` 进程；
2. 备份并清理 `~/.cursor/hooks.json` 里指向 `hooks/feishu-bridge/*` 的老条目；
3. 删除 `~/.cursor/hooks/feishu-bridge/` 老脚本目录。

`~/.cursor/feishu-bridge/` 这个老**根目录**（老版的二进制、日志、config）`doctor` **不会**自动删，留给你确认里面没有值得保留的东西后手动 `rm -rf` 掉。

#### 情况 C：不确定当前状态 —— 一把梭

下面这串命令对"旧 cursor-lark-bridge"、"旧 feishu-bridge"、"从未装过"这三种起点都安全：

```bash
fb kill 2>/dev/null || pkill -9 -f feishu-bridge-daemon 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb init          # 已有 config.json 会被保留；没有才真正走首次配置
fb doctor --fix  # 任何残留一键清
fb start
```

## 安全说明

- 你的 `open_id` 放在 `~/.cursor/cursor-lark-bridge/config.json`（权限 0600）。安装器永远不会把它放进仓库或其他公开位置。
- daemon 只监听 `127.0.0.1:19836`。
- `.gitignore` 已排除 `config.json`、日志、PID 文件、Agent 输出缓存。

## 贡献

欢迎提 PR / Issue。请保持 daemon 的**纯标准库**取向，提交前跑一下 `bash tests/hooks-merge-test.sh`。

## License

[MIT](./LICENSE)
