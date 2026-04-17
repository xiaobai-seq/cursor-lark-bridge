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
2. **open_id 输入** – 粘贴你自己的飞书 `open_id`，可通过：
   ```bash
   lark-cli contact +batchGetId --emails you@example.com
   ```
   获取。
3. **合并 hooks.json** – 展示 diff，备份原文件，把新的 hook 条目写进 `~/.cursor/hooks.json`。你已有的 hook 会原样保留。

## 日常使用

```bash
fb start      # 激活远程模式（会发一张激活卡片到飞书）
fb status     # 查看 daemon / 事件订阅 / 远程模式状态 + 版本号
fb stop       # 关闭远程模式，daemon 继续运行
fb kill       # 彻底停 daemon 进程
fb restart    # 重启 daemon 并重新激活
```

**远程模式激活**时，每一个 Cursor hook 都会路由到飞书。**关闭**时，hook 直接放行，Cursor 恢复正常。

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

| 现象 | 建议 |
|---|---|
| `fb start` 报 `未找到 config.json` | 先跑 `fb init` |
| 飞书收不到卡片 | 执行 `fb status`，看"事件订阅"是否在跑；若没有，检查 `lark-cli auth login`（daemon 会以 bot 身份订阅） |
| 卡片到了但按钮点了没反应 | 看 `~/.cursor/cursor-lark-bridge/daemon.log`，大概率是 lark-cli scope / 权限问题 |
| `fb` 命令找不到 | 把 `~/.local/bin` 加到 `PATH` |
| `command not found: lark-cli` | 先装 lark-cli: https://github.com/larksuite/lark-cli |

完整日志： `~/.cursor/cursor-lark-bridge/daemon.log`。

## 安全说明

- 你的 `open_id` 放在 `~/.cursor/cursor-lark-bridge/config.json`（权限 0600）。安装器永远不会把它放进仓库或其他公开位置。
- daemon 只监听 `127.0.0.1:19836`。
- `.gitignore` 已排除 `config.json`、日志、PID 文件、Agent 输出缓存。

## 贡献

欢迎提 PR / Issue。请保持 daemon 的**纯标准库**取向，提交前跑一下 `bash tests/hooks-merge-test.sh`。

## License

[MIT](./LICENSE)
