# cursor-lark-bridge

> Approve, answer, and steer your Cursor Agent from Feishu / Lark — even when you're away from the keyboard.

**[简体中文](./README.zh-CN.md)** · English

`cursor-lark-bridge` forwards every Cursor Agent prompt (shell approval, MCP tool approval, `AskQuestion`, `SwitchMode`, stop-hook resume) to a Feishu one-to-one chat, and lets you reply with either a card button or free-form text. The Agent keeps running while you're on the subway, in a meeting, or out for coffee.

---

## Why

Cursor hooks are powerful but local. If you walk away from your laptop, the Agent stalls on any interactive prompt. This bridge plugs a tiny Go daemon into Cursor's hook system, talks to Feishu over `lark-cli`, and resolves every prompt remotely — with full audit trail and a clear per-agent identifier so parallel sessions don't get confused.

## Features

- **Five Cursor hooks covered** – `beforeShellExecution`, `beforeMCPExecution`, `preToolUse` (`AskQuestion` / `SwitchMode`), `afterAgentResponse`, `stop`.
- **Card + text fallback** – click `✅ Approve` / `❌ Deny` or just type a reply.
- **Multi-agent safe** – each card shows a per-conversation label (`project · #abcd123`); override with `FEISHU_BRIDGE_AGENT_LABEL=...`.
- **Idempotent installer** – `install.sh` is safe to re-run, and `fb init` merges into your existing `~/.cursor/hooks.json` with a diff preview and backup.
- **Zero third-party Go deps** – stdlib only; binary < 6 MB.
- **Offline-friendly** – no data leaves your machine except the Feishu messages the daemon itself sends.

## Requirements

| Tool | Why |
|---|---|
| `bash`, `curl`, `python3`, `tar` | installer + runtime |
| [`lark-cli`](https://github.com/larksuite/lark-cli) | daemon uses it to send cards and subscribe to events |
| Cursor IDE with hooks enabled | the whole point |
| `go` 1.22+ | **only** if you build from source |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

Pick a specific release:

```bash
VERSION=v0.1.0 curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

No prebuilt binary for your platform? Build from source (requires Go):

```bash
BUILD_FROM_SOURCE=1 curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
```

## Configure (one-time)

```bash
fb init
```

This walks you through three steps:

1. **`lark-cli` check** – confirms you can talk to Feishu.
2. **`open_id`** – paste in your own Feishu `open_id`. Get it with:
   ```bash
   lark-cli contact +batchGetId --emails you@example.com
   ```
3. **`hooks.json` merge** – shows you a diff, backs up the original, and writes `~/.cursor/hooks.json` with the new entries. Your existing hooks are preserved.

## Daily use

```bash
fb start      # activate remote mode (sends an activation card to Feishu)
fb status     # show daemon / event-subscribe / remote-mode state + version
fb stop       # deactivate remote mode, daemon keeps running
fb kill       # stop the daemon process entirely
fb restart    # restart daemon and re-activate
```

While remote mode is **active**, every Cursor hook is routed through Feishu. When it's **inactive**, hooks no-op and Cursor behaves normally.

## Running multiple Cursor agents in parallel

Each hook automatically tags the card with a short label derived from the workspace + conversation ID, e.g. `my-project · #dfc1e56a`. If you want a friendlier name:

```bash
export FEISHU_BRIDGE_AGENT_LABEL="🔥 live hotfix"
```

## Uninstall

```bash
fb --uninstall
# or, equivalently:
bash <(curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh) --uninstall
```

The installer removes the daemon, hook scripts and `fb` symlink, and reminds you to clean up entries from `~/.cursor/hooks.json` if you no longer want them.

## Repository layout

```
cursor-lark-bridge/
├── install.sh                  # one-liner installer
├── daemon/                     # Go HTTP daemon (stdlib only)
│   └── main.go
├── scripts/
│   ├── bridge.sh               # the `fb` command entrypoint
│   └── hooks-merge.py          # safe merger for ~/.cursor/hooks.json
├── hooks/                      # Cursor hook scripts (bash)
│   ├── shell-approve.sh
│   ├── mcp-approve.sh
│   ├── pretool-approve.sh
│   ├── agent-response.sh
│   ├── on-stop.sh
│   └── agent-label.py
├── config/
│   ├── hooks-additions.json    # canonical hook entries
│   └── config.json.example     # open_id template (no secrets)
└── tests/
    └── hooks-merge-test.sh
```

At runtime the installer lays things out under:

```
~/.cursor/cursor-lark-bridge/     # binary, config, logs
~/.cursor/hooks/cursor-lark-bridge/  # hook scripts referenced by hooks.json
~/.local/bin/fb                   # symlink → bridge.sh
```

## Troubleshooting

| Symptom | What to try |
|---|---|
| `未找到 config.json` on `fb start` | run `fb init` first |
| Feishu receives no cards | `fb status` — is `event subscribe` running? If not, check `lark-cli auth login` (daemon runs it as bot). |
| Cards arrive, buttons don't resolve | inspect `~/.cursor/cursor-lark-bridge/daemon.log` — usually a lark-cli scope / permission issue |
| `fb` not found in shell | add `~/.local/bin` to `PATH` |
| `command not found: lark-cli` | install it first: https://github.com/larksuite/lark-cli |

Full log: `~/.cursor/cursor-lark-bridge/daemon.log`.

## Security notes

- Your `open_id` lives in `~/.cursor/cursor-lark-bridge/config.json` (mode 0600). The installer never places it in the repo or anywhere world-readable.
- The daemon listens only on `127.0.0.1:19836`.
- `.gitignore` excludes `config.json`, logs, PID, and cached Agent output.

## Contributing

PRs and issues are welcome. Please keep the stdlib-only, zero-dependency stance of the daemon, and run `bash tests/hooks-merge-test.sh` before submitting.

## License

[MIT](./LICENSE)
