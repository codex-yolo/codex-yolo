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
PLAN_APPROVAL_TTL="${CODEX_YOLO_PLAN_APPROVAL_TTL:-3600}"
SLASH_APPROVAL_TTL="${CODEX_YOLO_SLASH_APPROVAL_TTL:-60}"

# Associative array tracking last-approval timestamp per pane
declare -A LAST_APPROVED

# Static-pane send cap: if a pane's content is byte-identical across repeated
# key sends, the "prompt" is not reacting — almost certainly a false positive
# (a menu merely displayed on an idle pane). Stop after SEND_STREAK_CAP sends
# instead of typing into it every cooldown forever. Any content change resets
# the streak, so real prompts (which disappear or redraw once answered) are
# unaffected.
declare -A LAST_SENT_HASH
declare -A SEND_STREAK
SEND_STREAK_CAP="${CODEX_YOLO_SEND_STREAK_CAP:-5}"

# Hidden-prompt handling. The launcher wires a PermissionRequest hook into the
# Codex config (see codex_yolo_configure_permission_hook in common.sh) that
# records every approval request as <audit-log>.waiting/<pane-id> (line 1:
# epoch timestamp, line 2: the hook payload). A fresh marker with no visible
# dialog means the dialog is rendered off-screen — e.g. a diff taller than the
# pane pushes the "Yes, ..." options below the viewport, where capture-pane
# can never see them. The dialog still has keyboard focus, so the daemon first
# nudges the window size to force a repaint (a re-rendered dialog is then
# approved by the normal visual path with all its safeguards) and, only for a
# plain command/edit approval that stays invisible, falls back to a blind
# Enter (the approval option is preselected on fresh dialogs). Plan and
# question dialogs are never blind-answered — the payload identifies them, and
# they need arming / Recommended handling the daemon cannot verify unseen.
NOTIFY_MARKER_TTL="${CODEX_YOLO_NOTIFY_TTL:-600}"
HIDDEN_NUDGE_MAX="${CODEX_YOLO_HIDDEN_NUDGE_MAX:-2}"
# Blind Enter is only sent within this many seconds of the marker's timestamp:
# a genuine hidden dialog is frozen from the moment it renders, so it is
# answered within a few polls. A blind Enter attempted much later means the
# pane froze on something else (a shell after Codex exited, a half-typed
# command), so we decline it and let the marker expire.
HIDDEN_BLIND_WINDOW="${CODEX_YOLO_HIDDEN_BLIND_WINDOW:-45}"
declare -A HIDDEN_NUDGES
declare -A HIDDEN_PREV_HASH
declare -A HIDDEN_CHANGES
declare -A HIDDEN_MARK_TS
declare -A HIDDEN_GATED_LOGGED

# Log daemon exit for debugging (catches crashes, signals, etc.)
trap '_exit_code=$?; echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon exited (code=$_exit_code, session=$SESSION_NAME)" >> "$AUDIT_LOG" 2>/dev/null; log_warn "Approver daemon exiting (code=$_exit_code)" 2>/dev/null' EXIT

audit() {
    local pane="$1" pattern="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] APPROVED pane=$pane pattern=\"$pattern\"" >> "$AUDIT_LOG" 2>/dev/null || true
    log_info "Auto-approved: pane=$pane pattern=\"$pattern\"" 2>/dev/null || true
}

# Audit-log a non-approval event (hidden-prompt nudges and the like). Lines
# land in the same audit log the control pane tails, so the user sees them
# live in the control window.
audit_event() {
    local pane="$1" event="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $event pane=$pane" >> "$AUDIT_LOG" 2>/dev/null || true
    log_info "$event: pane=$pane" 2>/dev/null || true
}

# Returns 0 (skip) when this exact pane content has already been keyed
# SEND_STREAK_CAP times without changing. Callers must treat a non-zero
# return as "go ahead and send" so a missing function (old test extractions)
# fails open to the pre-cap behavior.
send_should_skip() {
    local pane="$1" content_hash="$2"
    [[ -n "$content_hash" ]] || return 1
    [[ "${LAST_SENT_HASH[$pane]:-}" == "$content_hash" ]] || return 1
    (( ${SEND_STREAK[$pane]:-0} >= SEND_STREAK_CAP ))
}

# Record that a key was sent for this pane content, growing the streak when
# the content is unchanged and resetting it otherwise.
note_key_sent() {
    local pane="$1" content_hash="$2"
    [[ -n "$content_hash" ]] || return 0
    if [[ "${LAST_SENT_HASH[$pane]:-}" == "$content_hash" ]]; then
        SEND_STREAK["$pane"]="$(( ${SEND_STREAK[$pane]:-0} + 1 ))"
    else
        LAST_SENT_HASH["$pane"]="$content_hash"
        SEND_STREAK["$pane"]=1
    fi
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
#          with "Yes, continue", or "Trust this folder?" with
#          "Trust and continue"
#   Style E (full access): "Enable full access?"
#          with "Yes, continue anyway" / "Go back"
#   Style F (network/host): "Allow Codex to" with host access
#          with "Yes, just this once" / "Yes, and allow this host"
#   Style G (proceed): "Would you like to run the following command?"
#          with "Yes, proceed (y)" / "No, and tell Codex what to do differently (esc)"
#
# All styles use a TUI selection list navigated with arrows. Most are confirmed
# with Enter; prompts that advertise "Yes, proceed (y)" are confirmed with y.
# The first option (approval) is pre-selected by default.
#
# Approval dialogs can grow far taller than the 25-line tail window: a long
# command echoed under the header (or inside a "Yes, and don't ask again for
# commands that start with ..." option) pushes the question header well above
# the bottom of the pane. So the header is also matched against the whole
# visible capture — but anchored to the start of the line (after an optional
# │ box border) so quoted headers in code output don't count, and only
# accepted when an approval option still sits near the pane bottom, where a
# live dialog always renders its option list.
detect_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 25)"

    local has_question=0 has_approval_option=0 has_context=0
    # Window the secondary signals are matched against. Stays the tail window
    # for a fully visible dialog; widens to the header-to-bottom region when
    # the header sits above the tail window.
    local signal_window="$tail_content"

    local question_phrases='(Would you like to run|Would you like to make|Allow Codex to|Approve app tool call|Do you trust the contents|Trust this folder|Enable full access)'
    local approval_option_re='(Yes, just this once|Yes, proceed[[:space:]]*\(y\)|Yes, continue|Yes, and don.t ask|Run the tool and continue|Apply full access|Trust and continue|Yes, and allow this host)'

    # Primary signal — Question/header phrases that indicate a permission prompt
    if echo "$tail_content" | grep -qiE "$question_phrases"; then
        has_question=1
    elif echo "$content" | grep -qiE "^[[:space:]]*(│[[:space:]]*)?$question_phrases"; then
        # Header above the tail window: only accept it while an approval
        # option is still near the pane bottom (a live dialog renders its
        # option list just above the footer; a header merely *displayed*
        # higher up — cat/diff of a fixture, quoted prose — is not one).
        if echo "$tail_content" | grep -qiE "$approval_option_re"; then
            has_question=1
            # Scope the secondary signals to the dialog region — from just
            # above the header to the pane bottom. Using the whole screen
            # would let unrelated option-like text in some other message
            # satisfy the two-signal requirement.
            local menu_start
            menu_start="$(echo "$content" | grep -niE "^[[:space:]]*(│[[:space:]]*)?$question_phrases" | head -n 1 | cut -d: -f1)"
            if [[ "$menu_start" =~ ^[0-9]+$ ]] && (( menu_start > 4 )); then
                signal_window="$(echo "$content" | tail -n "+$((menu_start - 4))")"
            else
                signal_window="$content"
            fi
        fi
    fi

    # Secondary signal 1: Approval option text
    if echo "$signal_window" | grep -qiE "$approval_option_re"; then
        has_approval_option=1
    fi

    # Secondary signal 2: Denial/context option text or contextual phrases
    # NOTE: "following command" / "following edits" are NOT here because they're
    # part of the question header itself and would cause false positives.
    if echo "$signal_window" | grep -qiE '(No, and tell Codex|Decline this tool call|Go back without|Cancel this|may have side effects|may access external|may modify|untrusted|prompt injection|requires approval|requires confirmation|Folder settings can run code|Continue only if you trust these files|Your trust decision will be saved)'; then
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

detect_plan_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 35)"

    local has_plan=0 has_approval_option=0 has_context=0

    # Require an actual plan-decision question. Loose mentions such as the
    # status line "Model changed ... for Plan mode" can remain visible above
    # an unrelated command-approval dialog; treating those words as the plan
    # signal causes the generic dialog to be withheld for lack of a /plan
    # control marker.
    if echo "$tail_content" | grep -qiE '^[[:space:]]*(│[[:space:]]*)?(Would you like to[[:space:]]+)?(proceed with (this )?plan|implement (this )?plan|approve (this )?plan)[?[:space:]]*$'; then
        has_plan=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(Yes, (proceed|implement this plan|clear context and implement)|Proceed|Implement|Approve|Continue)([[:space:]]|$)'; then
        has_approval_option=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(No, (and tell Codex|stay in Plan mode)|Go back|Cancel|Keep planning|Revise|.*do differently)'; then
        has_context=1
    fi

    if (( has_plan && has_approval_option && has_context )); then
        echo "plan"
        return 0
    fi

    return 1
}

detect_plan_choice_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 35)"

    local has_question=0 has_recommended_choice=0

    if echo "$tail_content" | grep -qiE 'Question[[:space:]]+[0-9]+/[0-9]+'; then
        has_question=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)[0-9]+[.)][[:space:]]+[^[:cntrl:]]*\(Recommended\)([[:space:]]|$)'; then
        has_recommended_choice=1
    fi

    if (( has_question && has_recommended_choice )); then
        echo "plan-choice"
        return 0
    fi

    return 1
}

plan_approval_file() {
    if [[ -n "${CODEX_YOLO_PLAN_APPROVAL_FILE:-}" ]]; then
        printf '%s\n' "$CODEX_YOLO_PLAN_APPROVAL_FILE"
        return 0
    fi

    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.plan-approval\n' "$AUDIT_LOG"
}

slash_approval_file() {
    if [[ -n "${CODEX_YOLO_SLASH_APPROVAL_FILE:-}" ]]; then
        printf '%s\n' "$CODEX_YOLO_SLASH_APPROVAL_FILE"
        return 0
    fi

    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.slash-approval\n' "$AUDIT_LOG"
}

clear_plan_approval_marker() {
    local marker
    marker="$(plan_approval_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

clear_slash_approval_marker() {
    local marker
    marker="$(slash_approval_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

plan_approval_marker_valid() {
    local pane="$1"
    local marker marker_pane marker_ts now ttl

    marker="$(plan_approval_file)" || return 1
    [[ -f "$marker" ]] || return 1

    IFS=$'\t ' read -r marker_pane marker_ts _ < "$marker" || return 1
    if [[ -z "$marker_pane" || ! "$marker_ts" =~ ^[0-9]+$ ]]; then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    ttl="$PLAN_APPROVAL_TTL"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=3600
    now="$(date +%s)"
    if (( now - marker_ts > ttl )); then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    [[ "$marker_pane" == "$pane" ]]
}

slash_approval_marker_valid() {
    local pane="$1"
    local marker marker_pane marker_ts now ttl

    marker="$(slash_approval_file)" || return 1
    [[ -f "$marker" ]] || return 1

    IFS=$'\t ' read -r marker_pane marker_ts _ < "$marker" || return 1
    if [[ -z "$marker_pane" || ! "$marker_ts" =~ ^[0-9]+$ ]]; then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    ttl="$SLASH_APPROVAL_TTL"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=60
    now="$(date +%s)"
    if (( now - marker_ts > ttl )); then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    [[ "$marker_pane" == "$pane" ]]
}

# Directory holding the per-pane approval-request markers written by the
# PermissionRequest hook (see codex_yolo_configure_permission_hook in
# common.sh).
notify_waiting_dir() {
    if [[ -n "${CODEX_YOLO_WAITING_DIR:-}" ]]; then
        printf '%s\n' "$CODEX_YOLO_WAITING_DIR"
        return 0
    fi

    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.waiting\n' "$AUDIT_LOG"
}

# A marker is fresh when it exists, carries a numeric epoch timestamp, and is
# younger than NOTIFY_MARKER_TTL. Malformed and expired markers are removed.
notify_marker_fresh() {
    local pane="$1"
    local dir marker ts now ttl

    dir="$(notify_waiting_dir)" || return 1
    marker="$dir/$pane"
    [[ -f "$marker" ]] || return 1

    IFS=$' \t' read -r ts _ < "$marker" 2>/dev/null || ts=""
    if [[ ! "$ts" =~ ^[0-9]+$ ]]; then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    ttl="$NOTIFY_MARKER_TTL"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=600
    now="$(date +%s)"
    if (( now - ts > ttl )); then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    return 0
}

clear_notify_marker() {
    local pane="$1" dir
    dir="$(notify_waiting_dir 2>/dev/null)" || return 0
    rm -f "$dir/$pane" 2>/dev/null || true
}

# Print the marker's epoch timestamp (line 1), or fail if absent/malformed.
notify_marker_ts() {
    local pane="$1" dir marker ts
    dir="$(notify_waiting_dir)" || return 1
    marker="$dir/$pane"
    [[ -f "$marker" ]] || return 1
    IFS=$' \t' read -r ts _ < "$marker" 2>/dev/null || return 1
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$ts"
}

# Print the payload the hook recorded in the marker (line 2 holds the hook's
# stdin JSON with newlines stripped). Empty when unavailable.
notify_marker_payload() {
    local pane="$1" dir marker line
    dir="$(notify_waiting_dir)" || return 1
    marker="$dir/$pane"
    [[ -f "$marker" ]] || return 1
    sed -n '2p' "$marker" 2>/dev/null
}

# Print the tool name the hook payload recorded ("tool_name":"Bash" for a
# shell escalation, the tool's name for MCP calls). Empty when the payload
# carries no tool_name field.
notify_marker_tool() {
    local pane="$1" payload
    payload="$(notify_marker_payload "$pane" 2>/dev/null)" || return 1
    printf '%s\n' "$payload" | grep -oE '"tool_name":"[^"]*"' | head -n 1
}

# Decide whether a hidden dialog may be answered blind. Only plain command /
# file-edit approvals qualify — identified by the payload's tool_name field
# (only that field is inspected, so a cwd or command containing "plan" never
# gates a plain shell escalation). Plan and question dialogs need arming /
# Recommended handling the daemon cannot verify without seeing them, so a
# tool name suggesting either is reserved for the user. A missing tool_name
# fails closed — without positive evidence it is a plain tool approval, we do
# not type into the pane.
notify_marker_blindable() {
    local pane="$1" tool
    tool="$(notify_marker_tool "$pane" 2>/dev/null)" || return 1
    [[ -n "$tool" ]] || return 1
    if printf '%s' "$tool" | grep -qiE '(plan|question|ask|input)'; then
        return 1
    fi
    return 0
}

# Forget a pane's hidden-prompt bookkeeping: its notify marker and all
# per-pane episode state. Called whenever an approval was delivered to the
# pane (the marker's dialog is gone, visible or not) and whenever the marker
# is found no longer fresh, so leftover state can never corrupt a later
# episode on the same pane.
reset_hidden_state() {
    local pane="$1"
    clear_notify_marker "$pane" 2>/dev/null || true
    unset "HIDDEN_NUDGES[$pane]" 2>/dev/null || true
    unset "HIDDEN_PREV_HASH[$pane]" 2>/dev/null || true
    unset "HIDDEN_CHANGES[$pane]" 2>/dev/null || true
    unset "HIDDEN_MARK_TS[$pane]" 2>/dev/null || true
    unset "HIDDEN_GATED_LOGGED[$pane]" 2>/dev/null || true
}

# A pane qualifies for a blind Enter only when its bottom lines show neither
# a ›/❯ marker (the Codex TUI's idle composer prompt and every rendered
# selection list draw one) nor box chrome (╰, drawn by boxed UI like the
# welcome banner), while the off-screen-dialog state this path exists for
# leaves raw diff/command text at the bottom of the pane. Keeps a stale
# marker from typing into an input box the user may be composing in.
hidden_candidate() {
    local content="$1"
    local bottom
    bottom="$(printf '%s\n' "$content" | tail -n 15)"
    if printf '%s\n' "$bottom" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(›|❯)'; then
        return 1
    fi
    ! printf '%s\n' "$bottom" | grep -q '╰'
}

# Force the pane's TUI to repaint by shrinking its window one row and growing
# it back (two SIGWINCHes). The Codex TUI re-renders on resize, which usually
# brings an off-screen dialog's options back inside the viewport. Re-enables
# automatic window sizing afterwards so the window keeps following client
# resizes (resize-window switches it to manual).
nudge_pane_window() {
    local pane="$1" win
    win="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)" || return 1
    [[ -n "$win" ]] || return 1
    tmux resize-window -t "$win" -U 1 2>/dev/null || return 1
    tmux resize-window -t "$win" -D 1 2>/dev/null || true
    tmux set-option -w -t "$win" -u window-size 2>/dev/null || true
    return 0
}

# Detect if the slash command autocomplete picker is visible.
# When the user types "/p" (or similar), Codex CLI shows an autocomplete popup
# with lines like:  /plan    Switch to plan mode and optionally send a prompt
# This can contribute false secondary signals (e.g. "/permissions" contains "permission").
# If 2+ such lines appear in the tail, veto any approval to avoid selecting autocomplete items.
detect_slash_picker() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 15)"

    # Count lines matching slash command autocomplete format:
    #   /command-name    Description text
    # Optional ❯ selection marker before the /command.
    local count
    count="$(echo "$tail_content" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?/[a-z][-a-z]+[[:space:]]{2,}' 2>/dev/null)" || count=0

    (( count >= 2 ))
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

detect_slash_command_prompt() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 25)"

    local has_question=0 has_yes=0 has_no=0

    if echo "$tail_content" | grep -qiE '(clear (conversation|context)|start (a )?new (conversation|chat)|discard conversation|are you sure|confirm)'; then
        has_question=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(Yes|Clear|Confirm|Proceed|Continue)([[:space:]]|$)'; then
        has_yes=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(No|Cancel|Go back|Keep)([[:space:]]|$)'; then
        has_no=1
    fi

    if (( has_question && has_yes && has_no )); then
        echo "slash-command"
        return 0
    fi

    return 1
}

# Detect Codex CLI's "Replace goal?" confirmation, shown when a /goal command
# (e.g. issued by the control pane's queue / loop) sets a new objective while a
# goal is already active. Pattern:
#   Replace goal?
#   New objective: <objective text>
#
#   › 1. Replace current goal  Set the new objective and start it now
#     2. Cancel                Keep the current goal
#
# The first option (Replace current goal) is pre-selected, so Enter confirms.
# Three independent signals are required so this only fires on the genuine
# goal-replacement prompt and never on incidental "goal" text in agent output.
detect_goal_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 20)"

    local has_question=0 has_replace=0 has_keep=0

    if echo "$tail_content" | grep -qiE 'Replace goal\?'; then
        has_question=1
    fi

    if echo "$tail_content" | grep -qiE 'Replace current goal'; then
        has_replace=1
    fi

    if echo "$tail_content" | grep -qiE '(Keep the current goal|New objective:)'; then
        has_keep=1
    fi

    if (( has_question && has_replace && has_keep )); then
        echo "goal"
        return 0
    fi

    return 1
}

# Decide which key approves a permission prompt detected by detect_prompt.
# Enter activates the pre-selected option (Codex pre-selects the approval
# option on fresh dialogs). But when the selection marker is visible on a
# non-approval option (e.g. the selection was moved before the daemon
# started), Enter would pick the wrong option — so send the approval option's
# number instead, which jumps the selection there. If the number press only
# moves the selection without activating it, the next poll cycle sees the
# marker on the approval option and finishes with Enter. Prompts that
# advertise a literal "(y)" shortcut are confirmed with y, which lands on Yes
# regardless of where the selection sits.
approval_key_for_prompt() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 25)"

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((_|❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?Yes, proceed[[:space:]]*\(y\)([[:space:]]|$)'; then
        printf '%s\n' "y"
        return 0
    fi

    # Only real ❯/›/_ selection markers count here — a bare ">" is too common
    # in shell transcripts (PS2 continuation, markdown blockquotes) and would
    # route to the digit path, typing digits into an input box on a false
    # positive. Without a marker we fall through to Enter, which activates
    # the pre-selected approval option.

    # Selection marker already on an approval option ("Yes, just this once",
    # "Yes, and don't ask again", "Run the tool and continue", ...) → Enter
    # confirms it.
    if echo "$tail_content" | grep -qiE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*|_[[:space:]]+)([0-9]+[.)][[:space:]]*)?(Yes\b|Run the tool|Apply full access|Trust and continue)'; then
        printf '%s\n' "Enter"
        return 0
    fi

    # Marker visible on some other numbered option → send the first approval
    # option's number to move the selection there.
    if echo "$tail_content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*|_[[:space:]]+)[0-9]+[.)]'; then
        local digit
        digit="$(echo "$tail_content" \
            | grep -iE '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)][[:space:]]*(Yes\b|Run the tool|Apply full access|Trust and continue)' \
            | head -n 1 | grep -oE '[0-9]+' | head -n 1)"
        if [[ -n "$digit" ]]; then
            printf '%s\n' "$digit"
            return 0
        fi
    fi

    printf '%s\n' "Enter"
}

# Detect a question dialog that offers a "(Recommended)" option. Codex renders
# plan-mode questions (and similar user-input requests) as a numbered option
# menu:
#
#   Question 1/2 (2 unanswered)
#   What form should the Snake game take?
#
#   › 1. Single HTML (Recommended)  A self-contained browser game ...
#     2. React app                  A small Vite/React project ...
#     3. Terminal game              A command-line implementation ...
#
# Signals required:
#   - a numbered option line labelled "(Recommended)" — case-sensitive:
#     Codex's convention is a capital R, so lowercase "(recommended)" in
#     user-driven pickers or prose does not count
#   - a ❯/›/_ selection marker on a numbered option (an active menu, not
#     prose; a bare ">" is NOT accepted — markdown blockquotes and PS2
#     continuation lines in ordinary output would satisfy it)
#   - at least two numbered option lines (a menu offers alternatives)
#   - no checkbox glyphs in the options (multi-select questions need toggling
#     before Enter — blindly confirming would submit nothing)
#
# Questions without a recommended option are deliberately left for the user.
# Yes/No permission prompts never carry "(Recommended)" labels and are handled
# by detect_prompt.
detect_question_prompt() {
    local content="$1"

    # A numbered option labelled (Recommended)
    if ! echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)].*\(Recommended\)'; then
        return 1
    fi

    # An active selection marker on a numbered option
    if ! echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*|_[[:space:]]+)[0-9]+[.)]'; then
        return 1
    fi

    # At least two numbered option lines
    local option_count
    option_count="$(echo "$content" | grep -cE '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)][[:space:]]')" || option_count=0
    if (( option_count < 2 )); then
        return 1
    fi

    # multi-select rendering — checkboxes need toggling, not a blind Enter
    if echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)][[:space:]]*(\[[ xX]\]|◻|☐|☑|◼|■)'; then
        return 1
    fi

    # Bottom anchor: a live dialog renders its options just above the
    # footer/status area, so at least one option line must be near the pane
    # bottom. Keeps question menus merely *displayed* higher up on screen
    # (cat/diff of fixtures, quoted menus in prose) from firing.
    if ! echo "$content" | tail -n 25 | grep -qE '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)][[:space:]]'; then
        return 1
    fi

    echo "question+recommended"
    return 0
}

# Decide which key answers a question dialog detected by detect_question_prompt.
# Enter when the selection marker already sits on the "(Recommended)" option;
# otherwise the recommended option's number, which jumps the selection there.
# If the number press only moves the selection without activating it, the next
# poll cycle sees the marker on the recommended option and finishes with Enter.
question_approval_key() {
    local content="$1"

    if echo "$content" | grep -E '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*|_[[:space:]]+)[0-9]+[.)]' \
        | grep -qF '(Recommended)'; then
        echo "Enter"
        return 0
    fi

    local digit
    digit="$(echo "$content" \
        | grep -E '^[[:space:]]*(│[[:space:]]*)?(((❯|›)[[:space:]]*|_[[:space:]]+))?[0-9]+[.)].*\(Recommended\)' \
        | head -n 1 | grep -oE '[0-9]+' | head -n 1)"
    if [[ -n "$digit" ]]; then
        echo "$digit"
        return 0
    fi

    echo "Enter"
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

            # Clear leftover hidden-prompt state once a pane's marker is gone
            # (answered by the user, or TTL-expired). Without this, an episode
            # that ended without a daemon send would leave stale nudge counts
            # and hashes that corrupt the next hidden dialog on the same pane.
            if [[ -n "${HIDDEN_PREV_HASH[$pane]:-}" ]] && ! notify_marker_fresh "$pane" 2>/dev/null; then
                reset_hidden_state "$pane"
            fi

            # Veto: slash command autocomplete picker is visible — do not send any keys
            if detect_slash_picker "$content"; then
                continue
            fi

            # Detect control-pane initiated plan approval prompts before generic
            # prompts, so direct /plan approval dialogs are not auto-approved.
            local pattern
            if pattern="$(detect_plan_choice_prompt "$content")"; then
                if plan_approval_marker_valid "$pane"; then
                    tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                    reset_hidden_state "$pane" 2>/dev/null || true
                    LAST_APPROVED["$pane"]="$(date +%s)"
                    audit "$pane" "plan-choice-control"
                    continue
                fi
                # No control-pane marker: fall through — a question carrying a
                # "(Recommended)" option is auto-answered by the question path
                # below, marker or not.
            elif pattern="$(detect_plan_prompt "$content")"; then
                if plan_approval_marker_valid "$pane"; then
                    tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                    clear_plan_approval_marker
                    reset_hidden_state "$pane" 2>/dev/null || true
                    LAST_APPROVED["$pane"]="$(date +%s)"
                    audit "$pane" "plan-control"
                fi
                continue
            fi

            if pattern="$(detect_slash_command_prompt "$content")"; then
                if slash_approval_marker_valid "$pane"; then
                    tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                    clear_slash_approval_marker
                    reset_hidden_state "$pane" 2>/dev/null || true
                    LAST_APPROVED["$pane"]="$(date +%s)"
                    audit "$pane" "slash-control"
                fi
                continue
            fi

            # Hash the capture for the static-pane send cap: identical content
            # across repeated sends means the pane is not reacting to our keys.
            local content_hash
            content_hash="$(printf '%s' "$content" | cksum 2>/dev/null)" || content_hash=""

            # Detect "Replace goal?" prompts (from /goal via queue/loop). The
            # first option is pre-selected, so confirm with Enter. This prompt
            # is specific enough to approve without a control-pane marker.
            if pattern="$(detect_goal_prompt "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                reset_hidden_state "$pane" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
                continue
            fi

            # Detect permission prompt
            if pattern="$(detect_prompt "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                # Confirm the approval option: y when a literal shortcut is
                # advertised, Enter when it is already selected, or its number
                # when the selection marker sits on another option.
                local approval_key
                approval_key="$(approval_key_for_prompt "$content")"
                tmux send-keys -t "$pane" "$approval_key" 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                reset_hidden_state "$pane" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_question_prompt "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                # Question dialog — answer with the recommended option.
                local question_key
                question_key="$(question_approval_key "$content" 2>/dev/null)" || question_key=""
                [[ -n "$question_key" ]] || question_key="Enter"
                tmux send-keys -t "$pane" "$question_key" 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                reset_hidden_state "$pane" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_elicitation "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                # Elicitation prompts — approve providing the info
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                reset_hidden_state "$pane" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif notify_marker_fresh "$pane" 2>/dev/null; then
                # The PermissionRequest hook reported an approval request for
                # this pane, but no visual detector saw it: the dialog is
                # rendered off-screen (e.g. a diff taller than the pane). It
                # still has keyboard focus, so it can be answered unseen.
                # Leave the pane alone while the user scrolls in copy-mode,
                # and without a capture hash there is nothing safe to do.
                if [[ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null)" == "1" ]]; then
                    continue
                fi
                [[ -n "$content_hash" ]] || continue

                local marker_ts
                marker_ts="$(notify_marker_ts "$pane" 2>/dev/null)" || marker_ts=""

                # A new marker (different timestamp) starts a fresh episode, so
                # leftover nudge counts / hashes from a previous dialog on this
                # pane never carry over. Sample once, then compare next cycle.
                if [[ "${HIDDEN_MARK_TS[$pane]:-}" != "$marker_ts" ]]; then
                    HIDDEN_MARK_TS["$pane"]="$marker_ts"
                    HIDDEN_NUDGES["$pane"]=0
                    HIDDEN_CHANGES["$pane"]=0
                    HIDDEN_PREV_HASH["$pane"]="$content_hash"
                    unset "HIDDEN_GATED_LOGGED[$pane]" 2>/dev/null || true
                    continue
                fi

                # A dialog stuck off-screen is frozen; a working agent (or a
                # race where the visual path already answered) keeps changing.
                # Require two consecutive changes before treating the marker as
                # stale, so a single mid-render frame between the first two
                # polls does not discard a genuine hidden dialog.
                if [[ "${HIDDEN_PREV_HASH[$pane]:-}" != "$content_hash" ]]; then
                    HIDDEN_PREV_HASH["$pane"]="$content_hash"
                    HIDDEN_CHANGES["$pane"]="$(( ${HIDDEN_CHANGES[$pane]:-0} + 1 ))"
                    if (( ${HIDDEN_CHANGES[$pane]} >= 2 )); then
                        reset_hidden_state "$pane"
                    fi
                    continue
                fi

                # Frozen this cycle — reset the change run.
                HIDDEN_CHANGES["$pane"]=0
                local hidden_nudges="${HIDDEN_NUDGES[$pane]:-0}"

                # First try repaint nudges — if the re-render brings the dialog
                # into view, the next cycle approves it through the normal
                # detectors with all their safeguards (plan scoping,
                # Recommended-only questions). Nudging is harmless for any
                # dialog type, so it is not gated.
                if (( hidden_nudges < HIDDEN_NUDGE_MAX )) && nudge_pane_window "$pane" 2>/dev/null; then
                    HIDDEN_NUDGES["$pane"]="$((hidden_nudges + 1))"
                    audit_event "$pane" "HIDDEN-PROMPT nudge $((hidden_nudges + 1))/$HIDDEN_NUDGE_MAX"
                    continue
                fi

                # Still invisible after nudging (or resize-window failed).
                # Blind Enter is only for a plain command/edit approval: plan
                # and question dialogs (identified by the marker's payload)
                # need arming / Recommended handling the daemon cannot verify
                # unseen, so they are left for the user.
                if ! notify_marker_blindable "$pane" 2>/dev/null; then
                    if [[ -z "${HIDDEN_GATED_LOGGED[$pane]:-}" ]]; then
                        audit_event "$pane" "HIDDEN-PROMPT hidden dialog left for user (not a plain tool approval)"
                        HIDDEN_GATED_LOGGED["$pane"]=1
                    fi
                    continue
                fi

                # Only blind-answer close to when the dialog appeared: a
                # genuine hidden dialog is frozen from render, so it is handled
                # within a few polls. A blind Enter attempted much later means
                # the pane froze on something else (a shell after Codex exited,
                # a half-typed command) — decline and let the marker expire.
                local now
                now="$(date +%s)"
                if [[ ! "$marker_ts" =~ ^[0-9]+$ ]] || (( now - marker_ts > HIDDEN_BLIND_WINDOW )); then
                    continue
                fi

                # Never type into a pane whose bottom shows box chrome (idle
                # composer or a rendered dialog); such markers just expire.
                hidden_candidate "$content" 2>/dev/null || continue
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                reset_hidden_state "$pane" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "hidden-blind+Enter"
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

# Refuse to run two daemons for the same session: duplicates double-send keys
# (a second Enter usually lands on an empty input box, but a second digit
# types text into the agent's input). The lock is keyed on the per-session
# audit log, so daemons for different sessions never contend. Fails open when
# flock is unavailable or the lock file cannot be created.
if command -v flock >/dev/null 2>&1 && exec 9>"${AUDIT_LOG}.lock" 2>/dev/null; then
    if ! flock -n 9; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Duplicate daemon refused (lock held) for session=$SESSION_NAME" >> "$AUDIT_LOG" 2>/dev/null || true
        trap - EXIT
        exit 0
    fi
fi

main_loop
