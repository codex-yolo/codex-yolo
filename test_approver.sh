#!/usr/bin/env bash
# test_approver.sh — Tests for codex-yolo, focused on Codex CLI permission prompt detection
#
# Usage: bash test_approver.sh
#        bash test_approver.sh -v          # verbose — show pass details
#        bash test_approver.sh <pattern>   # run only tests matching pattern

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── test harness ─────────────────────────────────────────────────────────────

PASS=0 FAIL=0 SKIP=0 TOTAL=0
VERBOSE="${VERBOSE:-0}"
FILTER="${1:-}"
[[ "$FILTER" == "-v" ]] && { VERBOSE=1; FILTER="${2:-}"; }

_red=$'\033[0;31m' _green=$'\033[0;32m' _yellow=$'\033[0;33m' _reset=$'\033[0m'

assert_ok() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
    fi
}

assert_fail() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc  (expected failure, got success)"
    else
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
        echo "        missing '$needle' in output"
    fi
}

section() { echo "${_yellow}▸ $1${_reset}"; }

# ── source the units under test ──────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"

# Source detect_prompt, detect_elicitation and friends without running the daemon's main_loop.
eval "$(sed -n '/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p' "$SCRIPT_DIR/lib/approver-daemon.sh")"

# Source build_agent_cmd from the launcher
eval "$(sed -n '/^build_agent_cmd()/,/^}/p' "$SCRIPT_DIR/codex-yolo")"

# ── helper to build realistic pane captures ──────────────────────────────────

# Simulates Codex CLI command execution approval prompt.
# $1 = command being requested
make_command_prompt() {
    local command_line="$1"
    cat <<EOF
  Codex is working on your task...
  Analyzing the codebase structure.

  Would you like to run the following command?

    $command_line

  ❯ Yes, just this once
    Yes, and don't ask again for commands that start with \`${command_line%% *}\`
    No, and tell Codex what to do differently
EOF
}

# Simulates Codex CLI file edit approval prompt.
# $1 = file being edited
make_edit_prompt() {
    local file="$1"
    cat <<EOF
  Codex is working on your task...

  Would you like to make the following edits?

    $file
    + added line
    - removed line

  ❯ Yes, just this once
    Yes, and don't ask again for these files
    No, and tell Codex what to do differently
EOF
}

# Simulates Codex CLI tool call approval prompt.
# $1 = tool description
# $2 = side-effect warning (optional)
make_tool_prompt() {
    local tool_desc="$1" warning="${2:-may have side effects}"
    cat <<EOF
  Approve app tool call?

  $tool_desc
  $warning

  ❯ Run the tool and continue.
    Approve this Session
    Decline this tool call and continue.
    Cancel this tool call
EOF
}

# Simulates Codex CLI trust directory prompt.
make_trust_prompt() {
    cat <<EOF
  Do you trust the contents of this directory? Working with untrusted
  contents comes with higher risk of prompt injection.

  /home/user/git/my-project

  ❯ Yes, continue
EOF
}

# Simulates Codex CLI full access prompt.
make_full_access_prompt() {
    cat <<EOF
  Enable full access?

  When Codex runs with full access, it can edit any file on your computer
  and run commands with network, without your approval.
  Exercise caution when enabling full access.

  ❯ Yes, continue anyway
    Yes, and don't ask again
    Go back without enabling full access
EOF
}

# Simulates Codex CLI network/host access prompt.
# $1 = command or host
make_network_prompt() {
    local host="$1"
    cat <<EOF
  Allow Codex to access $host

  Would you like to run the following command?

    curl $host/api/data

  ❯ Yes, just this once
    Yes, and allow this host for this session
    No, and tell Codex what to do differently
EOF
}

###############################################################################
#              COMMAND EXECUTION APPROVAL PROMPTS                              #
###############################################################################

section "detect_prompt — Command execution approval"

assert_ok "Command: ls" \
    detect_prompt "$(make_command_prompt "ls -la /tmp")"

assert_ok "Command: git status" \
    detect_prompt "$(make_command_prompt "git status")"

assert_ok "Command: pytest" \
    detect_prompt "$(make_command_prompt "python3 -m pytest tests/ -v")"

assert_ok "Command: npm install" \
    detect_prompt "$(make_command_prompt "npm install --save-dev jest")"

assert_ok "Command: rm -rf" \
    detect_prompt "$(make_command_prompt "rm -rf /tmp/test-dir")"

assert_ok "Command: piped command" \
    detect_prompt "$(make_command_prompt "cat /etc/hosts | grep localhost")"

assert_ok "Command: chained commands" \
    detect_prompt "$(make_command_prompt "cd /project && make build && make test")"

# Exact prompt text from Codex CLI binary
assert_ok "Command: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Would you like to run the following command?

    ls /home/user/git/codex-yolo/

  ❯ Yes, just this once
    Yes, and don't ask again for commands that start with `ls`
    No, and tell Codex what to do differently

  ↑/↓ to navigate · Enter to confirm · Esc to cancel
PANE
)"

_out="$(detect_prompt "$(make_command_prompt "ls")")"
assert_contains "Command: pattern includes +approval" "$_out" "+approval"
assert_contains "Command: pattern includes +context" "$_out" "+context"

###############################################################################
#                   FILE EDIT APPROVAL PROMPTS                                 #
###############################################################################

section "detect_prompt — File edit approval"

assert_ok "Edit: single file" \
    detect_prompt "$(make_edit_prompt "src/main.py")"

assert_ok "Edit: config file" \
    detect_prompt "$(make_edit_prompt "package.json")"

assert_ok "Edit: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Would you like to make the following edits?

    src/auth/login.ts
    + import { validateToken } from './utils';
    - import { checkToken } from './legacy';

  ❯ Yes, just this once
    Yes, and don't ask again for these files
    No, and tell Codex what to do differently

  ↑/↓ to navigate · Enter to confirm · Esc to cancel
PANE
)"

_out="$(detect_prompt "$(make_edit_prompt "src/main.py")")"
assert_contains "Edit: pattern includes question" "$_out" "question"
assert_contains "Edit: pattern includes +approval" "$_out" "+approval"

###############################################################################
#                    MCP TOOL CALL APPROVAL PROMPTS                            #
###############################################################################

section "detect_prompt — MCP tool call approval"

assert_ok "Tool: basic approval" \
    detect_prompt "$(make_tool_prompt "database_query" "may have side effects")"

assert_ok "Tool: external access" \
    detect_prompt "$(make_tool_prompt "send_email" "may access external systems")"

assert_ok "Tool: modify data" \
    detect_prompt "$(make_tool_prompt "delete_records" "may modify or delete data")"

assert_ok "Tool: modify and access external" \
    detect_prompt "$(make_tool_prompt "sync_data" "may modify data and access external systems")"

assert_ok "Tool: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Approve app tool call?

  Tool: github_create_issue
  Arguments: {"title": "Fix auth bug", "body": "..."}

  may access external systems

  ❯ Run the tool and continue.
    Run the tool and remember this choice for this session.
    Decline this tool call and continue.
    Cancel this tool call

  ↑/↓ to navigate · Enter to confirm · Esc to cancel
PANE
)"

_out="$(detect_prompt "$(make_tool_prompt "test_tool" "may have side effects")")"
assert_contains "Tool: pattern includes question" "$_out" "question"

###############################################################################
#                   TRUST DIRECTORY PROMPTS                                    #
###############################################################################

section "detect_prompt — Trust directory"

assert_ok "Trust: standard prompt" \
    detect_prompt "$(make_trust_prompt)"

assert_ok "Trust: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Do you trust the contents of this directory? Working with untrusted contents
  comes with higher risk of prompt injection.

  /home/user/git/snake-game

  ❯ Yes, continue
PANE
)"

assert_ok "Trust: minimal" \
    detect_prompt "$(cat <<'PANE'
  Do you trust the contents of this directory?
  ❯ Yes, continue
PANE
)"

_out="$(detect_prompt "$(make_trust_prompt)")"
assert_contains "Trust: pattern includes question" "$_out" "question"
assert_contains "Trust: pattern includes +approval" "$_out" "+approval"

###############################################################################
#                   FULL ACCESS PROMPTS                                        #
###############################################################################

section "detect_prompt — Full access"

assert_ok "Full access: standard prompt" \
    detect_prompt "$(make_full_access_prompt)"

assert_ok "Full access: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Enable full access?

  When Codex runs with full access, it can edit any file on your computer
  and run commands with network, without your approval. Exercise caution
  when enabling full access. This significantly increases the risk of
  data loss, leaks, or unexpected behavior.

  ❯ Yes, continue anyway
    Yes, and don't ask again
    Go back without enabling full access
PANE
)"

assert_ok "Full access: apply variant" \
    detect_prompt "$(cat <<'PANE'
  Enable full access?
  ❯ Apply full access for this session
    Enable full access and remember this choice
    Go back without enabling full access
PANE
)"

_out="$(detect_prompt "$(make_full_access_prompt)")"
assert_contains "Full access: pattern includes question" "$_out" "question"
assert_contains "Full access: pattern includes +approval" "$_out" "+approval"
assert_contains "Full access: pattern includes +context" "$_out" "+context"

###############################################################################
#                   NETWORK/HOST ACCESS PROMPTS                                #
###############################################################################

section "detect_prompt — Network/host access"

assert_ok "Network: simple host" \
    detect_prompt "$(make_network_prompt "https://api.example.com")"

assert_ok "Network: localhost" \
    detect_prompt "$(make_network_prompt "http://localhost:3000")"

assert_ok "Network: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

  Allow Codex to access api.github.com

  Would you like to run the following command?

    curl -H "Authorization: Bearer ..." https://api.github.com/repos

  ❯ Yes, just this once
    Yes, and allow this host for this session
    No, and tell Codex what to do differently

  ↑/↓ to navigate · Enter to confirm · Esc to cancel
PANE
)"

_out="$(detect_prompt "$(make_network_prompt "https://example.com")")"
assert_contains "Network: pattern includes +approval" "$_out" "+approval"

###############################################################################
#                   MCP ELICITATION PROMPTS                                    #
###############################################################################

section "detect_elicitation — MCP elicitation (info request)"

assert_ok "Elicitation: standard prompt" \
    detect_elicitation "$(cat <<'PANE'
  The tool is requesting additional information.

  ❯ Yes, provide the requested info
    No, but continue without it
    Cancel this request
PANE
)"

assert_ok "Elicitation: minimal" \
    detect_elicitation "$(cat <<'PANE'
  ❯ Yes, provide the requested info
    Cancel this request
PANE
)"

assert_fail "Elicitation: no matching text" \
    detect_elicitation "$(cat <<'PANE'
  Working on the task...
  Reading files and analyzing code.
PANE
)"

###############################################################################
#                   FALSE POSITIVE RESISTANCE                                  #
###############################################################################

section "detect_prompt — False positive resistance"

# Normal agent output
assert_fail "FP: normal agent work output" \
    detect_prompt "$(cat <<'PANE'
  I'll help you fix the authentication bug.
  Let me read the relevant files first.

  Reading src/auth/login.ts...
  The issue is on line 42 where the token validation
  skips the expiry check.
PANE
)"

# Empty content
assert_fail "FP: empty string" \
    detect_prompt ""

# Just whitespace
assert_fail "FP: whitespace only" \
    detect_prompt "$(printf '   \n  \n   ')"

# Code output that mentions prompts
assert_fail "FP: code mentioning Yes/No" \
    detect_prompt "$(cat <<'PANE'
  options = {
    "Yes, just this once": handle_yes,
    "No, cancel": handle_no,
  }
  print("Processing options...")
PANE
)"

# Question without approval options
assert_fail "FP: question without approval options" \
    detect_prompt "$(cat <<'PANE'
  Would you like to run the following command?
  echo "hello world"
  Processing...
PANE
)"

# Approval options without question
assert_fail "FP: approval option alone (no question or context)" \
    detect_prompt "$(cat <<'PANE'
  Some random output here.
  Yes, just this once
  More output below.
PANE
)"

# Code output referencing Codex
assert_fail "FP: code referencing Codex" \
    detect_prompt "$(cat <<'PANE'
  const message = "Allow Codex to process the request";
  console.log(message);
  // This is not an actual prompt
PANE
)"

# Prompt-like text more than 25 lines from bottom
assert_fail "FP: prompt beyond 25-line detection window" \
    detect_prompt "$(cat <<'PANE'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
line5
line6
line7
line8
line9
line10
line11
line12
line13
line14
line15
line16
line17
line18
line19
line20
line21
line22
line23
line24
line25
line26
line27
line28
Agent is now working on a different task...
PANE
)"

# Output with "Would you like" but not a Codex prompt
assert_fail "FP: conversational Would you like" \
    detect_prompt "$(cat <<'PANE'
  I analyzed the code. Would you like me to
  explain the architecture in more detail?
  Let me know and I'll continue.
PANE
)"

# rm command in normal output (not a prompt)
assert_fail "FP: rm command in normal output" \
    detect_prompt "$(cat <<'PANE'
  Removing temporary files...
  $ rm -rf /tmp/build
  Done. Build artifacts cleaned up.
PANE
)"

# Known limitation: code discussing Codex prompts triggers detection
assert_ok "Known limitation: code discussing prompts triggers detection" \
    detect_prompt "$(cat <<'PANE'
  // Testing the approval dialog
  assert text.includes("Would you like to run the following command?");
  assert text.includes("Yes, just this once");
  assert text.includes("No, and tell Codex what to do differently");
  PASSED
PANE
)"

###############################################################################
#                   PATTERN OUTPUT VALUES                                      #
###############################################################################

section "detect_prompt — Pattern output correctness"

# Command prompt: has question + approval + context
_out="$(detect_prompt "$(make_command_prompt "ls")")"
assert_eq "Pattern: command → question+approval+context" \
    "question+approval+context" "$_out"

# Edit prompt: has question + approval + context
_out="$(detect_prompt "$(make_edit_prompt "file.py")")"
assert_eq "Pattern: edit → question+approval+context" \
    "question+approval+context" "$_out"

# Tool prompt: has question + approval (Run the tool) + context (Decline)
_out="$(detect_prompt "$(make_tool_prompt "test" "may have side effects")")"
assert_eq "Pattern: tool → question+approval+context" \
    "question+approval+context" "$_out"

# Trust prompt: has question + approval + context (prompt injection warning)
_out="$(detect_prompt "$(make_trust_prompt)")"
assert_eq "Pattern: trust → question+approval+context" \
    "question+approval+context" "$_out"

# Full access prompt: has question + approval + context (Go back)
_out="$(detect_prompt "$(make_full_access_prompt)")"
assert_eq "Pattern: full access → question+approval+context" \
    "question+approval+context" "$_out"

# Minimal prompt with only question + approval (no context denial options)
_out="$(detect_prompt "$(cat <<'PANE'
  Would you like to run the following command?
  echo "hello"
  Yes, just this once
PANE
)")"
assert_eq "Pattern: minimal question+approval → question+approval" \
    "question+approval" "$_out"

###############################################################################
#                         COOLDOWN LOGIC                                      #
###############################################################################

section "in_cooldown — Pane cooldown logic"

# Fresh pane — never approved, should NOT be in cooldown
LAST_APPROVED=()
assert_fail "Cooldown: fresh pane is not in cooldown" \
    in_cooldown "%1"

# Just approved — should be in cooldown
LAST_APPROVED=(["%1"]="$(date +%s)")
assert_ok "Cooldown: just-approved pane is in cooldown" \
    in_cooldown "%1"

# Approved 10 seconds ago — should NOT be in cooldown (> 2s)
LAST_APPROVED=(["%1"]="$(($(date +%s) - 10))")
assert_fail "Cooldown: pane approved 10s ago is not in cooldown" \
    in_cooldown "%1"

# Approved exactly at threshold
LAST_APPROVED=(["%1"]="$(($(date +%s) - 2))")
assert_fail "Cooldown: pane at exactly 2s is not in cooldown" \
    in_cooldown "%1"

# Approved 1 second ago — should be in cooldown
LAST_APPROVED=(["%1"]="$(($(date +%s) - 1))")
assert_ok "Cooldown: pane approved 1s ago is in cooldown" \
    in_cooldown "%1"

# Different panes have independent cooldowns
LAST_APPROVED=(["%1"]="$(date +%s)" ["%2"]="$(($(date +%s) - 10))")
assert_ok "Cooldown: pane %1 just approved, in cooldown" \
    in_cooldown "%1"
assert_fail "Cooldown: pane %2 approved 10s ago, not in cooldown" \
    in_cooldown "%2"

###############################################################################
#                       BUILD_AGENT_CMD                                       #
###############################################################################

section "build_agent_cmd — Command construction"

_out="$(build_agent_cmd "" "fix the bug")"
assert_eq "build_agent_cmd: no model" \
    "codex 'fix the bug'" "$_out"

_out="$(build_agent_cmd "o4-mini" "fix the bug")"
assert_eq "build_agent_cmd: with model" \
    "codex --model o4-mini 'fix the bug'" "$_out"

_out="$(build_agent_cmd "gpt-4.1" "it's a test")"
assert_eq "build_agent_cmd: single-quote escaping" \
    "codex --model gpt-4.1 'it'\\''s a test'" "$_out"

_out="$(build_agent_cmd "" "simple task")"
assert_contains "build_agent_cmd: starts with codex" "$_out" "codex"

_out="$(build_agent_cmd "o3" "task")"
assert_contains "build_agent_cmd: model flag present" "$_out" "--model o3"

_out="$(build_agent_cmd "" "task with \"double quotes\"")"
assert_eq "build_agent_cmd: double quotes preserved" \
    "codex 'task with \"double quotes\"'" "$_out"

# Interactive mode (no task)
_out="$(build_agent_cmd "" "")"
assert_eq "build_agent_cmd: interactive mode" \
    "codex" "$_out"

_out="$(build_agent_cmd "o4-mini" "")"
assert_eq "build_agent_cmd: interactive with model" \
    "codex --model o4-mini" "$_out"

###############################################################################
#                       ENSURE_CODEX_CONFIG                                   #
###############################################################################

section "ensure_codex_config — Codex config setup"

_test_config_creates_dir() {
    local fake_home
    fake_home="$(mktemp -d)"
    # No .codex dir at all
    HOME="$fake_home" ensure_codex_config 2>/dev/null

    local result=1
    [[ -d "$fake_home/.codex" ]] && result=0
    rm -rf "$fake_home"
    return $result
}

_test_config_creates_toml() {
    local fake_home
    fake_home="$(mktemp -d)"
    HOME="$fake_home" ensure_codex_config 2>/dev/null

    local result=1
    [[ -f "$fake_home/.codex/config.toml" ]] && result=0
    rm -rf "$fake_home"
    return $result
}

_test_config_idempotent() {
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.codex"
    echo 'approval_policy = "on-request"' > "$fake_home/.codex/config.toml"

    local before after
    before="$(cat "$fake_home/.codex/config.toml")"
    HOME="$fake_home" ensure_codex_config 2>/dev/null
    after="$(cat "$fake_home/.codex/config.toml")"
    rm -rf "$fake_home"

    # Should not have modified existing config
    [[ "$before" == "$after" ]]
}

_test_config_preserves_existing() {
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.codex"
    cat > "$fake_home/.codex/config.toml" <<'EOF'
approval_policy = "untrusted"
sandbox_mode = "read-only"
model = "o4-mini"
EOF

    HOME="$fake_home" ensure_codex_config 2>/dev/null

    local result
    result="$(cat "$fake_home/.codex/config.toml")"
    rm -rf "$fake_home"

    [[ "$result" == *"approval_policy"* ]] && \
    [[ "$result" == *"model"* ]]
}

assert_ok "ensure_codex_config: creates .codex directory" _test_config_creates_dir
assert_ok "ensure_codex_config: creates config.toml" _test_config_creates_toml
assert_ok "ensure_codex_config: idempotent (no overwrite)" _test_config_idempotent
assert_ok "ensure_codex_config: preserves existing config" _test_config_preserves_existing

###############################################################################
#                         AUDIT FUNCTION                                      #
###############################################################################

section "audit — Logging"

_audit_tmp="$(mktemp)"
AUDIT_LOG="$_audit_tmp"

audit "%99" "question+approval"
_content="$(cat "$_audit_tmp")"
assert_contains "audit: writes pane ID" "$_content" "pane=%99"
assert_contains "audit: writes pattern" "$_content" 'pattern="question+approval"'
assert_contains "audit: writes APPROVED" "$_content" "APPROVED"
assert_contains "audit: writes timestamp" "$_content" "[20"

rm -f "$_audit_tmp"

###############################################################################
#                     COMMON.SH UTILITIES                                     #
###############################################################################

section "common.sh — Logging and prereqs"

# log functions write to stderr
_out="$(log_info "test message" 2>&1)"
assert_contains "log_info: contains INFO" "$_out" "INFO"
assert_contains "log_info: contains message" "$_out" "test message"

_out="$(log_warn "warning msg" 2>&1)"
assert_contains "log_warn: contains WARN" "$_out" "WARN"

_out="$(log_error "error msg" 2>&1)"
assert_contains "log_error: contains ERROR" "$_out" "ERROR"

# check_prereqs — tmux and codex should be available in test environment
assert_ok "check_prereqs: passes when tmux and codex are available" check_prereqs

# log_dir — returns a writable directory
_test_log_dir_returns_path() {
    local d
    d="$(log_dir)"
    [[ -n "$d" ]] && [[ -d "$d" ]]
}
assert_ok "log_dir: returns an existing directory" _test_log_dir_returns_path

_test_log_dir_writable() {
    local d
    d="$(log_dir)"
    touch "$d/.codex-yolo-test-probe" 2>/dev/null && rm -f "$d/.codex-yolo-test-probe"
}
assert_ok "log_dir: returned directory is writable" _test_log_dir_writable

# log_dir fallback — when /tmp is not writable, uses ~/.codex-yolo/logs
_test_log_dir_fallback() {
    local fake_home
    fake_home="$(mktemp -d)"
    # Run in a subshell where /tmp probe will fail (override touch via function)
    local result
    result="$(HOME="$fake_home" bash -c '
        touch() { return 1; }
        export -f touch
        source "'"$SCRIPT_DIR"'/lib/common.sh"
        log_dir
    ' 2>/dev/null)"
    rm -rf "$fake_home"
    [[ "$result" == *"/.codex-yolo/logs" ]]
}
assert_ok "log_dir: falls back to ~/.codex-yolo/logs when /tmp is not writable" _test_log_dir_fallback

###############################################################################
#                  LAUNCHER ARGUMENT PARSING                                  #
###############################################################################

section "codex-yolo — Argument parsing and validation"

# Help flag exits 0
assert_ok "launcher: --help exits successfully" \
    bash "$SCRIPT_DIR/codex-yolo" --help

assert_ok "launcher: -h exits successfully" \
    bash "$SCRIPT_DIR/codex-yolo" -h

assert_fail "launcher: -d nonexistent path fails" \
    bash "$SCRIPT_DIR/codex-yolo" -d /nonexistent/path/xyz "task"

assert_fail "launcher: -f nonexistent file fails" \
    bash "$SCRIPT_DIR/codex-yolo" -f /nonexistent/file.txt

# No args = interactive mode (creates a tmux session, so we need cleanup)
_test_no_args() {
    local before
    before="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
    bash "$SCRIPT_DIR/codex-yolo" >/dev/null 2>&1
    local rc=$?
    # Kill any new codex-yolo-* sessions created during the test
    local s
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^codex-yolo-' || true); do
        echo "$before" | grep -qxF "$s" || tmux kill-session -t "$s" 2>/dev/null || true
    done
    return $rc
}
assert_ok "launcher: no arguments launches interactive mode" _test_no_args

# Unknown option exits non-zero
assert_fail "launcher: unknown --flag fails" \
    bash "$SCRIPT_DIR/codex-yolo" --bogus

# --dir with nonexistent path
assert_fail "launcher: --dir nonexistent path fails" \
    bash "$SCRIPT_DIR/codex-yolo" --dir /nonexistent/path/xyz "task"

# Short flags match long flags for --dir and --file
assert_fail "launcher: -d matches --dir behavior" \
    bash "$SCRIPT_DIR/codex-yolo" -d /nonexistent/path/xyz "task"

assert_fail "launcher: -f matches --file behavior" \
    bash "$SCRIPT_DIR/codex-yolo" -f /nonexistent/file.txt

###############################################################################
#                REALISTIC TERMINAL CAPTURES                                  #
###############################################################################

section "detect_prompt — Realistic full-pane captures"

# Realistic command prompt after scrollback
assert_ok "Realistic: command prompt after scrollback" \
    detect_prompt "$(cat <<'PANE'

  codex> Working on your task...

  I'll check the project structure first.
  Let me look at the files in the current directory.

  $ ls -la

  total 48
  drwxr-xr-x  5 user user  4096 Feb 15 10:00 .
  drwxr-xr-x  3 user user  4096 Feb 15 09:00 ..
  -rw-r--r--  1 user user  1234 Feb 15 10:00 main.py

  Now let me run the tests to see what's failing.

  Would you like to run the following command?

    python3 -m pytest tests/ -v

  ❯ Yes, just this once
    Yes, and don't ask again for commands that start with `python3`
    No, and tell Codex what to do differently
PANE
)"

# Realistic edit prompt
assert_ok "Realistic: file edit after analysis" \
    detect_prompt "$(cat <<'PANE'

  codex> I found the bug on line 42.
  The token validation skips the expiry check.

  Would you like to make the following edits?

    src/auth/login.ts
    @@ -40,3 +40,5 @@
    - if (token.isValid()) {
    + if (token.isValid() && !token.isExpired()) {

  ❯ Yes, just this once
    Yes, and don't ask again for these files
    No, and tell Codex what to do differently
PANE
)"

# Realistic trust prompt on first launch
assert_ok "Realistic: trust directory on first launch" \
    detect_prompt "$(cat <<'PANE'

  ╭──────────────────────────────────────────╮
  │         OpenAI Codex CLI v0.104          │
  ╰──────────────────────────────────────────╯

  Do you trust the contents of this directory? Working with untrusted
  contents comes with higher risk of prompt injection.

  /home/user/git/my-project

  ❯ Yes, continue
PANE
)"

# Realistic network access prompt
assert_ok "Realistic: network access after browsing" \
    detect_prompt "$(cat <<'PANE'

  codex> Let me check the API documentation.

  Allow Codex to access docs.rs

  Would you like to run the following command?

    curl https://docs.rs/tokio/latest/tokio/

  ❯ Yes, just this once
    Yes, and allow this host for this session
    No, and tell Codex what to do differently
PANE
)"

# Second prompt after first was approved
assert_ok "Realistic: second prompt after first approved" \
    detect_prompt "$(cat <<'PANE'
  $ ls -la
  total 12
  -rw-r--r-- 1 user user 500 Feb 15 10:00 main.py

  Good, now let me run the linter.

  Would you like to run the following command?

    python3 -m ruff check .

  ❯ Yes, just this once
    Yes, and don't ask again for commands that start with `python3`
    No, and tell Codex what to do differently
PANE
)"

###############################################################################
#                  INTEGRATION: DAEMON + TMUX                                 #
###############################################################################

section "Integration — Daemon with real tmux"

_INTEG_SESSION="codex-yolo-test-$$"
_integ_cleanup() {
    tmux kill-session -t "$_INTEG_SESSION" 2>/dev/null || true
    sleep 0.2
}

# Create a tmux session with a pane, inject a fake permission prompt,
# verify the daemon detects and approves it
_run_integ_command() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    # Create session with a cat process (keeps pane alive and accepts input)
    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # Inject a command execution prompt into the pane
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls -la /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    # Run daemon for a short burst
    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^AUDIT_LOG=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_edit() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Would you like to make the following edits?
  src/main.py
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_tool() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Approve app tool call?
  database_query
  may have side effects
  Run the tool and continue.
  Decline this tool call and continue.
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_trust() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Do you trust the contents of this directory?
  /home/user/project
  Yes, continue
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_no_false_positive() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # Send normal output — no permission prompt
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'OUTPUT'
  Working on the task...
  Reading files and analyzing code.
  No permission needed here.
OUTPUT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 1.5 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_elicitation()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    # Should NOT contain any approvals
    [[ "$result" != *"APPROVED"* ]]
}

assert_ok  "Integration: command prompt detected and approved" _run_integ_command
assert_ok  "Integration: file edit prompt detected and approved" _run_integ_edit
assert_ok  "Integration: tool call prompt detected and approved" _run_integ_tool
assert_ok  "Integration: trust directory prompt detected and approved" _run_integ_trust
assert_ok  "Integration: no false positive on normal output" _run_integ_no_false_positive

# ── Per-session audit log ────────────────────────────────────────────────────

section "Per-session audit log"

# Verify the daemon uses session-specific log when invoked with 3rd arg
_run_integ_audit_log_arg() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    # Run daemon with explicit audit log path (3rd arg)
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION" 0.2 "$audit_tmp" 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

assert_ok "Per-session audit: daemon uses 3rd arg as log path" _run_integ_audit_log_arg

# Verify default audit log includes session name and uses log_dir
_check_default_audit_path() {
    # Source common.sh so log_dir is available, then check the path contains the session name
    local path
    path="$(source "$SCRIPT_DIR/lib/common.sh"; echo "$(log_dir)/codex-yolo-codex-yolo-test-123.log")"
    [[ "$path" == *"codex-yolo-codex-yolo-test-123.log" ]]
}

assert_ok "Per-session audit: default path includes session name" _check_default_audit_path

# Verify launcher generates per-session log path using log_dir
_check_launcher_audit_path() {
    grep -q 'AUDIT_LOG="$(log_dir)/codex-yolo-${SESSION_NAME}.log"' "$SCRIPT_DIR/codex-yolo"
}

assert_ok "Per-session audit: launcher sets AUDIT_LOG from SESSION_NAME" _check_launcher_audit_path

# ── Integration: Concurrent daemons with isolated logs ────────────────────────

section "Integration — Concurrent daemons"

_INTEG_SESSION_A="codex-yolo-test-A-$$"
_INTEG_SESSION_B="codex-yolo-test-B-$$"

_concurrent_cleanup() {
    tmux kill-session -t "$_INTEG_SESSION_A" 2>/dev/null || true
    tmux kill-session -t "$_INTEG_SESSION_B" 2>/dev/null || true
    sleep 0.2
}

# Two daemons running concurrently must write to their own audit logs
_run_integ_concurrent_isolated_logs() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    # Create two independent sessions
    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    # Inject different prompts into each session
    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /home/project-a
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""

    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'PROMPT'
  Would you like to make the following edits?
  src/main.py
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    # Run two daemons concurrently with separate audit logs
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    # Wait for both daemons to finish
    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Each log must have its own APPROVED entry
    [[ "$result_a" == *"APPROVED"* ]] && [[ "$result_b" == *"APPROVED"* ]]
}

_run_integ_concurrent_no_crosstalk() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    # Create two sessions — only session A gets a prompt
    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    # Session A: real prompt
    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""

    # Session B: normal output, no prompt
    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'OUTPUT'
  Working on the task...
  Reading files and analyzing code.
OUTPUT
)" ""
    sleep 0.2

    # Run two daemons concurrently
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 1.5 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Session A should be approved, session B should NOT
    [[ "$result_a" == *"APPROVED"* ]] && [[ "$result_b" != *"APPROVED"* ]]
}

_run_integ_concurrent_session_in_log() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""

    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'PROMPT'
  Would you like to make the following edits?
  src/app.js
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Log A must reference session A, log B must reference session B
    [[ "$result_a" == *"session=$_INTEG_SESSION_A"* ]] && \
    [[ "$result_b" == *"session=$_INTEG_SESSION_B"* ]] && \
    [[ "$result_a" != *"session=$_INTEG_SESSION_B"* ]] && \
    [[ "$result_b" != *"session=$_INTEG_SESSION_A"* ]]
}

assert_ok  "Concurrent: both daemons approve their own prompts" _run_integ_concurrent_isolated_logs
assert_ok  "Concurrent: no crosstalk — daemon B ignores session A prompt" _run_integ_concurrent_no_crosstalk
assert_ok  "Concurrent: each log only references its own session" _run_integ_concurrent_session_in_log

###############################################################################
#              DAEMON RESILIENCE — survives transient errors                  #
###############################################################################

section "Daemon resilience — survives errors and keeps approving"

# The daemon must survive transient errors (unwritable audit log, disappearing
# panes, etc.) and continue approving prompts. Previously it used set -euo
# pipefail which killed it silently on any unhandled error.

_RESIL_SESSION="codex-yolo-resil-$$"
_resil_cleanup() {
    tmux kill-session -t "$_RESIL_SESSION" 2>/dev/null || true
    sleep 0.2
}

# Test: daemon survives when audit log becomes unwritable mid-run, then
# still approves prompts once log is writable again.
_run_resil_unwritable_log() {
    _resil_cleanup
    local audit_tmp audit_dir
    audit_dir="$(mktemp -d)"
    audit_tmp="$audit_dir/audit.log"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # First prompt — daemon writes to writable log
    tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    # Start daemon in background
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 1

    # Daemon should have approved first prompt
    local first_result
    first_result="$(cat "$audit_tmp" 2>/dev/null)"

    # Make log unwritable
    chmod 000 "$audit_dir" 2>/dev/null || true

    # Inject a second prompt — daemon must survive the log write failure
    tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<'PROMPT'
  Would you like to run the following command?
  git status
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 1.5

    # Check daemon is still alive
    local daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1

    # Restore permissions and clean up
    chmod 755 "$audit_dir" 2>/dev/null || true
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -rf "$audit_dir"
    _resil_cleanup

    # Both conditions must hold:
    # 1. First prompt was approved (log has APPROVED)
    # 2. Daemon was still alive after log write failure
    [[ "$first_result" == *"APPROVED"* ]] && (( daemon_alive ))
}

# Test: daemon survives when a pane disappears mid-iteration.
_run_resil_pane_disappears() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    # Create session with two windows
    tmux new-session -d -s "$_RESIL_SESSION" -n "test1" "cat"
    tmux new-window -t "$_RESIL_SESSION" -n "test2" "cat"
    sleep 0.3

    # Inject prompt in window 1
    tmux send-keys -t "$_RESIL_SESSION:test1" "$(cat <<'PROMPT'
  Would you like to run the following command?
  ls /tmp
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 0.2

    # Start daemon
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 1

    # Kill window 2 (pane disappears while daemon is iterating over panes)
    tmux kill-window -t "$_RESIL_SESSION:test2" 2>/dev/null || true
    sleep 0.5

    # Inject another prompt in window 1
    tmux send-keys -t "$_RESIL_SESSION:test1" "$(cat <<'PROMPT'
  Would you like to make the following edits?
  src/main.py
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
    sleep 1.5

    local result daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1
    result="$(cat "$audit_tmp")"

    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -f "$audit_tmp"
    _resil_cleanup

    # Daemon must still be alive and have approved prompts
    (( daemon_alive )) && [[ "$result" == *"APPROVED"* ]]
}

# Test: daemon logs its own exit (EXIT trap works).
_run_resil_exit_logged() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # Run daemon briefly, then kill it
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 0.5
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _resil_cleanup

    # The EXIT trap should have logged the daemon exit
    [[ "$result" == *"Daemon exited"* ]]
}

# Test: daemon keeps approving after many rapid iterations without crashing.
_run_resil_rapid_prompts() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # Start daemon with very fast poll
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.1 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!

    # Inject 3 prompts rapidly
    local i
    for i in 1 2 3; do
        tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<PROMPT
  Would you like to run the following command?
  command-$i
  Yes, just this once
  No, and tell Codex what to do differently
PROMPT
)" ""
        sleep 1
    done

    local daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1
    local result
    result="$(cat "$audit_tmp")"

    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -f "$audit_tmp"
    _resil_cleanup

    # Count APPROVED lines — should have at least 2
    local count
    count="$(echo "$result" | grep -c "APPROVED" || true)"
    (( daemon_alive )) && (( count >= 2 ))
}

assert_ok "Resilience: daemon survives unwritable audit log" _run_resil_unwritable_log
assert_ok "Resilience: daemon survives disappearing pane" _run_resil_pane_disappears
assert_ok "Resilience: daemon logs its own exit via EXIT trap" _run_resil_exit_logged
assert_ok "Resilience: daemon handles rapid sequential prompts" _run_resil_rapid_prompts

###############################################################################
#                          SUMMARY                                            #
###############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if (( FAIL == 0 )); then
    echo "${_green}All $PASS tests passed${_reset} ($TOTAL total, $SKIP skipped)"
else
    echo "${_red}$FAIL failed${_reset}, $PASS passed ($TOTAL total, $SKIP skipped)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAIL
