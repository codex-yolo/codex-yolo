> [!CAUTION]
> **DO NOT USE THIS TOOL ON CORPORATE HARDWARE OR CONNECTED TO A CORPORATE NETWORK.**
>
> This tool auto-approves all Codex CLI permission prompts without human review, including destructive commands. For maximum isolation, run it on a **dedicated bare-metal server** with no personal data, no saved credentials, and no access to sensitive networks. You accept full responsibility for any consequences.

# codex-yolo

Run parallel OpenAI Codex CLI agents in tmux with automatic permission approval. Optionally isolate each agent in its own git worktree with real-time merge conflict detection and automated conflict resolution.

Codex CLI can prompt before commands leave the workspace sandbox or require other elevated permissions. Standard agent windows start in **Ask for approval** mode (`workspace-write`, `on-request`, user review); the tmux approver daemon handles those prompts at the terminal level. Command network access is enabled inside that sandbox by default so tools such as `git`, `gh`, package managers, and `curl` can reach public websites.

On launch, codex-yolo also reconciles these user-level defaults in
`~/.codex/config.toml` (existing unrelated settings are preserved):

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[features]
shell_tool = true
code_mode_host = true
```

`unified_exec` is intentionally left unset so the Codex default or an
organization's managed requirement can select the execution backend.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
  - [Model selection](#model-selection)
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

On Linux and WSL2, the installer installs the distribution `bubblewrap` package
when `bwrap` is missing from `PATH`, as recommended by Codex's official sandbox
prerequisites. The bundled helper remains Codex's fallback, but it requires
unprivileged user namespaces. If a namespace or AppArmor warning remains, follow
the [official troubleshooting steps](https://learn.chatgpt.com/docs/sandboxing?surface=app#app-prerequisites),
including the Ubuntu 24.04 AppArmor profile setup when applicable.

**One-liner** (macOS, Linux, WSL, Termux):

```bash
command -v curl >/dev/null || { s=; [ "$(id -u)" != 0 ] && s=sudo; command -v apt-get >/dev/null && { $s apt-get update && $s apt-get install -y curl; } || command -v dnf >/dev/null && $s dnf install -y curl || command -v yum >/dev/null && $s yum install -y curl || command -v apk >/dev/null && $s apk add curl || command -v pacman >/dev/null && $s pacman -S --noconfirm curl || command -v pkg >/dev/null && pkg install -y curl || command -v brew >/dev/null && brew install curl; }; curl -fsSL https://raw.githubusercontent.com/codex-yolo/codex-yolo/refs/heads/main/install.sh | bash && export PATH="${CODEX_YOLO_BIN_DIR:-$HOME/.local/bin}:${CODEX_YOLO_HOME:-$HOME/.codex-yolo}/bin:$PATH"
```

This clones to `~/.codex-yolo` and symlinks the binary into `~/.local/bin`. If `~/.local/bin` is not writable, the installer falls back to `~/.codex-yolo/bin`; you can also set `CODEX_YOLO_BIN_DIR` to choose a writable bin directory. It also installs `git`, `tmux`, `curl`, and `codex` if they are missing. Codex CLI and its version-matched `codex-code-mode-host` companion are installed from the latest stable standalone GitHub release first, with `@openai/codex@latest` from npm as a fallback. Re-running the one-liner upgrades installer-managed Codex binaries to the latest stable release and repairs older installs that are missing the Code Mode host; npm-, brew-, and system-managed Codex installs are left unchanged. Set `CODEX_YOLO_SKIP_CODEX_UPGRADE=1` to leave an installer-managed binary unchanged, or set `CODEX_YOLO_CODEX_VERSION=rust-v0.X.Y` to pin a specific release. Override the install location with `CODEX_YOLO_HOME`:

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
codex-yolo -m gpt-5.6-sol "refactor the API layer"

# Dial the reasoning effort down (default: ultra)
codex-yolo -e medium "quick cleanup pass"

# Point agents at a different project
codex-yolo -d /path/to/project "run the test suite and fix failures"
```

Once launched, you're inside a tmux session with one window per agent. The last window (`control`) tails the audit log in real time and accepts slash commands.

### Model selection

Without `-m/--model`, codex-yolo picks the most capable model your account can actually use: it probes `gpt-6-astra`, then `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and finally `gpt-5.5` with a tiny one-shot `codex exec` request. It launches every agent (and the worktree merge resolver) with the first model that answers. The winner and candidate order are cached in `~/.codex-yolo/model-cache` for 24 hours, so only the first launch of the day pays the probe; changing `CODEX_YOLO_MODEL_CANDIDATES`, including its order, invalidates the cache immediately. If no candidate responds (offline, not logged in), agents launch with Codex's configured model and effort. Probing beats reading the local model catalog — the catalog lists what exists, not what your account/plan (or your installed CLI version) is currently allowed to use. Agents run at `model_reasoning_effort = "ultra"` by default — override with `-e/--effort`, or `-e none` to leave whatever your `~/.codex/config.toml` sets. Luna supports through `max` and GPT-5.5 through `xhigh`, so codex-yolo uses those levels automatically when either is selected with the default effort; an explicit incompatible effort fails with guidance instead of being silently changed. Ultra also requires an eligible account. Because the quick probe deliberately runs at low effort and tests model access only, use `-e max` (or another supported level) if Codex reports that Ultra is unavailable for your account. Tune with `CODEX_YOLO_MODEL_CACHE_TTL` (seconds, default 86400) and `CODEX_YOLO_MODEL_PROBE_TIMEOUT` (seconds per probe, default 60).

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

### One-shot control commands from the CLI

Pass `-c "/..."` to run a single slash command in the `control` window right after launch — same effect as typing it at the `codex-yolo>` prompt. To compose multiple commands, wrap them in `/queue [...]` rather than repeating `-c`.

```bash
codex-yolo -c "/loop 10m /plan Draft the next implementation plan"
codex-yolo -c '/queue ["/plan first", "/loop 1h /plan continue"]'
codex-yolo --resume -c "/loops"
```

Multi-line strings are sent as a paste, so multi-line `/plan` and `/queue` work:

```bash
codex-yolo -c "$(printf '/plan line one\nline two\nline three')"
```

When the launch also kicks off Codex Auto-review reconciliation (i.e. interactive mode with no task and the `codex-auto-review` permissions profile), the injection waits for that reconciliation to finish before sending keys, so the first `/plan` or `/loop` lands on the Codex chat prompt rather than the welcome / permissions screen.

## Options

The default permissions mode is **Ask for approval** (`workspace-write`, `on-request`, user review). Command network access is enabled by default; use `--no-network` when a run should remain offline. Existing `full-access`, `auto-review`, and `none` permission overrides remain available.

```
-s, --session NAME    Custom tmux session name (default: codex-yolo-<timestamp>)
-d, --dir PATH        Working directory for agents (default: current directory)
-m, --model MODEL     Model to use (e.g., gpt-6-astra, gpt-5.6-sol).
                      Default: best available model, probed automatically
                      (Astra → Sol → Terra → Luna → GPT-5.5), cached for 24h
-e, --effort LEVEL    Reasoning effort for each agent
                      (minimal|low|medium|high|xhigh|max|ultra, or 'none' to
                      leave Codex's configured default). Default: ultra;
                      compatibility fallbacks: Luna max, GPT-5.5 xhigh
-p, --poll SECONDS    Approver poll interval (default: 0.3)
-f, --file FILE       Read a multiline prompt from a text file
-c, --command STRING  Slash command to run in the control pane after launch
                      (e.g. "/loop 10m /plan ...", "/queue [...]", "/help").
                      Must start with '/'. Multi-line strings are sent as a paste.
                      Works with --resume to inject into an existing session.
-r, --resume          Re-attach to an existing yolo session
    --permissions PROFILE Set Codex permissions mode (default: ask-for-approval)
    --network             Enable command network access (default)
    --no-network          Disable command network access
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

By default, `codex-yolo` probes `codex sandbox linux true` once. If that probe
fails inside a detected container (including `bwrap: No permissions to create
new namespace`), `codex-yolo` creates a temporary fake `bwrap` earlier in
`PATH` and launches agents without Codex sandboxing. The shim is required even
when the CLI bypass flag is present because a managed permission policy may
reject the flag and force commands back through `bwrap`. The fake `bwrap`
executes the command after bubblewrap's `--` separator directly, so it should
only be used inside an externally isolated container. Use
`--force-codex-sandbox` to require the real sandbox and surface failures instead.

For Codex `/permissions`, `codex-yolo` defaults to **Ask for approval**. The
launcher passes `sandbox_workspace_write.network_access=true` directly to every
sandboxed agent rather than changing the network behavior of ordinary Codex
sessions outside `codex-yolo`. Set `CODEX_YOLO_NETWORK_ACCESS=0` or pass
`--no-network` to opt out. Explicit permission overrides remain available with
`--permissions full-access`, `--permissions auto-review`, or
`--permissions none`. For explicit interactive Auto-review sessions,
`codex-yolo` also reconciles the TUI once at startup so `/permissions` shows
`Auto-review (current)`.

`codex-yolo` also configures a Codex `Stop` lifecycle hook in `~/.codex/config.toml`
that rings the terminal bell when an agent finishes its turn, so you get an
audible cue once the approver has cleared the prompts and control returns to you.
On Codex `>=0.136.0`, a newly-added hook is gated behind a startup "Hooks need
review" trust modal; `codex-yolo` pre-trusts its own bell hook deterministically
(by the stable hash Codex derives from the hook definition) and the control pane
also clears the modal at startup if it appears, so the bell runs without manual
review. Any pre-existing `hooks.Stop` configuration is left untouched. Opt out of
the bell entirely with `CODEX_YOLO_NO_BELL=1`.

A second lifecycle hook — `hooks.PermissionRequest`, installed and pre-trusted
the same way — records every Codex approval dialog as a per-pane marker file in
`<audit-log>.waiting/`, so the approver daemon can recognize dialogs rendered
**off-screen** (see "Hidden-prompt rails" below). The hook command is static:
the session-specific marker directory comes from the `CODEX_YOLO_WAITING_DIR`
environment variable the launcher sets on each agent pane, so outside a
codex-yolo session the hook is a no-op and your other Codex sessions are
unaffected. Any pre-existing `hooks.PermissionRequest` configuration is left
untouched. Opt out with `CODEX_YOLO_NO_PERMISSION_HOOK=1`.

## How it works

1. **Launcher** (`codex-yolo`) creates a tmux session and spawns one window per task. Standard sessions default to `workspace-write` with `on-request` approvals and command network access enabled; `--no-network` opts out. Full Access remains explicit. Worktree mode uses `codex exec`. If the Codex Linux sandbox is unavailable, launch commands include Codex's no-sandbox bypass flag.
2. **Control pane** (`lib/control-pane.sh`) opens the `control` window, tails the audit log, and handles slash commands such as `/loop` and `/permissions auto-review`.
3. **Approver daemon** (`lib/approver-daemon.sh`) runs in the background, polling every 0.3s. For each pane it:
   - Captures visible content via `tmux capture-pane`
   - Detects eight prompt styles (see below), including Codex's `Replace goal?` confirmation
   - Sends the confirm key via `tmux send-keys` to choose the approval option: `y` when a `Yes, proceed (y)` shortcut is advertised (lands on Yes regardless of the selection), `Enter` when the `›` marker already sits on the approval option, or the approval option's number when the selection was moved to another option
   - Auto-answers question dialogs (plan-mode `Question N/M` menus and the like) that carry a capital-R `(Recommended)` option — `Enter` when the marker is already on it, the option's number otherwise. Questions without a recommended option are left for the user, as are multi-select checkbox questions
   - Catches dialogs rendered **off-screen** — e.g. a diff taller than the pane pushes the option list below the viewport, where `capture-pane` can never see it. The pre-trusted `PermissionRequest` hook leaves a marker for the pane; when a fresh marker exists but no dialog is visible and the pane is frozen (a working agent keeps repainting, a pane stuck on a dialog stops), the daemon first "nudges" the window (resizes it one row down and back, forcing the TUI to re-render — a revealed dialog is then approved by the normal detectors with all their safeguards) and, if it stays invisible, sends a blind `Enter`: the dialog keeps keyboard focus with the approval option preselected even when it isn't drawn
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
| Denial/context | Secondary (at least one) | `No, and tell Codex`, `Decline this tool call`, `Go back without`, `Cancel this`, `may have side effects`, `may access external`, `may modify`, `untrusted`, `prompt injection`, `requires approval`, `requires confirmation` |

Signals are normally matched against the last 25 pane lines, but a tall dialog
(a multi-line command echoed under the header) can push the question header far
above that window. The header is therefore also matched against the whole
visible capture — line-anchored, so quoted headers in code output don't count —
and only accepted while an approval option still sits near the pane bottom,
where a live dialog always renders its option list. Secondary signals are then
scoped to the header-to-bottom region.

**Safety rails** — a static-pane send cap stops keying a pane after 5 sends
with byte-identical content (a "prompt" that doesn't react to keys is a false
positive; the audit log records `suppressed-static` once), configurable via
`CODEX_YOLO_SEND_STREAK_CAP`. A per-session `flock` on `<audit-log>.lock`
refuses duplicate daemons for the same session, so keys are never double-sent
during redeploys.

**Hidden-prompt rails** — the off-screen path never types blindly unless the
pane has been byte-identical across consecutive polls (frozen), is not in
copy-mode (the user may be scrolling), got `CODEX_YOLO_HIDDEN_NUDGE_MAX`
repaint nudges first (default 2), and shows neither a `›` composer/selection
marker nor box chrome (`╰`) in its bottom lines — so a stale marker can never
submit text someone is composing. Blind `Enter` is reserved for plain
command/edit approvals (identified by the marker payload's `tool_name`); plan
and question dialogs are left for the user. A marker on a pane whose content
*changed* is consumed without any key (the dialog was already answered — by
the visual path racing the hook, or by you), markers expire after
`CODEX_YOLO_NOTIFY_TTL` seconds (default 600), and blind answers are only
attempted within `CODEX_YOLO_HIDDEN_BLIND_WINDOW` seconds of the dialog
appearing (default 45). Nudges are logged as `HIDDEN-PROMPT nudge` in the
audit log, blind approvals as `hidden-blind+Enter` — both visible live in the
control window.

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
| Replace goal | `Replace goal?` (from `/goal` via queue/loop) | `Enter` → "Replace current goal" |
| Recommended question | numbered menu with a `(Recommended)` option and an active `›` marker | `Enter` on the recommended option, or its number to jump there |

The `Replace goal?` prompt has its own three-signal detector (it requires
`Replace goal?` plus `Replace current goal` plus `Keep the current goal` or
`New objective:`) so it only fires on the genuine goal-replacement dialog and
never on incidental "goal" text in agent output.

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

  * `bubblewrap` on Linux and WSL2 (installed automatically when missing; see the [official Codex sandbox prerequisites](https://learn.chatgpt.com/docs/sandboxing?surface=app#app-prerequisites))

- **tmux** (tested with 3.4)
- **codex** (OpenAI Codex CLI — the installer uses the latest stable standalone GitHub release or `npm install -g @openai/codex@latest`)
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
- Prompt detection for all six Codex CLI permission prompt types (command, edit, tool, trust, full access, network), including tall dialogs whose header sits above the tail window
- MCP elicitation, `Replace goal?`, and `(Recommended)` question prompt detection
- Approval-key targeting (Enter vs the approval option's number vs the `y` shortcut)
- False positive resistance (code output, partial signals, missing context, displayed-not-live menus)
- Managed-requirements-compatible permission construction, including the safe default, explicit Full Access, and no-sandbox behavior
- Cooldown logic, the static-pane send cap, command construction (model/effort/marker-dir plumbing), audit logging
- Best-model auto-selection (probe order, caching, TTL and candidate-list invalidation)
- Turn-complete bell and PermissionRequest marker hook configuration and pre-trust (and the startup hook-review modal handling)
- Hidden-prompt marker handling (freshness, blind-answer gating, composer/copy-mode/stale-marker safety)
- End-to-end integration tests using real tmux sessions, including the nudge → blind-Enter path and the duplicate-daemon lock
- Concurrent daemon isolation (no crosstalk between sessions)
- Worktree creation, cleanup, conflict detection, and merge behavior

## Key features

- **Parallel multi-agent execution** — Uniquely enables parallel execution of multiple Codex CLI agents in tmux with non-invasive, terminal-level auto-approval of permissions.
- **Git worktree isolation** — Each agent can work in its own branch and worktree, then merge back into the base branch.
- **Real-time conflict detection** — A background daemon polls `git merge-tree` across all branch pairs and logs conflicts as they emerge.
- **Automated conflict resolution** — On merge conflict, a Codex resolver task is spawned to resolve conflict markers and commit the merge.
- **Requirements-compatible defaults** — Standard sessions omit `--yolo`, request `workspace-write` with `on-request` approvals, and explicitly enable sandboxed command networking. Explicit Full Access remains available for isolated environments where broad command execution is acceptable.
- **Comprehensive detection logic** — Handles all six Codex CLI permission prompt types plus MCP elicitation, the `Replace goal?` confirmation, and `(Recommended)` question menus, using a multi-signal approach that minimizes false positives; the approval key always lands on the approval option even when the selection was moved.
- **Best-model auto-selection** — Without `-m/--model`, probes for the most capable model your account can use (`gpt-6-astra` → `gpt-5.6-sol` → `gpt-5.6-terra` → `gpt-5.6-luna` → `gpt-5.5`), caches the winner for 24h, and runs Ultra-capable models at `ultra` reasoning effort by default (`-e/--effort` to override; Luna falls back to `max` and GPT-5.5 to `xhigh`).
- **Off-screen dialog handling** — A pre-trusted Codex `PermissionRequest` hook records approval dialogs as per-pane markers, so dialogs rendered below the viewport are revealed by repaint nudges or answered blind under strict safety gates.
- **Turn-complete bell** — Configures (and pre-trusts) a Codex `Stop` hook so the terminal bell rings when an agent finishes its turn; opt out with `CODEX_YOLO_NO_BELL=1`.
- **Reliability and traceability** — Per-pane cooldowns, a static-pane send cap, a duplicate-daemon lock, detailed audit logging, and an extensive test suite emphasize reliability and traceability.
- **No CLI patching or containerization** — Works entirely at the terminal level without modifying the Codex binary or wrapping it in containers.

## Development history

This tool was built by adapting the [claude-yolo](https://github.com/claude-yolo/claude-yolo) approach for OpenAI's Codex CLI. Key design decisions:

1. **TUI overlay detection**: Codex CLI uses a full-screen Ratatui TUI overlay for approval dialogs (not inline text like Claude Code). The `tmux capture-pane` approach still works because tmux captures the rendered terminal content including TUI overlays.

2. **Approval keystroke**: The first option in the selection list is always the approval option and is pre-selected (`❯`). Sending `Enter` confirms it.

3. **Multi-signal detection**: Simple keyword matching produces too many false positives from code output. The two-tier approach (primary question/header signal + secondary approval/denial signal) eliminates these.

4. **Per-pane cooldown**: Without a cooldown, the 0.3s poll interval can send multiple `Enter` keystrokes for the same prompt. A 2-second per-pane cooldown prevents double-approvals.

5. **Automation mode**: Codex CLI has approval policies and independent sandbox modes. Current `codex-yolo` standard sessions pass `--yolo`, which prioritizes automation over sandbox preservation. Use dedicated, isolated environments.
