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
- **Self-healing daemon** – PID lock prevents double daemons, child `lark-cli` lives in its own process group and dies with the daemon, stderr-driven auto-recovery from `already running` conflicts, real three-tier health probe (`subscribe_ok` / `last_event_age_ms` / `restart_count`).
- **Built-in diagnostics** – `fb doctor [--fix]` checks five classes of real-world breakage (legacy processes, lark-cli orphans, PID drift, port 19836, duplicate hook entries) and can auto-repair all of them.
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
2. **`open_id`** – `fb init` calls `lark-cli contact +get-user` under the hood,
   shows you the detected name / `open_id` / owning app, and asks for `[Y/n]`
   confirmation. This guarantees the `open_id` was issued by the **same app**
   the daemon will later use to send messages, preventing the
   `open_id cross app` error.

   Prerequisite: you've run `lark-cli auth login` once so `lark-cli` is
   authenticated. If auto-detection fails (not logged in, network issue, etc.)
   the prompt falls back to manual paste. You can also override up-front:

   ```bash
   fb init --open-id ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --force
   ```
3. **`hooks.json` merge** – shows you a diff, backs up the original, and writes `~/.cursor/hooks.json` with the new entries. Your existing hooks are preserved.

## Daily use

```bash
fb start              # activate remote mode (sends an activation card to Feishu)
fb status             # show daemon / event-subscribe / remote-mode state + version
fb stop               # deactivate remote mode, daemon keeps running
fb kill               # stop the daemon process entirely
fb restart            # restart daemon and re-activate
fb doctor             # diagnose common failure modes (stale procs, port, hooks, ...)
fb doctor --fix       # one-shot auto-fix for everything the diagnostic turns up
```

While remote mode is **active**, every Cursor hook is routed through Feishu. When it's **inactive**, hooks no-op and Cursor behaves normally.

`fb status` reports a three-tier health for the event subscription: **healthy** (stable for >2 s and receiving events/heartbeats), **unstable** (currently restarting — usually a conflicting subscriber holding the slot), **not running** (the `lark-cli` child process is gone). Anything other than "healthy" → run `fb doctor`.

## Auto-start + crash recovery (launchd)

Since v0.2 the daemon can register as a **User LaunchAgent** for auto-start at
login and automatic crash recovery within ~10s.

```bash
fb service install     # install plist and launchctl load
fb service status      # show launchd load state
fb service logs        # tail launchd stdout (use `logs err` for stderr)
fb service uninstall   # remove the plist (data dir preserved)
```

After install:

- **Logs** land in `~/.cursor/cursor-lark-bridge/logs/daemon-YYYY-MM-DD.log`
  (per-day rotation, 7-day retention).
- launchd's own stdout/stderr go to `logs/launchd-{stdout,stderr}.log`.
- `fb start` keeps working: it only flips the "remote mode" flag — the daemon
  itself is now supervised by launchd.
- `fb kill` stops the daemon, but launchd will bring it back within
  `ThrottleInterval=10` seconds. To fully stop, run `fb service uninstall`.

The daemon comes back on its own after reboots — no manual step needed.

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

**When something feels off, run `fb doctor` first.** Every symptom in the table below can be pinpointed — and, for most of them, auto-fixed with `fb doctor --fix`.

| Symptom | Root cause | What to do |
|---|---|---|
| `未找到 config.json` on `fb start` | never initialized | `fb init` |
| Feishu receives no cards at all | event subscribe is not running | `fb status` — if `event subscribe` is `not running` / `unstable`, run `fb doctor --fix`; if `lark-cli` itself is not authenticated, run `lark-cli auth login` |
| **Messages stop arriving after the screen has been off for a while** | a previous crash left a `lark-cli event +subscribe` orphan holding the "one-subscriber-per-app" slot, so every subsequent reconnect is rejected | `fb doctor --fix` — kills the orphan and the daemon reconnects automatically |
| **Every interaction delivers two authorization cards and the second card's buttons do nothing** | `~/.cursor/hooks.json` contains both the old `hooks/feishu-bridge/*` entries and the new `hooks/cursor-lark-bridge/*` entries; Cursor only awaits the **first** hook's response, so the second card's button events are discarded | `fb doctor --fix` — backs up `hooks.json`, removes the stale entries, and deletes the old `hooks/feishu-bridge/` directory |
| `HTTP 400: open_id cross app` in `daemon.log` | the `open_id` in `config.json` was issued by a different app than the one `lark-cli` is currently bound to | `fb init --force` to re-detect under the current app |
| Cards arrive (**just one**) but the button does nothing | usually a lark-cli scope / permission issue | read `~/.cursor/cursor-lark-bridge/daemon.log`; make sure the bot/app has `im:message:send_as_bot` and related scopes |
| `fb status` shows `event subscribe: unstable (restarting, total N restarts)` | someone else is contending for the same subscription slot (stale orphan, legacy daemon, …) | `fb doctor --fix` |
| `fb` not found in shell | `~/.local/bin` not on `PATH` | add `~/.local/bin` to `PATH` |
| `command not found: lark-cli` | lark-cli is not installed | [install lark-cli](https://github.com/larksuite/lark-cli) |

Full log: `~/.cursor/cursor-lark-bridge/daemon.log`.

### What `fb doctor` actually checks

```text
[1/5] legacy feishu-bridge processes   → they would steal port 19836
[2/5] lark-cli event subscribers       → expect exactly 2 (node shim + real binary); more = orphans
[3/5] PID file consistency             → prevents `fb` from misreading daemon state
[4/5] whoever is listening on 19836    → a non-bridge occupant makes the new daemon's bind fail
[5/5] stale feishu-bridge entries in hooks.json  → root cause of the "two cards, second inert" bug
```

Process scans filter out shell interpreters via `ps -o comm=`, so even if the doctor script's own `cmdline` contains the literal string `feishu-bridge-daemon`, it will never match itself.

### Upgrading to a newer version

`install.sh` is idempotent: re-run it and the daemon binary / `bridge.sh` / hook scripts are overwritten while `config.json` is preserved. The installer does **not** stop the running daemon, so you have to `fb restart` (or `fb kill && fb start`) after the upgrade to actually run the new binary. Pick your path below based on where you are starting from:

#### Case A: upgrading an existing `cursor-lark-bridge` (v0.1.x → latest)

Same package name, same config layout, same hook paths — just replace the binary:

```bash
fb status                                                                           # inspect current version
fb kill                                                                             # stop the old daemon
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb start                                                                            # bring the new daemon up
fb doctor                                                                           # self-check (no --fix needed)
```

No need to re-run `fb init` — your `open_id` and `~/.cursor/hooks.json` are reused.

#### Case B: upgrading from the old `feishu-bridge` project

This project was called `feishu-bridge` before v0.1.0 and was renamed to `cursor-lark-bridge`. Coming from the old name needs one extra `fb doctor --fix` to sweep residues:

```bash
pkill -9 -f feishu-bridge-daemon || true                                            # old project had no fb kill
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb init                                                                             # first-time configure (new open_id + new hook paths)
fb doctor --fix                                                                     # sweep: old procs / duplicate hooks / stale dirs
fb start
```

`fb doctor --fix` will:

1. Kill any surviving old `feishu-bridge-daemon` process.
2. Back up and strip the `hooks/feishu-bridge/*` entries from `~/.cursor/hooks.json`.
3. Remove the old `~/.cursor/hooks/feishu-bridge/` scripts directory.

The old **root** directory `~/.cursor/feishu-bridge/` (binary, logs, config from the old project) is intentionally **not** removed automatically — look through it first, then `rm -rf` it by hand if you don't need anything inside.

#### Case C: not sure what you have — the catch-all

The sequence below is safe for "old `cursor-lark-bridge`", "old `feishu-bridge`", and "never installed":

```bash
fb kill 2>/dev/null || pkill -9 -f feishu-bridge-daemon 2>/dev/null || true
curl -fsSL https://raw.githubusercontent.com/xiaobai-seq/cursor-lark-bridge/main/install.sh | bash
fb init          # existing config.json is preserved; only prompts if it's truly a first install
fb doctor --fix  # clear whatever residue is found
fb start
```

## Security notes

- Your `open_id` lives in `~/.cursor/cursor-lark-bridge/config.json` (mode 0600). The installer never places it in the repo or anywhere world-readable.
- The daemon listens only on `127.0.0.1:19836`.
- `.gitignore` excludes `config.json`, logs, PID, and cached Agent output.

## Contributing

PRs and issues are welcome. Please keep the stdlib-only, zero-dependency stance of the daemon, and run `bash tests/hooks-merge-test.sh` before submitting.

## License

[MIT](./LICENSE)
