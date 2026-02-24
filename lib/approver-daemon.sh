#!/usr/bin/env bash
# approver-daemon.sh — Background monitor that auto-approves Codex CLI permission prompts
#
# Usage: approver-daemon.sh <session-name> [poll-interval] [audit-log]
# Discovers all panes in the given tmux session and monitors them.

set -u  # Catch unset variables, but NO set -e (daemon must survive transient errors)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SESSION_NAME="${1:?Usage: approver-daemon.sh <session-name> [poll-interval] [audit-log]}"
POLL_INTERVAL="${2:-0.3}"
AUDIT_LOG="${3:-$(log_dir)/codex-yolo-${SESSION_NAME}.log}"
COOLDOWN_SECS=2

# Associative array tracking last-approval timestamp per pane
declare -A LAST_APPROVED

# Log daemon exit for debugging (catches crashes, signals, etc.)
trap '_exit_code=$?; echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon exited (code=$_exit_code, session=$SESSION_NAME)" >> "$AUDIT_LOG" 2>/dev/null; log_warn "Approver daemon exiting (code=$_exit_code)" 2>/dev/null' EXIT

audit() {
    local pane="$1" pattern="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] APPROVED pane=$pane pattern=\"$pattern\"" >> "$AUDIT_LOG" 2>/dev/null || true
    log_info "Auto-approved: pane=$pane pattern=\"$pattern\"" 2>/dev/null || true
}

# Check if a pane is in cooldown
in_cooldown() {
    local pane="$1"
    local last="${LAST_APPROVED[$pane]:-0}"
    local now
    now="$(date +%s)"
    (( now - last < COOLDOWN_SECS ))
}

# Detect permission prompt in captured pane content.
# Requires multiple signals to avoid false positives.
#
# Codex CLI prompt styles:
#   Style A (command execution): "Would you like to run the following command?"
#          with "Yes, just this once" / "No, and tell Codex"
#   Style B (file changes): "Would you like to make the following edits?"
#          with "Yes, just this once" / "No, and tell Codex"
#   Style C (tool approval): "Approve app tool call?"
#          with "Run the tool and continue" / "Decline this tool call"
#   Style D (trust directory): "Do you trust the contents of this directory?"
#          with "Yes, continue"
#   Style E (full access): "Enable full access?"
#          with "Yes, continue anyway" / "Go back"
#   Style F (network/host): "Allow Codex to" with host access
#          with "Yes, just this once" / "Yes, and allow this host"
#
# All styles use a TUI selection list navigated with arrows, confirmed with Enter.
# The first option (approval) is pre-selected by default.
detect_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 25)"

    local has_question=0 has_approval_option=0 has_context=0

    # Primary signal — Question/header phrases that indicate a permission prompt
    if echo "$tail_content" | grep -qiE '(Would you like to run|Would you like to make|Allow Codex to|Approve app tool call|Do you trust the contents|Enable full access)'; then
        has_question=1
    fi

    # Secondary signal 1: Approval option text
    if echo "$tail_content" | grep -qiE '(Yes, just this once|Yes, continue|Yes, and don.t ask|Run the tool and continue|Apply full access|Yes, and allow this host)'; then
        has_approval_option=1
    fi

    # Secondary signal 2: Denial/context option text or contextual phrases
    # NOTE: "following command" / "following edits" are NOT here because they're
    # part of the question header itself and would cause false positives.
    if echo "$tail_content" | grep -qiE '(No, and tell Codex|Decline this tool call|Go back without|Cancel this|may have side effects|may access external|may modify|untrusted|prompt injection)'; then
        has_context=1
    fi

    # Require primary signal plus at least one secondary signal
    if (( has_question && (has_approval_option || has_context) )); then
        local pattern="question"
        (( has_approval_option )) && pattern="$pattern+approval"
        (( has_context )) && pattern="$pattern+context"
        echo "$pattern"
        return 0
    fi

    # Fallback: detect approval options even without explicit question header
    # (some Codex prompts render the question above the visible area)
    if (( has_approval_option && has_context )); then
        echo "approval+context"
        return 0
    fi

    return 1
}

# Detect Codex CLI's MCP elicitation prompts (information requests).
# Pattern: "Yes, provide the requested info" / "No, but continue without it"
detect_elicitation() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 15)"

    if echo "$tail_content" | grep -qiE 'provide the requested info'; then
        if echo "$tail_content" | grep -qiE '(continue without it|Cancel this request)'; then
            echo "elicitation"
            return 0
        fi
    fi

    return 1
}

main_loop() {
    log_info "Approver daemon started for session '$SESSION_NAME' (poll=${POLL_INTERVAL}s, cooldown=${COOLDOWN_SECS}s)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Daemon started for session=$SESSION_NAME" >> "$AUDIT_LOG"

    while true; do
        # Check if session still exists
        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            log_warn "Session '$SESSION_NAME' no longer exists, exiting daemon"
            break
        fi

        # Get all panes in the session
        local panes
        panes="$(tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_id}' 2>/dev/null)" || continue

        for pane in $panes; do
            # Skip if in cooldown
            if in_cooldown "$pane"; then
                continue
            fi

            # Capture pane content
            local content
            content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)" || continue

            # Skip empty panes
            [[ -z "$content" ]] && continue

            # Detect permission prompt
            local pattern
            if pattern="$(detect_prompt "$content")"; then
                # Send Enter to confirm the pre-selected first option (always the approval option)
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_elicitation "$content")"; then
                # Elicitation prompts — approve providing the info
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

main_loop
