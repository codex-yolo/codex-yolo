#!/usr/bin/env bash
# control-pane.sh - Interactive control window for codex-yolo sessions
set -uo pipefail

SESSION_NAME="${1:-}"
AUDIT_LOG="${2:-}"
SESSION_MODE="${3:-standard}"

declare -A LOOP_PIDS=()
declare -A LOOP_INTERVALS=()
declare -A LOOP_SECONDS=()
declare -A LOOP_PROMPTS=()
declare -A LOOP_TARGETS=()
declare -A LOOP_TYPES=()
NEXT_LOOP_ID=1
TAIL_PID=""
CONTROL_SUBMIT_DELAY="${CODEX_YOLO_CONTROL_SUBMIT_DELAY:-0.2}"
CONTROL_PERMISSIONS_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_DELAY:-0.5}"
CONTROL_PERMISSIONS_OPEN_ATTEMPTS="${CODEX_YOLO_CONTROL_PERMISSIONS_OPEN_ATTEMPTS:-10}"
CONTROL_PERMISSIONS_BUSY_RETRY_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_BUSY_RETRY_DELAY:-2}"
CONTROL_PERMISSIONS_STARTUP_ATTEMPTS="${CODEX_YOLO_CONTROL_PERMISSIONS_STARTUP_ATTEMPTS:-240}"
CONTROL_PERMISSIONS_STARTUP_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_STARTUP_DELAY:-0.5}"
CONTROL_PERMISSIONS_AUTO_REVIEW_RESET_STEPS="${CODEX_YOLO_CONTROL_PERMISSIONS_AUTO_REVIEW_RESET_STEPS:-6}"
CONTROL_PLAN_PASTE_GRACE="${CODEX_YOLO_CONTROL_PLAN_PASTE_GRACE:-0.5}"

control_audit() {
    local msg="$1"
    [[ -n "${AUDIT_LOG:-}" ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONTROL $msg" >> "$AUDIT_LOG" 2>/dev/null || true
}

control_ltrim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "$value"
}

control_preview() {
    local value="$1"
    if (( ${#value} > 80 )); then
        printf '%s...' "${value:0:77}"
    else
        printf '%s' "$value"
    fi
}

control_parse_interval() {
    local interval="$1"
    local amount unit multiplier

    [[ "$interval" =~ ^([1-9][0-9]*)([smhd])$ ]] || return 1

    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"

    case "$unit" in
        s) multiplier=1 ;;
        m) multiplier=60 ;;
        h) multiplier=3600 ;;
        d) multiplier=86400 ;;
        *) return 1 ;;
    esac

    printf '%s\n' "$(( amount * multiplier ))"
}

control_parse_loop_command() {
    local line="$1"
    local rest interval prompt seconds

    [[ "$line" == "/loop" || "$line" == "/loop "* || "$line" == $'/loop\t'* ]] || return 1

    rest="${line#/loop}"
    rest="$(control_ltrim "$rest")"
    [[ -n "$rest" ]] || return 1

    interval="${rest%%[[:space:]]*}"
    prompt="${rest#"$interval"}"
    prompt="$(control_ltrim "$prompt")"
    [[ -n "$prompt" ]] || return 1

    seconds="$(control_parse_interval "$interval")" || return 1
    printf '%s\t%s\t%s\n' "$interval" "$seconds" "$prompt"
}

control_plan_paste_enabled() {
    case "${CODEX_YOLO_CONTROL_PLAN_PASTE:-auto}" in
        1|true|yes|on) return 0 ;;
        0|false|no|off) return 1 ;;
    esac

    [[ -t 0 ]]
}

control_collect_plan_prompt() {
    local prompt="$1"
    local delay ch chunk="" tty_state="" restore_tty=0

    control_plan_paste_enabled || {
        printf '%s' "$prompt"
        return 0
    }

    delay="$CONTROL_PLAN_PASTE_GRACE"
    if [[ ! "$delay" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; then
        delay=0.5
    fi

    if [[ -t 0 ]]; then
        tty_state="$(stty -g 2>/dev/null)" && \
            stty -icanon min 0 time 0 2>/dev/null && \
            restore_tty=1
    fi

    while IFS= read -r -s -N 1 -t "$delay" ch; do
        chunk+="$ch"
    done

    if (( restore_tty )); then
        stty "$tty_state" 2>/dev/null || true
    fi

    if [[ -n "$chunk" ]]; then
        # The submit newline for a pasted command is a delimiter, not prompt text.
        [[ "$chunk" == *$'\n' ]] && chunk="${chunk%$'\n'}"
        if [[ -n "$prompt" ]]; then
            prompt+=$'\n'"$chunk"
        else
            prompt="$chunk"
        fi
    fi

    printf '%s' "$prompt"
}

control_is_plan_command() {
    local command="$1"
    [[ "$command" == "/plan" || "$command" == "/plan "* || "$command" == $'/plan\t'* ]]
}

control_agent_exists() {
    local session="$1" target_window="$2"
    tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$target_window"
}

control_permissions_page_visible() {
    local content="$1"
    [[ "$content" == *"Update Model Permissions"* ]]
}

control_permissions_command_busy() {
    local content="$1"
    [[ "$content" == *"/permissions"* && "$content" == *"disabled while a task is in progress"* ]]
}

control_permissions_auto_review_current() {
    local content="$1"
    control_permissions_page_visible "$content" || return 1
    echo "$content" | grep -qiE 'Auto-review[[:space:]]*\(current\)'
}

control_permissions_auto_review_available() {
    local content="$1"
    control_permissions_page_visible "$content" || return 1
    echo "$content" | grep -qi 'Auto-review'
}

control_permissions_needs_auto_review() {
    local content="$1"
    control_permissions_page_visible "$content" || return 1
    control_permissions_auto_review_current "$content" && return 1
    control_permissions_auto_review_available "$content"
}

control_permissions_select_auto_review() {
    local target="$1"
    local reset_steps="$CONTROL_PERMISSIONS_AUTO_REVIEW_RESET_STEPS"
    local keys=()
    local i

    if [[ ! "$reset_steps" =~ ^[1-9][0-9]*$ ]]; then
        reset_steps=6
    fi

    for (( i=0; i<reset_steps; i++ )); do
        keys+=(Up)
    done
    keys+=(Down Enter)

    tmux send-keys -t "$target" "${keys[@]}" 2>/dev/null
}

control_codex_tui_visible() {
    local content="$1"
    [[ "$content" == *"OpenAI Codex"* ]] || \
    [[ "$content" == *"Update Model Permissions"* ]] || \
    [[ "$content" == *"model:"*" /model to change"* ]]
}

control_codex_welcome_continue_visible() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 30)"
    [[ "$tail_content" == *"Welcome to Codex"* && "$tail_content" == *"Press enter to continue"* ]]
}

control_capture_target() {
    local target="$1"
    tmux capture-pane -p -t "$target" -S -100 2>/dev/null
}

control_plan_marker_file() {
    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.plan-approval\n' "$AUDIT_LOG"
}

control_plan_target_pane() {
    local session="$1" target_window="$2"
    tmux display-message -p -t "${session}:${target_window}" '#{pane_id}' 2>/dev/null
}

control_arm_plan_approval() {
    local session="$1" target_window="$2"
    local marker pane_id now

    marker="$(control_plan_marker_file)" || return 1
    pane_id="$(control_plan_target_pane "$session" "$target_window")" || return 1
    [[ -n "$pane_id" ]] || return 1
    now="$(date +%s)"

    printf '%s\t%s\n' "$pane_id" "$now" > "$marker" 2>/dev/null
}

control_disarm_plan_approval() {
    local marker
    marker="$(control_plan_marker_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

control_set_auto_review() {
    local session="$1" audit_log="$2" target_window="${3:-agent-1}"
    local target="${session}:${target_window}"
    local content open_attempt open_attempts

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review target missing: $target_window"
        return 1
    fi

    open_attempts="$CONTROL_PERMISSIONS_OPEN_ATTEMPTS"
    if [[ ! "$open_attempts" =~ ^[1-9][0-9]*$ ]]; then
        open_attempts=1
    fi

    content="$(control_capture_target "$target" 2>/dev/null)" || content=""
    if ! control_permissions_page_visible "$content"; then
        if ! tmux send-keys -t "$target" -l "/permissions" 2>/dev/null; then
            echo "failed to open /permissions on $target_window"
            AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review open failed: $target_window"
            return 1
        fi

        sleep "$CONTROL_SUBMIT_DELAY" 2>/dev/null || true
        if ! tmux send-keys -t "$target" Enter 2>/dev/null; then
            echo "failed to submit /permissions on $target_window"
            AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review submit failed: $target_window"
            return 1
        fi

        for (( open_attempt=1; open_attempt<=open_attempts; open_attempt++ )); do
            sleep "$CONTROL_PERMISSIONS_DELAY" 2>/dev/null || true
            content="$(control_capture_target "$target" 2>/dev/null)" || content=""

            if control_permissions_page_visible "$content"; then
                break
            fi

            if control_permissions_command_busy "$content"; then
                echo "permissions command disabled while task is in progress on $target_window"
                AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review busy: $target_window"
                return 2
            fi
        done
    fi

    if ! control_permissions_page_visible "$content"; then
        tmux send-keys -t "$target" Escape 2>/dev/null || true
        echo "permissions page not visible on $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review page not visible: $target_window"
        return 3
    fi

    if control_permissions_auto_review_current "$content"; then
        tmux send-keys -t "$target" Escape 2>/dev/null || true
        echo "Auto-review already current on $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review already current: $target_window"
        return 0
    fi

    if ! control_permissions_needs_auto_review "$content"; then
        tmux send-keys -t "$target" Escape 2>/dev/null || true
        echo "Auto-review row not visible on $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review row missing: $target_window"
        return 1
    fi

    if ! control_permissions_select_auto_review "$target"; then
        echo "failed to select Auto-review on $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review select failed: $target_window"
        return 1
    fi

    sleep "$CONTROL_SUBMIT_DELAY" 2>/dev/null || true
    tmux send-keys -t "$target" Escape 2>/dev/null || true

    echo "selected Auto-review on $target_window"
    AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review selected: $target_window"
}

control_wait_set_auto_review() {
    local session="$1" audit_log="$2" target_window="${3:-agent-1}"
    local attempts="${4:-$CONTROL_PERMISSIONS_STARTUP_ATTEMPTS}"
    local delay="${5:-$CONTROL_PERMISSIONS_STARTUP_DELAY}"
    local target="${session}:${target_window}"
    local attempt content rc

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup target missing: $target_window"
        return 1
    fi

    AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup waiting: $target_window"

    for (( attempt=1; attempt<=attempts; attempt++ )); do
        content="$(control_capture_target "$target" 2>/dev/null)" || content=""

        if control_codex_welcome_continue_visible "$content"; then
            AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup continuing welcome: $target_window attempt=$attempt"
            tmux send-keys -t "$target" Enter 2>/dev/null || {
                echo "failed to continue Codex welcome on $target_window"
                AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup welcome continue failed: $target_window"
                return 1
            }
            sleep "$delay" 2>/dev/null || true
            continue
        fi

        if control_permissions_page_visible "$content" || control_codex_tui_visible "$content"; then
            AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup ready: $target_window attempt=$attempt"
            control_set_auto_review "$session" "$audit_log" "$target_window"
            rc=$?
            if (( rc == 2 )); then
                AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup busy: $target_window attempt=$attempt"
                sleep "$CONTROL_PERMISSIONS_BUSY_RETRY_DELAY" 2>/dev/null || true
                continue
            fi
            if (( rc == 3 )); then
                AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup page not ready: $target_window attempt=$attempt"
                sleep "$delay" 2>/dev/null || true
                continue
            fi
            return "$rc"
        fi

        sleep "$delay" 2>/dev/null || true
    done

    echo "Codex TUI not visible on $target_window"
    AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup timed out: $target_window"
    return 1
}

control_send_prompt() {
    local session="$1" audit_log="$2" target_window="$3" prompt="$4" loop_id="${5:-manual}"
    local target="${session}:${target_window}"
    local preview

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id target missing: $target_window"
        return 1
    fi

    if tmux send-keys -t "$target" -l "$prompt" 2>/dev/null; then
        # Codex's TUI can classify a burst of text plus immediate Enter as paste
        # input. A short pause makes the Enter arrive as a submit key.
        sleep "$CONTROL_SUBMIT_DELAY" 2>/dev/null || true
        tmux send-keys -t "$target" Enter 2>/dev/null || {
            echo "failed to submit prompt to $target_window"
            AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id submit failed: $target_window"
            return 1
        }
        preview="$(control_preview "$prompt")"
        AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id sent to $target_window: $preview"
        return 0
    fi

    echo "failed to send prompt to $target_window"
    AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id send failed: $target_window"
    return 1
}

control_send_plan_command() {
    local session="$1" audit_log="$2" target_window="$3" command="$4"
    local audit_prefix="${5:-PLAN}"
    local target="${session}:${target_window}"
    local preview

    if tmux send-keys -t "$target" -l "$command" 2>/dev/null; then
        sleep "$CONTROL_SUBMIT_DELAY" 2>/dev/null || true
        tmux send-keys -t "$target" Enter 2>/dev/null || {
            echo "failed to submit /plan to $target_window"
            AUDIT_LOG="$audit_log" control_audit "$audit_prefix submit failed: $target_window"
            return 1
        }

        preview="$(control_preview "$command")"
        AUDIT_LOG="$audit_log" control_audit "$audit_prefix sent to $target_window: $preview"
        return 0
    fi

    echo "failed to send /plan to $target_window"
    AUDIT_LOG="$audit_log" control_audit "$audit_prefix send failed: $target_window"
    return 1
}

control_send_plan_with_approval() {
    local session="$1" audit_log="$2" target_window="$3" command="$4"
    local audit_prefix="${5:-PLAN}"

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "$audit_prefix target missing: $target_window"
        return 1
    fi

    if ! AUDIT_LOG="$audit_log" control_arm_plan_approval "$session" "$target_window"; then
        echo "failed to arm plan approval for $target_window"
        AUDIT_LOG="$audit_log" control_audit "$audit_prefix approval arm failed: $target_window"
        return 1
    fi

    if ! control_send_plan_command "$session" "$audit_log" "$target_window" "$command" "$audit_prefix"; then
        AUDIT_LOG="$audit_log" control_disarm_plan_approval
        return 1
    fi

    return 0
}

control_send_loop_plan() {
    local session="$1" audit_log="$2" target_window="$3" command="$4" loop_id="${5:-manual}"
    control_send_plan_with_approval "$session" "$audit_log" "$target_window" "$command" "LOOP #$loop_id plan"
}

control_loop_worker() {
    local session="$1" audit_log="$2" loop_id="$3" seconds="$4" interval="$5" target_window="$6" prompt="$7" loop_type="${8:-prompt}"

    AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id worker started: every $interval to $target_window"

    while tmux has-session -t "$session" 2>/dev/null; do
        if [[ "$loop_type" == "plan" ]]; then
            control_send_loop_plan "$session" "$audit_log" "$target_window" "$prompt" "$loop_id" >/dev/null || true
        else
            control_send_prompt "$session" "$audit_log" "$target_window" "$prompt" "$loop_id" >/dev/null || true
        fi
        sleep "$seconds" || break
    done

    AUDIT_LOG="$audit_log" control_audit "LOOP #$loop_id worker stopped"
}

control_start_loop() {
    local interval="$1" seconds="$2" prompt="$3"
    local target_window="agent-1"
    local loop_id pid preview loop_type="prompt"

    if [[ "$SESSION_MODE" == "worktree" ]]; then
        echo "/loop is disabled in worktree mode because agent windows run codex exec and may exit."
        control_audit "LOOP rejected in worktree mode"
        return 1
    fi

    if ! control_agent_exists "$SESSION_NAME" "$target_window"; then
        echo "agent target not found: $target_window"
        control_audit "LOOP rejected; target missing: $target_window"
        return 1
    fi

    if control_is_plan_command "$prompt"; then
        loop_type="plan"
    fi

    loop_id="$NEXT_LOOP_ID"
    NEXT_LOOP_ID=$((NEXT_LOOP_ID + 1))

    control_loop_worker "$SESSION_NAME" "$AUDIT_LOG" "$loop_id" "$seconds" "$interval" "$target_window" "$prompt" "$loop_type" &
    pid=$!

    LOOP_PIDS["$loop_id"]="$pid"
    LOOP_INTERVALS["$loop_id"]="$interval"
    LOOP_SECONDS["$loop_id"]="$seconds"
    LOOP_PROMPTS["$loop_id"]="$prompt"
    LOOP_TARGETS["$loop_id"]="$target_window"
    LOOP_TYPES["$loop_id"]="$loop_type"

    preview="$(control_preview "$prompt")"
    echo "scheduled loop #$loop_id every $interval to $target_window: $preview"
    if [[ "$loop_type" == "plan" ]]; then
        control_audit "LOOP #$loop_id scheduled (plan): every $interval to $target_window: $preview"
    else
        control_audit "LOOP #$loop_id scheduled: every $interval to $target_window: $preview"
    fi
}

control_start_plan() {
    local prompt="${1:-}"
    local target_window="agent-1"
    local command="/plan"
    local preview

    if [[ "$SESSION_MODE" == "worktree" ]]; then
        echo "/plan is disabled in worktree mode because agent windows run codex exec and may exit."
        control_audit "PLAN rejected in worktree mode"
        return 1
    fi

    if ! control_agent_exists "$SESSION_NAME" "$target_window"; then
        echo "agent target not found: $target_window"
        control_audit "PLAN rejected; target missing: $target_window"
        return 1
    fi

    if [[ -n "$prompt" ]]; then
        command="/plan $prompt"
    fi

    if ! control_send_plan_with_approval "$SESSION_NAME" "$AUDIT_LOG" "$target_window" "$command" "PLAN"; then
        return 1
    fi

    preview="$(control_preview "$command")"
    echo "sent $preview to $target_window"
}

control_cancel_loop() {
    local loop_id="$1"
    local pid="${LOOP_PIDS[$loop_id]:-}"

    if [[ -z "$pid" ]]; then
        echo "no active loop with id: $loop_id"
        return 1
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    unset "LOOP_PIDS[$loop_id]"
    unset "LOOP_INTERVALS[$loop_id]"
    unset "LOOP_SECONDS[$loop_id]"
    unset "LOOP_PROMPTS[$loop_id]"
    unset "LOOP_TARGETS[$loop_id]"
    unset "LOOP_TYPES[$loop_id]"

    echo "canceled loop #$loop_id"
    control_audit "LOOP #$loop_id canceled"
}

control_list_loops() {
    local found=0
    local id pid preview

    for (( id=1; id<NEXT_LOOP_ID; id++ )); do
        pid="${LOOP_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            unset "LOOP_PIDS[$id]"
            unset "LOOP_INTERVALS[$id]"
            unset "LOOP_SECONDS[$id]"
            unset "LOOP_PROMPTS[$id]"
            unset "LOOP_TARGETS[$id]"
            unset "LOOP_TYPES[$id]"
            continue
        fi

        found=1
        preview="$(control_preview "${LOOP_PROMPTS[$id]}")"
        printf '#%s every %s to %s: %s\n' "$id" "${LOOP_INTERVALS[$id]}" "${LOOP_TARGETS[$id]}" "$preview"
    done

    if (( ! found )); then
        echo "no active loops"
    fi
}

control_print_help() {
    cat <<'EOF'
Available commands:
  /permissions auto-review     Make Auto-review current for agent-1
  /plan [prompt]               Send /plan to agent-1 with scoped auto-approval
  /loop <interval> <prompt>     Schedule a prompt for agent-1. Intervals: 30s, 15m, 1h, 1d
  /loop <interval> /plan <prompt>
                                Schedule /plan with scoped auto-approval
  /loops                        List active loops
  /loops cancel <id>            Cancel a loop
  /help                         Show this help
EOF
}

control_handle_command() {
    local line="$1"
    local parsed interval seconds prompt rest loop_id

    line="$(control_ltrim "$line")"
    [[ -n "$line" ]] || return 0

    case "$line" in
        /help)
            control_print_help
            ;;
        /loops)
            control_list_loops
            ;;
        /loops\ cancel\ *)
            rest="${line#/loops cancel }"
            rest="$(control_ltrim "$rest")"
            if [[ "$rest" =~ ^([0-9]+)[[:space:]]*$ ]]; then
                loop_id="${BASH_REMATCH[1]}"
                control_cancel_loop "$loop_id"
            else
                echo "usage: /loops cancel <id>"
            fi
            ;;
        /loops*)
            echo "usage: /loops or /loops cancel <id>"
            ;;
        /permissions\ auto-review)
            control_set_auto_review "$SESSION_NAME" "$AUDIT_LOG" "agent-1"
            ;;
        /permissions*)
            echo "usage: /permissions auto-review"
            ;;
        /plan|/plan\ *|$'/plan\t'*)
            rest="${line#/plan}"
            rest="$(control_ltrim "$rest")"
            rest="$(control_collect_plan_prompt "$rest")"
            control_start_plan "$rest"
            ;;
        /loop*)
            if parsed="$(control_parse_loop_command "$line")"; then
                interval="${parsed%%$'\t'*}"
                rest="${parsed#*$'\t'}"
                seconds="${rest%%$'\t'*}"
                prompt="${rest#*$'\t'}"
                control_start_loop "$interval" "$seconds" "$prompt"
            else
                echo "usage: /loop <interval> <prompt>"
            fi
            ;;
        /*)
            echo "unknown command: $line"
            echo "type /help for available commands"
            ;;
        *)
            echo "control accepts slash commands only; type /help"
            ;;
    esac
}

control_cleanup() {
    local id pid

    if [[ -n "${TAIL_PID:-}" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=""
    fi

    for id in "${!LOOP_PIDS[@]}"; do
        pid="${LOOP_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

control_main() {
    local line

    if [[ -z "$SESSION_NAME" || -z "$AUDIT_LOG" ]]; then
        echo "usage: control-pane.sh <session> <audit-log> [standard|worktree]" >&2
        exit 1
    fi

    : >> "$AUDIT_LOG" 2>/dev/null || true

    trap control_cleanup EXIT
    trap 'control_cleanup; exit 0' INT TERM
    control_audit "control pane started (mode=$SESSION_MODE)"

    tail -n 40 -f "$AUDIT_LOG" &
    TAIL_PID=$!

    echo ""
    echo "codex-yolo control ready. Type /help for commands."

    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        printf 'codex-yolo> '
        if ! IFS= read -r line; then
            break
        fi
        control_handle_command "$line"
    done

    control_audit "control pane stopped"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "$SESSION_MODE" == "auto-review-once" ]]; then
        control_wait_set_auto_review "$SESSION_NAME" "$AUDIT_LOG" "agent-1"
        exit $?
    fi
    control_main "$@"
fi
