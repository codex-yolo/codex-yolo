> [!CAUTION]
> **DO NOT USE THIS TOOL ON CORPORATE HARDWARE OR CONNECTED TO A CORPORATE NETWORK.**
>
> This tool auto-approves all Codex CLI permission prompts without human review, including destructive commands. For maximum isolation, run it on a **dedicated bare-metal server** with no personal data, no saved credentials, and no access to sensitive networks. You accept full responsibility for any consequences.

# codex-yolo

Run parallel OpenAI Codex CLI agents in tmux with automatic permission approval. Optionally isolate each agent in its own git worktree with real-time merge conflict detection and automated conflict resolution.

When approval policy is set to `on-request` or `untrusted`, Codex CLI prompts the user before running commands, applying edits, or accessing the network. Standard agent windows are launched with Codex's `--yolo` mode for maximum automation; the tmux approver daemon remains in place for prompt styles that still appear.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Worktree mode](#worktree-mode)
- [Navigation](#navigation)
- [Control commands](#control-commands)
- [Options](#options)
- [How it works](#how-it-works)
  - [Detection signals](#detection-signals)
  - [Worktree pipeline](#worktree-pipeline)
- [File structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Testing](#testing)
- [Key features](#key-features)
- [Development history](#development-history)

## Installation

**One-liner** (macOS, Linux, WSL, Termux):

```bash
command -v curl >/dev/null || { s=; [ "$(id -u)" != 0 ] && s=sudo; command -v apt-get >/dev/null && { $s apt-get update && $s apt-get install -y curl; } || command -v dnf >/dev/null && $s dnf install -y curl || command -v yum >/dev/null && $s yum install -y curl || command -v apk >/dev/null && $s apk add curl || command -v pacman >/dev/null && $s pacman -S --noconfirm curl || command -v pkg >/dev/null && pkg install -y curl || command -v brew >/dev/null && brew install curl; }; curl -fsSL https://raw.githubusercontent.com/codex-yolo/codex-yolo/refs/heads/main/install.sh | bash && export PATH="${CODEX_YOLO_BIN_DIR:-$HOME/.local/bin}:${CODEX_YOLO_HOME:-$HOME/.codex-yolo}/bin:$PATH"
```

This clones to `~/.codex-yolo` and symlinks the binary into `~/.local/bin`. If `~/.local/bin` is not writable, the installer falls back to `~/.codex-yolo/bin`; you can also set `CODEX_YOLO_BIN_DIR` to choose a writable bin directory. It also installs `git`, `tmux`, `curl`, and `codex` if they are missing. Codex CLI is installed from the standalone GitHub release first, with npm as a fallback. Override the install location with `CODEX_YOLO_HOME`:

```bash
CODEX_YOLO_HOME="$HOME/my/path"; command -v curl >/dev/null || { s=; [ "$(id -u)" != 0 ] && s=sudo; command -v apt-get >/dev/null && { $s apt-get update && $s apt-get install -y curl; } || command -v dnf >/dev/null && $s dnf install -y curl || command -v yum >/dev/null && $s yum install -y curl || command -v apk >/dev/null && $s apk add curl || command -v pacman >/dev/null && $s pacman -S --noconfirm curl || command -v pkg >/dev/null && pkg install -y curl || command -v brew >/dev/null && brew install curl; }; curl -fsSL https://raw.githubusercontent.com/codex-yolo/codex-yolo/refs/heads/main/install.sh | CODEX_YOLO_HOME="$CODEX_YOLO_HOME" bash && export PATH="${CODEX_YOLO_BIN_DIR:-$HOME/.local/bin}:$CODEX_YOLO_HOME/bin:$PATH"
```

**Local install** (from a cloned repo; no network access needed if Codex CLI is already installed):

```bash
git clone https://github.com/codex-yolo/codex-yolo.git ~/.codex-yolo
cd ~/.codex-yolo
./install.sh --local
```

**Manual install:**

```bash
git clone https://github.com/codex-yolo/codex-yolo.git ~/.codex-yolo
ln -s ~/.codex-yolo/codex-yolo ~/.local/bin/codex-yolo
```

Then run from any project directory:

```bash
cd /path/to/your/project
codex-yolo "fix the tests" "update docs"
```

The tool runs agents in whatever directory you invoke it from (or the `-d`/`--dir` path if specified).

## Quick start

```bash
# Run three agents in parallel
codex-yolo "fix the login bug" "add unit tests for auth" "update the README"

# Use a specific model
codex-yolo -m o4-mini "refactor the API layer"

# Point agents at a different project
codex-yolo -d /path/to/project "run the test suite and fix failures"
```

Once launched, you're inside a tmux session with one window per agent. The last window (`control`) tails the audit log in real time and accepts slash commands.

## Worktree mode

With `--worktree` (`-w`), each agent gets its own git worktree and branch so parallel tasks do not overwrite each other's files:

```bash
codex-yolo -w -s feat -d /path/to/repo \
  "implement auth system" \
  "add database migrations" \
  "write API tests"
```

This creates worktrees under `<repo>-worktrees/<session>/`, runs each task with `codex exec`, polls branch pairs with `git merge-tree`, and opens a `merge` window that waits for agents to finish before merging the branches back into the base branch.

Skip auto-merge to inspect worktrees manually:

```bash
codex-yolo -w --no-merge -s feat -d /repo "task1" "task2"

git diff main..feat-1
git diff main..feat-2
git checkout main && git merge feat-1 && git merge feat-2

source ~/.codex-yolo/lib/worktree-manager.sh
wt_cleanup feat
```

See [docs/worktree-mode-demo.md](docs/worktree-mode-demo.md) for a complete demo.

## Navigation

| Key | Action |
|---|---|
| `Ctrl-b w` | List all agent windows and select one |
| `Ctrl-b s` | Switch between agent windows |
| `Ctrl-b n` | Next pane |
| `Ctrl-b p` | Previous pane |
| `Ctrl-b x` | Stop the current agent, close pane |
| `Ctrl-b d` | Detach (agents keep running) |

Re-attach later with `codex-yolo -r` (or `codex-yolo --resume`).

## Control commands

The `control` window accepts slash commands while continuing to show the audit log.

```bash
/loop 1h Continue experiments and push best submission
/loop 1h /plan Draft the next implementation plan
/loop 1h /queue ["/status", "/clear", "/plan Draft the next implementation plan"]
/queue ["/status", "/clear", "Continue from the latest result"]
/plan Draft the implementation plan before coding
```

Available commands:

| Command | Action |
|---|---|
| `/permissions auto-review` | Open Codex `/permissions`, make Auto-review current for `agent-1`, then return to chat |
| `/plan [prompt]` | Send Codex `/plan` to `agent-1`; pasted multiline prompts are supported and plan approval is auto-confirmed only for this control-pane command |
| `/queue ["item1", "item2"]` | Run prompts or slash commands sequentially on `agent-1`; each item waits for the previous item to finish |
| `/queue add <id> ["item"]` | Append pending items to an active queue |
| `/queue edit <id> <index> ["item"]` | Replace one pending queue item |
| `/queue remove <id> <index-or-range>` | Remove pending queue item(s), for example `2` or `2-4` |
| `/queue dequeue <id>` | Remove the next pending item; `/queue deque <id>` is also accepted |
| `/queue show <id>` | Show numbered queue items |
| `/queues` | List active queues |
| `/queues cancel <id>` | Cancel one queue |
| `/loop <interval> <prompt>` | Send `<prompt>` to `agent-1` immediately, then every interval until canceled; if `<prompt>` starts with `/plan`, each iteration uses scoped plan auto-approval |
| `/loop <interval> /queue ["item1", "item2"]` | Run the full queue immediately, then repeat after each queue run completes and the interval elapses |
| `/loops` | List active loops |
| `/loops cancel <id>` | Cancel one loop |
| `/help` | Show command help |

Intervals are whole numbers with `s`, `m`, `h`, or `d`, for example `30s`, `15m`, `1h`, or `1d`.
Queue item lists must be arrays of quoted strings. Use single quotes, double quotes, or triple quotes for multiline items:

```bash
/queue ['item1', 'item2', 'item3']
/queue ["item1", "item2", "item3"]
/queue ["""item1
item1""", """item2
item2"""]
/queue ['''item1
item1''', '''item2
item2''']
```

`/plan`, `/queue`, and `/loop` are disabled in worktree mode because agent windows run `codex exec` and may exit.
When pasting a multiline `/plan` command into the interactive control pane, lines pasted immediately after the first `/plan` line are sent as part of the same plan prompt.
Scheduled `/loop <interval> /plan <prompt>` commands use the same scoped plan approval marker as direct control-pane `/plan` commands on every iteration.
Scheduled `/loop <interval> /queue [...]` commands wait for each queued item to complete before sending the next item, and they do not start the next loop iteration until the previous queue run has finished.

## Options

```
-s, --session NAME    Custom tmux session name (default: codex-yolo-<timestamp>)
-d, --dir PATH        Working directory for agents (default: current directory)
-m, --model MODEL     Model to use (e.g., o4-mini, o3, gpt-4.1)
-p, --poll SECONDS    Approver poll interval (default: 0.3)
-f, --file FILE       Read a multiline prompt from a text file
-r, --resume          Re-attach to an existing yolo session
--permissions PROFILE Set Codex /permissions profile (default: full-access when allowed, else auto-review)
--no-codex-sandbox    Disable Codex sandboxing (for externally sandboxed containers)
--force-codex-sandbox Require Codex sandboxing; do not auto-fallback when unsupported
-h, --help            Show help

Worktree options:
-w, --worktree          Run each agent in its own git worktree
--base-branch BRANCH    Base branch for worktrees (default: current branch)
--no-merge              Skip auto-merge after agents complete
--no-cleanup            Keep worktrees after merge
--conflict-poll SECS    Conflict detection interval (default: 5)

install.sh options:
--local               Install from the local repo without pulling from GitHub
```

By default, `codex-yolo` probes `codex sandbox linux true` once. In containers
where bubblewrap fails with namespace permission errors, `codex-yolo` creates a
temporary fake `bwrap` earlier in `PATH` and launches agents without Codex
sandboxing. The fake `bwrap` executes the command after bubblewrap's `--`
separator directly, so it should only be used inside an externally isolated
container. Use `--force-codex-sandbox` to require the real sandbox and surface
failures instead.

For Codex `/permissions`, `codex-yolo` defaults to Full Access when the active
Codex requirements allow it. If Full Access is disabled by requirements, it uses
Auto-review (`codex-auto-review`). In containers where the Codex sandbox is
unavailable and codex-yolo has to rely on external isolation, the `auto` default
also uses Auto-review. Override this with `--permissions
full-access`, `--permissions auto-review`, or `--permissions none`. For
standard interactive Auto-review sessions, `codex-yolo` also reconciles the TUI
once at startup so `/permissions` shows `Auto-review (current)`.

## How it works

1. **Launcher** (`codex-yolo`) creates a tmux session and spawns one window per task, each running `codex --yolo` for standard sessions or `codex exec` in worktree mode. If the Codex Linux sandbox is unavailable, launch commands include Codex's no-sandbox bypass flag.
2. **Control pane** (`lib/control-pane.sh`) opens the `control` window, tails the audit log, and handles slash commands such as `/loop` and `/permissions auto-review`.
3. **Approver daemon** (`lib/approver-daemon.sh`) runs in the background, polling every 0.3s. For each pane it:
   - Captures visible content via `tmux capture-pane`
   - Detects seven prompt styles (see below)
   - Sends the confirm key via `tmux send-keys` to choose the first approval option (`Enter`, or `y` for prompts showing `Yes, proceed (y)`)
   - Applies a 2-second per-pane cooldown to prevent double-approvals
4. **Audit log** at `/tmp/codex-yolo-<session>.log` records every approval and control event with timestamps. Each session gets its own log, so concurrent codex-yolo processes don't interfere.

### Worktree pipeline

When `--worktree` is enabled, three additional components run alongside the approver:

1. **Worktree manager** (`lib/worktree-manager.sh`) creates a branch and git worktree per agent in `<repo>-worktrees/<session>/`.
2. **Conflict daemon** (`lib/conflict-daemon.sh`) polls every `--conflict-poll` seconds and runs `git merge-tree --write-tree` across branch pairs. Conflicts are logged to the audit log.
3. **Merge resolver** (`lib/merge-resolver.sh`) waits for `codex exec` agents to finish, auto-commits uncommitted changes, merges branches into the base branch, and starts a Codex resolver task if a merge conflict occurs.

### Detection signals

The approver requires the primary signal plus at least one secondary signal to fire:

| Signal | Type | Patterns |
|---|---|---|
| Question/header | Primary | `Would you like to run`, `Would you like to make`, `Allow Codex to`, `Approve app tool call`, `Do you trust the contents`, `Enable full access` |
| Approval options | Secondary (at least one) | `Yes, just this once`, `Yes, proceed (y)`, `Yes, continue`, `Yes, and don't ask`, `Run the tool and continue`, `Apply full access`, `Yes, and allow this host` |
| Denial/context | Secondary (at least one) | `No, and tell Codex`, `Decline this tool call`, `Go back without`, `Cancel this`, `may have side effects`, `may access external`, `may modify`, `untrusted`, `prompt injection` |

**Prompt types handled:**

| Prompt | Trigger | Action |
|---|---|---|
| Command execution | `Would you like to run the following command?` | `Enter` or `y` → first approval option |
| File edits | `Would you like to make the following edits?` | `Enter` → "Yes, just this once" |
| MCP tool calls | `Approve app tool call?` | `Enter` → "Run the tool and continue" |
| Trust directory | `Do you trust the contents of this directory?` | `Enter` → "Yes, continue" |
| Full access | `Enable full access?` | `Enter` → "Yes, continue anyway" |
| Network/host | `Allow Codex to access <host>` | `Enter` → "Yes, just this once" |
| MCP elicitation | `Yes, provide the requested info` | `Enter` → approve |

## File structure

```
codex-yolo               # Main launcher script
lib/
  common.sh              # Logging, prerequisite checks
  control-pane.sh        # Interactive control window + slash command scheduler
  approver-daemon.sh     # tmux capture-pane monitor + auto-approver
  worktree-manager.sh    # Git worktree lifecycle
  conflict-daemon.sh     # Real-time conflict detection via git merge-tree
  merge-resolver.sh      # Sequential merge + Codex-powered conflict resolution
test_approver.sh         # Test suite
install.sh               # Cross-platform installer
docs/
  worktree-mode-demo.md  # Step-by-step worktree demo
```

## Prerequisites

- **tmux** (tested with 3.4)
- **codex** (OpenAI Codex CLI — installed from the standalone GitHub release or `npm install -g @openai/codex`)
- **git** 2.38+ (required for worktree mode — `git merge-tree --write-tree`)

## Testing

```bash
# Run all tests
bash test_approver.sh

# Verbose output (shows passing tests)
bash test_approver.sh -v

# Filter by pattern
bash test_approver.sh "Command:"
bash test_approver.sh "Trust"
bash test_approver.sh Integration
bash test_approver.sh Concurrent
```

The test suite covers:
- Prompt detection for all six Codex CLI prompt types (command, edit, tool, trust, full access, network)
- MCP elicitation prompt detection
- False positive resistance (code output, partial signals, missing context)
- Cooldown logic, command construction, audit logging
- End-to-end integration tests using real tmux sessions
- Concurrent daemon isolation (no crosstalk between sessions)
- Worktree creation, cleanup, conflict detection, and merge behavior

## Key features

- **Parallel multi-agent execution** — Uniquely enables parallel execution of multiple Codex CLI agents in tmux with non-invasive, terminal-level auto-approval of permissions.
- **Git worktree isolation** — Each agent can work in its own branch and worktree, then merge back into the base branch.
- **Real-time conflict detection** — A background daemon polls `git merge-tree` across all branch pairs and logs conflicts as they emerge.
- **Automated conflict resolution** — On merge conflict, a Codex resolver task is spawned to resolve conflict markers and commit the merge.
- **Convenience-first automation** — Standard sessions use Codex `--yolo`, so this is intended only for isolated environments where broad command execution is acceptable.
- **Comprehensive detection logic** — Handles all six Codex CLI prompt types plus MCP elicitation using a multi-signal approach that minimizes false positives.
- **Reliability and traceability** — Per-pane cooldowns, detailed audit logging, and an extensive test suite emphasize reliability and traceability.
- **No CLI patching or containerization** — Works entirely at the terminal level without modifying the Codex binary or wrapping it in containers.

## Development history

This tool was built by adapting the [claude-yolo](https://github.com/claude-yolo/claude-yolo) approach for OpenAI's Codex CLI. Key design decisions:

1. **TUI overlay detection**: Codex CLI uses a full-screen Ratatui TUI overlay for approval dialogs (not inline text like Claude Code). The `tmux capture-pane` approach still works because tmux captures the rendered terminal content including TUI overlays.

2. **Approval keystroke**: The first option in the selection list is always the approval option and is pre-selected (`❯`). Sending `Enter` confirms it.

3. **Multi-signal detection**: Simple keyword matching produces too many false positives from code output. The two-tier approach (primary question/header signal + secondary approval/denial signal) eliminates these.

4. **Per-pane cooldown**: Without a cooldown, the 0.3s poll interval can send multiple `Enter` keystrokes for the same prompt. A 2-second per-pane cooldown prevents double-approvals.

5. **Automation mode**: Codex CLI has approval policies and independent sandbox modes. Current `codex-yolo` standard sessions pass `--yolo`, which prioritizes automation over sandbox preservation. Use dedicated, isolated environments.
