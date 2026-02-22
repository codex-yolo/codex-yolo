> [!CAUTION]
> **DO NOT USE THIS TOOL ON CORPORATE HARDWARE OR CONNECTED TO A CORPORATE NETWORK.**
>
> This tool auto-approves all Codex CLI permission prompts without human review, including destructive commands. For maximum isolation, run it on a **dedicated bare-metal server** with no personal data, no saved credentials, and no access to sensitive networks. You accept full responsibility for any consequences.

# codex-yolo

Run parallel OpenAI Codex CLI agents in tmux with automatic permission approval.

When approval policy is set to `on-request` or `untrusted`, Codex CLI prompts the user before running commands, applying edits, or accessing the network. This tool auto-approves those prompts at the terminal level using `tmux capture-pane` + `send-keys`, while preserving sandbox protection.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Navigation](#navigation)
- [Options](#options)
- [How it works](#how-it-works)
  - [Detection signals](#detection-signals)
- [File structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Testing](#testing)
- [Key features](#key-features)
- [Development history](#development-history)

## Installation

**One-liner** (macOS, Linux, WSL):

```bash
curl -fsSL https://raw.githubusercontent.com/codex-yolo/codex-yolo/refs/heads/main/install.sh | bash
```

This clones to `~/.codex-yolo` and symlinks the binary into `~/.local/bin`. It also installs `tmux` and `codex` (Codex CLI via npm) if they are missing. Override the install location with `CODEX_YOLO_HOME`:

```bash
CODEX_YOLO_HOME=~/my/path curl -fsSL https://raw.githubusercontent.com/codex-yolo/codex-yolo/refs/heads/main/install.sh | bash
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

Once launched, you're inside a tmux session with one window per agent. The last window (`control`) tails the audit log in real time.

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

## Options

```
-s, --session NAME    Custom tmux session name (default: codex-yolo-<timestamp>)
-d, --dir PATH        Working directory for agents (default: current directory)
-m, --model MODEL     Model to use (e.g., o4-mini, o3, gpt-4.1)
-p, --poll SECONDS    Approver poll interval (default: 0.3)
-f, --file FILE       Read a multiline prompt from a text file
-r, --resume          Re-attach to an existing yolo session
-h, --help            Show help
```

## How it works

1. **Launcher** (`codex-yolo`) creates a tmux session and spawns one window per task, each running `codex`.
2. **Approver daemon** (`lib/approver-daemon.sh`) runs in the background, polling every 0.3s. For each pane it:
   - Captures visible content via `tmux capture-pane`
   - Detects six prompt styles (see below)
   - Sends `Enter` via `tmux send-keys` to confirm the pre-selected first option (always the approval option)
   - Applies a 2-second per-pane cooldown to prevent double-approvals
3. **Audit log** at `/tmp/codex-yolo-<session>.log` records every approval with timestamp, pane ID, and matched pattern. Each session gets its own log, so concurrent codex-yolo processes don't interfere.

### Detection signals

The approver requires the primary signal plus at least one secondary signal to fire:

| Signal | Type | Patterns |
|---|---|---|
| Question/header | Primary | `Would you like to run`, `Would you like to make`, `Allow Codex to`, `Approve app tool call`, `Do you trust the contents`, `Enable full access` |
| Approval options | Secondary (at least one) | `Yes, just this once`, `Yes, continue`, `Yes, and don't ask`, `Run the tool and continue`, `Apply full access`, `Yes, and allow this host` |
| Denial/context | Secondary (at least one) | `No, and tell Codex`, `Decline this tool call`, `Go back without`, `Cancel this`, `may have side effects`, `may access external`, `may modify`, `untrusted`, `prompt injection` |

**Prompt types handled:**

| Prompt | Trigger | Action |
|---|---|---|
| Command execution | `Would you like to run the following command?` | `Enter` → "Yes, just this once" |
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
  approver-daemon.sh     # tmux capture-pane monitor + auto-approver
test_approver.sh         # Test suite (109 tests)
install.sh               # Cross-platform installer
```

## Prerequisites

- **tmux** (tested with 3.4)
- **codex** (OpenAI Codex CLI — `npm install -g @openai/codex`)

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

## Key features

- **Parallel multi-agent execution** — Uniquely enables parallel execution of multiple Codex CLI agents in tmux with non-invasive, terminal-level auto-approval of permissions.
- **Sandbox-preserving** — Unlike `--dangerously-bypass-approvals-and-sandbox` (aka `--yolo`), this approach auto-approves prompts while keeping Codex's OS-level sandbox (Landlock/seccomp on Linux, Seatbelt on macOS) active.
- **Comprehensive detection logic** — Handles all six Codex CLI prompt types plus MCP elicitation using a multi-signal approach that minimizes false positives.
- **Reliability and traceability** — Per-pane cooldowns, detailed audit logging, and an extensive test suite emphasize reliability and traceability.
- **No CLI patching or containerization** — Works entirely at the terminal level without modifying the Codex binary or wrapping it in containers.

## Development history

This tool was built by adapting the [claude-yolo](https://github.com/claude-yolo/claude-yolo) approach for OpenAI's Codex CLI. Key design decisions:

1. **TUI overlay detection**: Codex CLI uses a full-screen Ratatui TUI overlay for approval dialogs (not inline text like Claude Code). The `tmux capture-pane` approach still works because tmux captures the rendered terminal content including TUI overlays.

2. **Approval keystroke**: The first option in the selection list is always the approval option and is pre-selected (`❯`). Sending `Enter` confirms it.

3. **Multi-signal detection**: Simple keyword matching produces too many false positives from code output. The two-tier approach (primary question/header signal + secondary approval/denial signal) eliminates these.

4. **Per-pane cooldown**: Without a cooldown, the 0.3s poll interval can send multiple `Enter` keystrokes for the same prompt. A 2-second per-pane cooldown prevents double-approvals.

5. **Sandbox preservation**: Codex CLI has three approval policies (`untrusted`, `on-request`, `never`) and independent sandbox modes. The `--yolo` flag sets both to maximum permissiveness. This tool only auto-approves prompts, leaving the sandbox intact — you get the convenience of auto-approval with the safety of OS-level sandboxing.
