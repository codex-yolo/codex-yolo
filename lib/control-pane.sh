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
declare -A LOOP_QUEUE_IDS=()
declare -A QUEUE_PIDS=()
declare -A QUEUE_INTERVALS=()
declare -A QUEUE_SECONDS=()
declare -A QUEUE_TARGETS=()
declare -A QUEUE_TYPES=()
declare -A QUEUE_STATE_DIRS=()
declare -A QUEUE_LOOP_IDS=()
NEXT_LOOP_ID=1
NEXT_QUEUE_ID=1
TAIL_PID=""
CONTROL_SUBMIT_DELAY="${CODEX_YOLO_CONTROL_SUBMIT_DELAY:-0.2}"
CONTROL_PERMISSIONS_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_DELAY:-0.5}"
CONTROL_PERMISSIONS_OPEN_ATTEMPTS="${CODEX_YOLO_CONTROL_PERMISSIONS_OPEN_ATTEMPTS:-10}"
CONTROL_PERMISSIONS_BUSY_RETRY_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_BUSY_RETRY_DELAY:-2}"
CONTROL_PERMISSIONS_STARTUP_ATTEMPTS="${CODEX_YOLO_CONTROL_PERMISSIONS_STARTUP_ATTEMPTS:-1200}"
CONTROL_PERMISSIONS_STARTUP_DELAY="${CODEX_YOLO_CONTROL_PERMISSIONS_STARTUP_DELAY:-0.5}"
CONTROL_PERMISSIONS_AUTO_REVIEW_RESET_STEPS="${CODEX_YOLO_CONTROL_PERMISSIONS_AUTO_REVIEW_RESET_STEPS:-6}"
CONTROL_PLAN_PASTE_GRACE="${CODEX_YOLO_CONTROL_PLAN_PASTE_GRACE:-0.5}"
CONTROL_MULTILINE_PASTE_DELAY="${CODEX_YOLO_CONTROL_MULTILINE_PASTE_DELAY:-0.8}"
CONTROL_QUEUE_WAIT_DELAY="${CODEX_YOLO_CONTROL_QUEUE_WAIT_DELAY:-1}"
CONTROL_QUEUE_POST_SEND_GRACE="${CODEX_YOLO_CONTROL_QUEUE_POST_SEND_GRACE:-0.5}"
CONTROL_QUEUE_LOCK_DELAY="${CODEX_YOLO_CONTROL_QUEUE_LOCK_DELAY:-0.05}"
CONTROL_QUEUE_PARSED_ITEMS=()

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

control_rtrim() {
    local value="$1"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

control_trim() {
    local value="$1"
    value="$(control_ltrim "$value")"
    control_rtrim "$value"
}

control_normalize_line_endings() {
    local value="$1"
    value="${value//$'\r\n'/$'\n'}"
    value="${value//$'\r'/$'\n'}"
    printf '%s' "$value"
}

control_preview() {
    local value="$1"
    value="$(control_normalize_line_endings "$value")"
    if (( ${#value} > 80 )); then
        printf '%s...' "${value:0:77}"
    else
        printf '%s' "$value"
    fi
}

control_queue_skip_space() {
    local text="$1" pos="$2" len="${#1}" ch

    while (( pos < len )); do
        ch="${text:pos:1}"
        case "$ch" in
            $' '|$'\t'|$'\r'|$'\n') pos=$((pos + 1)) ;;
            *) break ;;
        esac
    done

    printf '%s\n' "$pos"
}

control_parse_queue_string() {
    local text="$1" pos="$2" len="${#1}" quote triple item="" ch

    (( pos < len )) || return 1
    quote="${text:pos:1}"
    [[ "$quote" == "'" || "$quote" == '"' ]] || return 1

    if [[ "${text:pos:3}" == "$quote$quote$quote" ]]; then
        triple=1
        pos=$((pos + 3))
        while (( pos < len )); do
            if [[ "${text:pos:3}" == "$quote$quote$quote" ]]; then
                pos=$((pos + 3))
                [[ -n "$item" ]] || return 1
                CONTROL_QUEUE_PARSED_ITEM="$item"
                CONTROL_QUEUE_PARSED_POS="$pos"
                return 0
            fi
            item+="${text:pos:1}"
            pos=$((pos + 1))
        done
        return 1
    fi

    pos=$((pos + 1))
    while (( pos < len )); do
        ch="${text:pos:1}"
        if [[ "$ch" == "$quote" ]]; then
            pos=$((pos + 1))
            [[ -n "$item" ]] || return 1
            CONTROL_QUEUE_PARSED_ITEM="$item"
            CONTROL_QUEUE_PARSED_POS="$pos"
            return 0
        fi
        [[ "$ch" == $'\n' || "$ch" == $'\r' ]] && return 1
        item+="$ch"
        pos=$((pos + 1))
    done

    return 1
}

control_parse_queue_items() {
    local text="$1" pos=0 len="${#1}" ch item

    CONTROL_QUEUE_PARSED_ITEMS=()
    text="$(control_normalize_line_endings "$text")"
    text="$(control_trim "$text")"
    len="${#text}"
    (( len > 0 )) || return 1

    pos="$(control_queue_skip_space "$text" "$pos")"
    [[ "${text:pos:1}" == "[" ]] || return 1
    pos=$((pos + 1))

    while true; do
        pos="$(control_queue_skip_space "$text" "$pos")"
        (( pos < len )) || return 1
        ch="${text:pos:1}"

        [[ "$ch" == "]" && "${#CONTROL_QUEUE_PARSED_ITEMS[@]}" -eq 0 ]] && return 1
        [[ "$ch" == "]" ]] && {
            pos=$((pos + 1))
            pos="$(control_queue_skip_space "$text" "$pos")"
            (( pos == len )) || return 1
            return 0
        }

        control_parse_queue_string "$text" "$pos" || return 1
        item="$CONTROL_QUEUE_PARSED_ITEM"
        pos="$CONTROL_QUEUE_PARSED_POS"
        CONTROL_QUEUE_PARSED_ITEMS+=("$item")

        pos="$(control_queue_skip_space "$text" "$pos")"
        (( pos < len )) || return 1
        ch="${text:pos:1}"
        if [[ "$ch" == "," ]]; then
            pos=$((pos + 1))
            local next_pos
            next_pos="$(control_queue_skip_space "$text" "$pos")"
            [[ "${text:next_pos:1}" == "]" ]] && return 1
            continue
        fi
        if [[ "$ch" == "]" ]]; then
            pos=$((pos + 1))
            pos="$(control_queue_skip_space "$text" "$pos")"
            (( pos == len )) || return 1
            return 0
        fi
        return 1
    done
}

control_queue_array_needs_more() {
    local text="$1" pos=0 len ch quote in_string=0 triple=0

    text="$(control_normalize_line_endings "$text")"
    text="$(control_ltrim "$text")"
    len="${#text}"
    (( len > 0 )) || return 1
    [[ "${text:0:1}" == "[" ]] || return 1

    pos=1
    while (( pos < len )); do
        ch="${text:pos:1}"

        if (( in_string )); then
            if (( triple )); then
                if [[ "${text:pos:3}" == "$quote$quote$quote" ]]; then
                    pos=$((pos + 3))
                    in_string=0
                    triple=0
                    continue
                fi
            elif [[ "$ch" == "$quote" ]]; then
                pos=$((pos + 1))
                in_string=0
                continue
            fi
            pos=$((pos + 1))
            continue
        fi

        case "$ch" in
            "'"|'"')
                quote="$ch"
                if [[ "${text:pos:3}" == "$quote$quote$quote" ]]; then
                    triple=1
                    pos=$((pos + 3))
                else
                    triple=0
                    pos=$((pos + 1))
                fi
                in_string=1
                ;;
            "]")
                return 1
                ;;
            *)
                pos=$((pos + 1))
                ;;
        esac
    done

    return 0
}

control_read_continuation_line() {
    local __line_var="$1" prompt="${2:-codex-yolo...> }"
    local __line_value

    if [[ -t 0 ]]; then
        if ! IFS= read -e -r -p "$prompt" __line_value; then
            return 1
        fi
    else
        if ! IFS= read -r __line_value; then
            return 1
        fi
    fi

    printf -v "$__line_var" '%s' "$__line_value"
}

control_collect_queue_array_payload() {
    local payload="$1" line

    payload="$(control_collect_queue_payload "$payload")"
    payload="$(control_normalize_line_endings "$payload")"
    while control_queue_array_needs_more "$payload"; do
        if ! control_read_continuation_line line "codex-yolo queue> "; then
            break
        fi
        line="$(control_normalize_line_endings "$line")"
        payload+=$'\n'"$line"
        payload="$(control_normalize_line_endings "$payload")"
    done

    printf '%s' "$payload"
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

    line="$(control_normalize_line_endings "$line")"
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

    prompt="$(control_normalize_line_endings "$prompt")"

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
        chunk="$(control_normalize_line_endings "$chunk")"
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

control_collect_loop_prompt() {
    control_collect_plan_prompt "$1"
}

control_read_line() {
    local __line_var="$1"
    local __line_value

    if [[ -t 0 ]]; then
        if ! IFS= read -e -r -p "codex-yolo> " __line_value; then
            return 1
        fi
        __line_value="$(control_normalize_line_endings "$__line_value")"
        if [[ -n "$__line_value" ]]; then
            history -s "$__line_value" 2>/dev/null || true
        fi
    else
        printf 'codex-yolo> '
        if ! IFS= read -r __line_value; then
            return 1
        fi
        __line_value="$(control_normalize_line_endings "$__line_value")"
    fi

    printf -v "$__line_var" '%s' "$__line_value"
}

control_is_plan_command() {
    local command="$1"
    command="$(control_normalize_line_endings "$command")"
    [[ "$command" == "/plan" || "$command" =~ ^/plan[[:space:]] ]]
}

control_agent_exists() {
    local session="$1" target_window="$2"
    tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$target_window"
}

control_send_text_to_target() {
    local target="$1" text="$2"
    local buffer

    text="$(control_normalize_line_endings "$text")"

    if [[ "$text" != *$'\n'* ]]; then
        tmux send-keys -t "$target" -l "$text" 2>/dev/null
        return
    fi

    buffer="codex-yolo-paste-$$-$RANDOM"
    if ! printf '%s' "$text" | tmux load-buffer -b "$buffer" - 2>/dev/null; then
        return 1
    fi

    if ! tmux paste-buffer -dpr -b "$buffer" -t "$target" 2>/dev/null; then
        tmux delete-buffer -b "$buffer" 2>/dev/null || true
        return 1
    fi
}

control_delay_after_text_send() {
    local text="$1"

    text="$(control_normalize_line_endings "$text")"

    if [[ "$text" == *$'\n'* ]]; then
        sleep "$CONTROL_MULTILINE_PASTE_DELAY" 2>/dev/null || true
    else
        sleep "$CONTROL_SUBMIT_DELAY" 2>/dev/null || true
    fi
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

control_codex_sign_in_visible() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 30)"
    [[ "$tail_content" == *"Sign in with ChatGPT"* && "$tail_content" == *"Provide your own API key"* ]] || \
    [[ "$tail_content" == *"Sign in with Device Code"* && "$tail_content" == *"Provide your own API key"* ]]
}

control_codex_welcome_continue_visible() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 30)"
    [[ "$tail_content" == *"Welcome to Codex"* && "$tail_content" == *"Press enter to continue"* ]] || return 1
    ! control_codex_sign_in_visible "$tail_content"
}

control_capture_target() {
    local target="$1"
    tmux capture-pane -p -t "$target" -S -100 2>/dev/null
}

control_plan_marker_file() {
    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.plan-approval\n' "$AUDIT_LOG"
}

control_slash_marker_file() {
    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.slash-approval\n' "$AUDIT_LOG"
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

control_arm_slash_approval() {
    local session="$1" target_window="$2"
    local marker pane_id now

    marker="$(control_slash_marker_file)" || return 1
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

control_disarm_slash_approval() {
    local marker
    marker="$(control_slash_marker_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

control_codex_prompt_line_visible() {
    local content="$1" line

    while IFS= read -r line; do
        line="$(control_ltrim "$line")"
        case "$line" in
            ">"|"> "*|"›"|"› "*) return 0 ;;
        esac
    done <<< "$content"

    return 1
}

control_codex_idle_visible() {
    local content="$1"
    local tail_content last_nonempty footer_re busy_re

    tail_content="$(echo "$content" | tail -n 20)"
    busy_re='(Codex is working|esc to interrupt|disabled while a task is in progress|Would you like to|Approve app tool call|Question[[:space:]]+[0-9]+/[0-9]+|^[[:space:]]*◦[[:space:]]*(Working|Running|Exploring|Reading|Editing|Searching|Thinking)([[:space:]]|$|\())'
    if echo "$tail_content" | grep -qiE "$busy_re"; then
        return 1
    fi

    last_nonempty="$(printf '%s\n' "$tail_content" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    [[ "$last_nonempty" == "READY" ]] && return 0
    [[ "$last_nonempty" =~ (^|[[:space:]])Ready([[:space:]]|$) ]] && return 0
    control_codex_prompt_line_visible "$last_nonempty" && return 0

    footer_re='^[[:space:]]*[^[:space:]].*·.*Context[[:space:]][0-9]+%[[:space:]]+(left|used)'
    [[ "$last_nonempty" =~ $footer_re ]] && control_codex_prompt_line_visible "$tail_content" && return 0

    return 1
}

control_wait_for_agent_idle() {
    local session="$1" audit_log="$2" target_window="$3" queue_id="$4" item_index="$5"
    local target="${session}:${target_window}"
    local content delay

    sleep "$CONTROL_QUEUE_POST_SEND_GRACE" 2>/dev/null || true
    delay="$CONTROL_QUEUE_WAIT_DELAY"
    [[ "$delay" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || delay=1

    AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index waiting for idle: $target_window"
    while tmux has-session -t "$session" 2>/dev/null; do
        content="$(control_capture_target "$target" 2>/dev/null)" || content=""
        if control_codex_idle_visible "$content"; then
            AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index completed: $target_window"
            return 0
        fi
        sleep "$delay" 2>/dev/null || true
    done

    AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index wait stopped; session missing"
    return 1
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
    local attempt content rc sign_in_logged=0

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup target missing: $target_window"
        return 1
    fi

    AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup waiting: $target_window"

    for (( attempt=1; attempt<=attempts; attempt++ )); do
        content="$(control_capture_target "$target" 2>/dev/null)" || content=""

        if control_codex_sign_in_visible "$content"; then
            if (( ! sign_in_logged )); then
                echo "Codex sign-in required on $target_window; waiting for manual sign-in"
                AUDIT_LOG="$audit_log" control_audit "PERMISSIONS auto-review startup sign-in required: $target_window attempt=$attempt"
                sign_in_logged=1
            fi
            sleep "$delay" 2>/dev/null || true
            continue
        fi

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

    if control_send_text_to_target "$target" "$prompt"; then
        # Codex's TUI can classify a burst of text plus immediate Enter as paste
        # input. A short pause makes the Enter arrive as a submit key.
        control_delay_after_text_send "$prompt"
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

    if control_send_text_to_target "$target" "$command"; then
        control_delay_after_text_send "$command"
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

control_send_queue_prompt() {
    local session="$1" audit_log="$2" target_window="$3" prompt="$4" queue_id="$5" item_index="$6"
    local target="${session}:${target_window}"
    local preview

    if ! control_agent_exists "$session" "$target_window"; then
        echo "agent target not found: $target_window"
        AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index target missing: $target_window"
        return 1
    fi

    if control_send_text_to_target "$target" "$prompt"; then
        control_delay_after_text_send "$prompt"
        tmux send-keys -t "$target" Enter 2>/dev/null || {
            echo "failed to submit queue item to $target_window"
            AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index submit failed: $target_window"
            return 1
        }
        preview="$(control_preview "$prompt")"
        AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index sent to $target_window: $preview"
        return 0
    fi

    echo "failed to send queue item to $target_window"
    AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index send failed: $target_window"
    return 1
}

control_send_slash_with_approval() {
    local session="$1" audit_log="$2" target_window="$3" command="$4" queue_id="$5" item_index="$6"

    if ! AUDIT_LOG="$audit_log" control_arm_slash_approval "$session" "$target_window"; then
        echo "failed to arm slash approval for $target_window"
        AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $item_index slash approval arm failed: $target_window"
        return 1
    fi

    if ! control_send_queue_prompt "$session" "$audit_log" "$target_window" "$command" "$queue_id" "$item_index"; then
        AUDIT_LOG="$audit_log" control_disarm_slash_approval
        return 1
    fi

    return 0
}

control_send_queue_item() {
    local session="$1" audit_log="$2" target_window="$3" item="$4" queue_id="$5" item_index="$6"

    item="$(control_normalize_line_endings "$item")"

    if control_is_plan_command "$item"; then
        control_send_plan_with_approval "$session" "$audit_log" "$target_window" "$item" "QUEUE #$queue_id item $item_index plan"
    elif [[ "$item" == /* ]]; then
        control_send_slash_with_approval "$session" "$audit_log" "$target_window" "$item" "$queue_id" "$item_index"
    else
        control_send_queue_prompt "$session" "$audit_log" "$target_window" "$item" "$queue_id" "$item_index"
    fi
}

control_is_queue_command() {
    local command="$1"
    command="$(control_normalize_line_endings "$command")"
    [[ "$command" == "/queue" || "$command" =~ ^/queue[[:space:]] ]]
}

control_collect_queue_payload() {
    control_collect_plan_prompt "$1"
}

control_queue_safe_name() {
    local value="$1"
    value="${value//[^A-Za-z0-9_.-]/_}"
    printf '%s' "$value"
}

control_queue_lock() {
    local state_dir="$1" lock_dir="$state_dir/.lock"
    local delay="$CONTROL_QUEUE_LOCK_DELAY"

    [[ "$delay" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || delay=0.05
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep "$delay" 2>/dev/null || true
    done
}

control_queue_unlock() {
    local state_dir="$1"
    rmdir "$state_dir/.lock" 2>/dev/null || true
}

control_queue_next_item_id() {
    local state_dir="$1" next_id
    next_id="$(cat "$state_dir/next_id" 2>/dev/null || printf '1')"
    [[ "$next_id" =~ ^[1-9][0-9]*$ ]] || next_id=1
    printf '%s\n' "$next_id"
    printf '%s\n' "$((next_id + 1))" > "$state_dir/next_id" 2>/dev/null || true
}

control_queue_append_item_unlocked() {
    local state_dir="$1" item="$2" item_id

    item_id="$(control_queue_next_item_id "$state_dir")" || return 1
    printf '%s' "$item" > "$state_dir/items/$item_id" || return 1
    printf '%s\n' "$item_id" >> "$state_dir/order" || return 1
}

control_queue_init_state() {
    local state_dir="$1" array_name="$2"
    local -n items_ref="$array_name"
    local item

    mkdir -p "$state_dir/items" || return 1
    : > "$state_dir/order" || return 1
    printf '1\n' > "$state_dir/next_id" || return 1
    printf 'pending\n' > "$state_dir/status" || return 1
    printf '1\n' > "$state_dir/next_pos" || return 1
    : > "$state_dir/current_id" || return 1
    : > "$state_dir/current_pos" || return 1

    for item in "${items_ref[@]}"; do
        control_queue_append_item_unlocked "$state_dir" "$item" || return 1
    done
}

control_queue_read_order() {
    local state_dir="$1" array_name="$2"
    local -n order_ref="$array_name"

    order_ref=()
    [[ -f "$state_dir/order" ]] || return 1
    mapfile -t order_ref < "$state_dir/order"
}

control_queue_write_order() {
    local state_dir="$1" array_name="$2"
    local -n order_ref="$array_name"
    local item_id

    : > "$state_dir/order" || return 1
    for item_id in "${order_ref[@]}"; do
        printf '%s\n' "$item_id" >> "$state_dir/order" || return 1
    done
}

control_queue_pending_index_allowed_unlocked() {
    local state_dir="$1" index="$2"
    local next_pos current_pos status

    [[ "$index" =~ ^[1-9][0-9]*$ ]] || return 1
    status="$(cat "$state_dir/status" 2>/dev/null || printf 'pending')"
    next_pos="$(cat "$state_dir/next_pos" 2>/dev/null || printf '1')"
    current_pos="$(cat "$state_dir/current_pos" 2>/dev/null || true)"
    [[ "$next_pos" =~ ^[1-9][0-9]*$ ]] || next_pos=1
    [[ "$current_pos" =~ ^[1-9][0-9]*$ ]] || current_pos=0

    [[ "$status" == "done" ]] && return 1
    (( current_pos > 0 && index == current_pos )) && return 1
    (( index >= next_pos ))
}

control_queue_get_state_dir() {
    local queue_id="$1"
    local state_dir="${QUEUE_STATE_DIRS[$queue_id]:-}"
    local pid="${QUEUE_PIDS[$queue_id]:-}"

    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -n "$state_dir" && -d "$state_dir" ]] || return 1
    printf '%s\n' "$state_dir"
}

control_queue_add_items() {
    local queue_id="$1" array_name="$2"
    local -n items_ref="$array_name"
    local state_dir item

    state_dir="$(control_queue_get_state_dir "$queue_id")" || {
        echo "no active queue with id: $queue_id"
        return 1
    }

    control_queue_lock "$state_dir"
    for item in "${items_ref[@]}"; do
        control_queue_append_item_unlocked "$state_dir" "$item" || {
            control_queue_unlock "$state_dir"
            return 1
        }
    done
    control_queue_unlock "$state_dir"

    echo "added ${#items_ref[@]} item(s) to queue #$queue_id"
    control_audit "QUEUE #$queue_id added ${#items_ref[@]} item(s)"
}

control_queue_remove_positions_unlocked() {
    local state_dir="$1" start="$2" end="$3"
    local ids=() new_ids=() i item_id total

    control_queue_read_order "$state_dir" ids || return 1
    total="${#ids[@]}"
    (( start >= 1 && end >= start && end <= total )) || return 1

    for (( i=start; i<=end; i++ )); do
        control_queue_pending_index_allowed_unlocked "$state_dir" "$i" || return 2
    done

    for (( i=1; i<=total; i++ )); do
        item_id="${ids[$((i - 1))]}"
        if (( i >= start && i <= end )); then
            rm -f "$state_dir/items/$item_id" 2>/dev/null || true
        else
            new_ids+=("$item_id")
        fi
    done

    control_queue_write_order "$state_dir" new_ids
}

control_queue_remove_items() {
    local queue_id="$1" spec="$2"
    local state_dir start end rc

    state_dir="$(control_queue_get_state_dir "$queue_id")" || {
        echo "no active queue with id: $queue_id"
        return 1
    }

    if [[ "$spec" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^[1-9][0-9]*$ ]]; then
        start="$spec"
        end="$spec"
    else
        echo "usage: /queue remove <id> <index-or-range>"
        return 1
    fi

    control_queue_lock "$state_dir"
    control_queue_remove_positions_unlocked "$state_dir" "$start" "$end"
    rc=$?
    control_queue_unlock "$state_dir"

    if (( rc == 2 )); then
        echo "cannot remove running or completed queue item(s)"
        return 1
    fi
    if (( rc != 0 )); then
        echo "queue item index out of range"
        return 1
    fi

    if [[ "$start" == "$end" ]]; then
        echo "removed item $start from queue #$queue_id"
    else
        echo "removed items $start-$end from queue #$queue_id"
    fi
    control_audit "QUEUE #$queue_id removed item(s) $start-$end"
}

control_queue_dequeue_item() {
    local queue_id="$1"
    local state_dir next_pos

    state_dir="$(control_queue_get_state_dir "$queue_id")" || {
        echo "no active queue with id: $queue_id"
        return 1
    }

    control_queue_lock "$state_dir"
    next_pos="$(cat "$state_dir/next_pos" 2>/dev/null || printf '1')"
    [[ "$next_pos" =~ ^[1-9][0-9]*$ ]] || next_pos=1
    control_queue_remove_positions_unlocked "$state_dir" "$next_pos" "$next_pos"
    local rc=$?
    control_queue_unlock "$state_dir"

    if (( rc == 2 )); then
        echo "cannot dequeue the currently running item"
        return 1
    fi
    if (( rc != 0 )); then
        echo "no pending items in queue #$queue_id"
        return 1
    fi

    echo "dequeued item $next_pos from queue #$queue_id"
    control_audit "QUEUE #$queue_id dequeued item $next_pos"
}

control_queue_edit_item() {
    local queue_id="$1" index="$2" item="$3"
    local state_dir ids=() item_id total

    [[ "$index" =~ ^[1-9][0-9]*$ ]] || {
        echo "usage: /queue edit <id> <index> [\"new item\"]"
        return 1
    }

    state_dir="$(control_queue_get_state_dir "$queue_id")" || {
        echo "no active queue with id: $queue_id"
        return 1
    }

    control_queue_lock "$state_dir"
    control_queue_read_order "$state_dir" ids || {
        control_queue_unlock "$state_dir"
        return 1
    }
    total="${#ids[@]}"
    if (( index < 1 || index > total )); then
        control_queue_unlock "$state_dir"
        echo "queue item index out of range"
        return 1
    fi
    if ! control_queue_pending_index_allowed_unlocked "$state_dir" "$index"; then
        control_queue_unlock "$state_dir"
        echo "cannot edit running or completed queue item"
        return 1
    fi

    item_id="${ids[$((index - 1))]}"
    printf '%s' "$item" > "$state_dir/items/$item_id" || {
        control_queue_unlock "$state_dir"
        return 1
    }
    control_queue_unlock "$state_dir"

    echo "edited item $index in queue #$queue_id"
    control_audit "QUEUE #$queue_id edited item $index"
}

control_queue_show() {
    local queue_id="$1"
    local state_dir ids=() item_id current_pos item preview i status next_pos

    state_dir="$(control_queue_get_state_dir "$queue_id")" || {
        echo "no active queue with id: $queue_id"
        return 1
    }

    control_queue_lock "$state_dir"
    control_queue_read_order "$state_dir" ids || {
        control_queue_unlock "$state_dir"
        return 1
    }
    current_pos="$(cat "$state_dir/current_pos" 2>/dev/null || true)"
    status="$(cat "$state_dir/status" 2>/dev/null || printf 'pending')"
    next_pos="$(cat "$state_dir/next_pos" 2>/dev/null || printf '1')"
    [[ "$current_pos" =~ ^[1-9][0-9]*$ ]] || current_pos=0
    [[ "$next_pos" =~ ^[1-9][0-9]*$ ]] || next_pos=1

    printf 'queue #%s status=%s next=%s\n' "$queue_id" "$status" "$next_pos"
    for (( i=1; i<=${#ids[@]}; i++ )); do
        item_id="${ids[$((i - 1))]}"
        item="$(cat "$state_dir/items/$item_id" 2>/dev/null || true)"
        preview="$(control_preview "$item")"
        if (( i == current_pos )); then
            printf '%s. [running] %s\n' "$i" "$preview"
        elif (( i < next_pos && status != "sleeping" )); then
            printf '%s. [done] %s\n' "$i" "$preview"
        else
            printf '%s. %s\n' "$i" "$preview"
        fi
    done
    control_queue_unlock "$state_dir"
}

control_prune_queues() {
    local id pid state_dir

    for id in "${!QUEUE_PIDS[@]}"; do
        pid="${QUEUE_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        state_dir="${QUEUE_STATE_DIRS[$id]:-}"
        [[ -n "$state_dir" ]] && rm -rf "$state_dir" 2>/dev/null || true
        if [[ -n "${QUEUE_LOOP_IDS[$id]:-}" ]]; then
            local loop_id="${QUEUE_LOOP_IDS[$id]}"
            unset "LOOP_PIDS[$loop_id]" "LOOP_INTERVALS[$loop_id]" "LOOP_SECONDS[$loop_id]" \
                "LOOP_PROMPTS[$loop_id]" "LOOP_TARGETS[$loop_id]" "LOOP_TYPES[$loop_id]" \
                "LOOP_QUEUE_IDS[$loop_id]"
        fi
        unset "QUEUE_PIDS[$id]" "QUEUE_INTERVALS[$id]" "QUEUE_SECONDS[$id]" \
            "QUEUE_TARGETS[$id]" "QUEUE_TYPES[$id]" "QUEUE_STATE_DIRS[$id]" \
            "QUEUE_LOOP_IDS[$id]"
    done
}

control_list_queues() {
    local found=0 id pid state_dir status next_pos current_pos count target interval

    control_prune_queues
    for (( id=1; id<NEXT_QUEUE_ID; id++ )); do
        pid="${QUEUE_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        state_dir="${QUEUE_STATE_DIRS[$id]:-}"
        [[ -n "$state_dir" && -d "$state_dir" ]] || continue
        status="$(cat "$state_dir/status" 2>/dev/null || printf 'unknown')"
        next_pos="$(cat "$state_dir/next_pos" 2>/dev/null || printf '?')"
        current_pos="$(cat "$state_dir/current_pos" 2>/dev/null || true)"
        count="$(wc -l < "$state_dir/order" 2>/dev/null || printf '0')"
        target="${QUEUE_TARGETS[$id]:-agent-1}"
        interval="${QUEUE_INTERVALS[$id]:-}"
        found=1
        if [[ -n "$interval" ]]; then
            printf '#%s loop every %s to %s: status=%s next=%s/%s current=%s\n' \
                "$id" "$interval" "$target" "$status" "$next_pos" "$count" "${current_pos:-none}"
        else
            printf '#%s once to %s: status=%s next=%s/%s current=%s\n' \
                "$id" "$target" "$status" "$next_pos" "$count" "${current_pos:-none}"
        fi
    done

    if (( ! found )); then
        echo "no active queues"
    fi
}

control_cancel_queue() {
    local queue_id="$1"
    local pid="${QUEUE_PIDS[$queue_id]:-}" state_dir loop_id

    if [[ -z "$pid" ]]; then
        echo "no active queue with id: $queue_id"
        return 1
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    state_dir="${QUEUE_STATE_DIRS[$queue_id]:-}"
    [[ -n "$state_dir" ]] && rm -rf "$state_dir" 2>/dev/null || true

    loop_id="${QUEUE_LOOP_IDS[$queue_id]:-}"
    if [[ -n "$loop_id" ]]; then
        unset "LOOP_PIDS[$loop_id]" "LOOP_INTERVALS[$loop_id]" "LOOP_SECONDS[$loop_id]" \
            "LOOP_PROMPTS[$loop_id]" "LOOP_TARGETS[$loop_id]" "LOOP_TYPES[$loop_id]" \
            "LOOP_QUEUE_IDS[$loop_id]"
    fi

    unset "QUEUE_PIDS[$queue_id]" "QUEUE_INTERVALS[$queue_id]" "QUEUE_SECONDS[$queue_id]" \
        "QUEUE_TARGETS[$queue_id]" "QUEUE_TYPES[$queue_id]" "QUEUE_STATE_DIRS[$queue_id]" \
        "QUEUE_LOOP_IDS[$queue_id]"

    echo "canceled queue #$queue_id"
    control_audit "QUEUE #$queue_id canceled"
}

control_queue_worker() {
    local session="$1" audit_log="$2" queue_id="$3" state_dir="$4" target_window="$5" seconds="$6" interval="$7" queue_type="$8"
    local ids=() next_pos item_id item current_index

    AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id worker started: type=$queue_type target=$target_window"

    while tmux has-session -t "$session" 2>/dev/null; do
        control_queue_lock "$state_dir"
        printf 'running\n' > "$state_dir/status" 2>/dev/null || true
        printf '1\n' > "$state_dir/next_pos" 2>/dev/null || true
        : > "$state_dir/current_id" 2>/dev/null || true
        : > "$state_dir/current_pos" 2>/dev/null || true
        control_queue_unlock "$state_dir"

        while tmux has-session -t "$session" 2>/dev/null; do
            control_queue_lock "$state_dir"
            control_queue_read_order "$state_dir" ids || ids=()
            next_pos="$(cat "$state_dir/next_pos" 2>/dev/null || printf '1')"
            [[ "$next_pos" =~ ^[1-9][0-9]*$ ]] || next_pos=1
            if (( next_pos > ${#ids[@]} )); then
                : > "$state_dir/current_id" 2>/dev/null || true
                : > "$state_dir/current_pos" 2>/dev/null || true
                control_queue_unlock "$state_dir"
                break
            fi

            item_id="${ids[$((next_pos - 1))]}"
            item="$(cat "$state_dir/items/$item_id" 2>/dev/null || true)"
            current_index="$next_pos"
            printf '%s\n' "$item_id" > "$state_dir/current_id" 2>/dev/null || true
            printf '%s\n' "$current_index" > "$state_dir/current_pos" 2>/dev/null || true
            printf '%s\n' "$((next_pos + 1))" > "$state_dir/next_pos" 2>/dev/null || true
            control_queue_unlock "$state_dir"

            if ! control_send_queue_item "$session" "$audit_log" "$target_window" "$item" "$queue_id" "$current_index" >/dev/null; then
                AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id item $current_index failed; queue stopped"
                break 2
            fi

            control_wait_for_agent_idle "$session" "$audit_log" "$target_window" "$queue_id" "$current_index" || break 2
            AUDIT_LOG="$audit_log" control_disarm_slash_approval

            control_queue_lock "$state_dir"
            : > "$state_dir/current_id" 2>/dev/null || true
            : > "$state_dir/current_pos" 2>/dev/null || true
            control_queue_unlock "$state_dir"
        done

        if [[ "$queue_type" != "loop" ]]; then
            break
        fi

        control_queue_lock "$state_dir"
        printf 'sleeping\n' > "$state_dir/status" 2>/dev/null || true
        printf '1\n' > "$state_dir/next_pos" 2>/dev/null || true
        : > "$state_dir/current_id" 2>/dev/null || true
        : > "$state_dir/current_pos" 2>/dev/null || true
        control_queue_unlock "$state_dir"
        sleep "$seconds" || break
    done

    control_queue_lock "$state_dir"
    printf 'done\n' > "$state_dir/status" 2>/dev/null || true
    : > "$state_dir/current_id" 2>/dev/null || true
    : > "$state_dir/current_pos" 2>/dev/null || true
    control_queue_unlock "$state_dir"
    AUDIT_LOG="$audit_log" control_disarm_slash_approval
    AUDIT_LOG="$audit_log" control_audit "QUEUE #$queue_id worker stopped"
}

control_start_queue() {
    local queue_type="$1" items_name="$2" interval="${3:-}" seconds="${4:-}" loop_id="${5:-}" display_prompt="${6:-}"
    local -n items_ref="$items_name"
    local target_window="agent-1"
    local queue_id pid state_dir safe_session

    if [[ "$SESSION_MODE" == "worktree" ]]; then
        echo "/queue is disabled in worktree mode because agent windows run codex exec and may exit."
        control_audit "QUEUE rejected in worktree mode"
        return 1
    fi

    if ! control_agent_exists "$SESSION_NAME" "$target_window"; then
        echo "agent target not found: $target_window"
        control_audit "QUEUE rejected; target missing: $target_window"
        return 1
    fi

    if [[ "$queue_type" == "loop" && -z "$loop_id" ]]; then
        loop_id="$NEXT_LOOP_ID"
        NEXT_LOOP_ID=$((NEXT_LOOP_ID + 1))
    fi

    queue_id="$NEXT_QUEUE_ID"
    NEXT_QUEUE_ID=$((NEXT_QUEUE_ID + 1))
    safe_session="$(control_queue_safe_name "${SESSION_NAME:-session}")"
    state_dir="$(mktemp -d "/tmp/codex-yolo-queue-${safe_session}-${queue_id}.XXXXXX")" || return 1

    if ! control_queue_init_state "$state_dir" "$items_name"; then
        rm -rf "$state_dir" 2>/dev/null || true
        return 1
    fi

    control_queue_worker "$SESSION_NAME" "$AUDIT_LOG" "$queue_id" "$state_dir" "$target_window" "$seconds" "$interval" "$queue_type" &
    pid=$!

    QUEUE_PIDS["$queue_id"]="$pid"
    QUEUE_INTERVALS["$queue_id"]="$interval"
    QUEUE_SECONDS["$queue_id"]="$seconds"
    QUEUE_TARGETS["$queue_id"]="$target_window"
    QUEUE_TYPES["$queue_id"]="$queue_type"
    QUEUE_STATE_DIRS["$queue_id"]="$state_dir"

    if [[ "$queue_type" == "loop" ]]; then
        [[ -n "$display_prompt" ]] || display_prompt="/queue (${#items_ref[@]} item(s))"
        QUEUE_LOOP_IDS["$queue_id"]="$loop_id"
        LOOP_PIDS["$loop_id"]="$pid"
        LOOP_INTERVALS["$loop_id"]="$interval"
        LOOP_SECONDS["$loop_id"]="$seconds"
        LOOP_PROMPTS["$loop_id"]="$display_prompt"
        LOOP_TARGETS["$loop_id"]="$target_window"
        LOOP_TYPES["$loop_id"]="queue"
        LOOP_QUEUE_IDS["$loop_id"]="$queue_id"

        echo "scheduled loop #$loop_id every $interval to $target_window: $display_prompt (${#items_ref[@]} queued item(s))"
        control_audit "LOOP #$loop_id scheduled (queue #$queue_id): every $interval to $target_window (${#items_ref[@]} item(s))"
        control_audit "QUEUE #$queue_id scheduled loop #$loop_id: every $interval to $target_window (${#items_ref[@]} item(s))"
    else
        echo "started queue #$queue_id to $target_window (${#items_ref[@]} item(s))"
        control_audit "QUEUE #$queue_id started: $target_window (${#items_ref[@]} item(s))"
    fi
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

    prompt="$(control_normalize_line_endings "$prompt")"

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

    if control_is_queue_command "$prompt"; then
        local queue_payload="${prompt#/queue}"
        queue_payload="$(control_ltrim "$queue_payload")"
        queue_payload="$(control_collect_queue_array_payload "$queue_payload")"
        if ! control_parse_queue_items "$queue_payload"; then
            echo "usage: /loop <interval> /queue [\"item1\", \"item2\"]"
            return 1
        fi
        control_start_queue "loop" CONTROL_QUEUE_PARSED_ITEMS "$interval" "$seconds" "" "$prompt"
        return
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

    prompt="$(control_normalize_line_endings "$prompt")"

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

control_handle_queue_command() {
    local rest="$1"
    local sub queue_id spec index payload

    rest="$(control_normalize_line_endings "$rest")"
    rest="$(control_ltrim "$rest")"

    if [[ "$rest" == \[* ]]; then
        rest="$(control_collect_queue_array_payload "$rest")"
        if ! control_parse_queue_items "$rest"; then
            echo "usage: /queue [\"item1\", \"item2\"]"
            return 1
        fi
        control_start_queue "once" CONTROL_QUEUE_PARSED_ITEMS
        return
    fi

    sub="${rest%%[[:space:]]*}"
    rest="${rest#"$sub"}"
    rest="$(control_ltrim "$rest")"

    case "$sub" in
        show)
            if [[ "$rest" =~ ^([0-9]+)[[:space:]]*$ ]]; then
                control_queue_show "${BASH_REMATCH[1]}"
            else
                echo "usage: /queue show <id>"
                return 1
            fi
            ;;
        cancel)
            if [[ "$rest" =~ ^([0-9]+)[[:space:]]*$ ]]; then
                control_cancel_queue "${BASH_REMATCH[1]}"
            else
                echo "usage: /queue cancel <id>"
                return 1
            fi
            ;;
        add|enqueue)
            queue_id="${rest%%[[:space:]]*}"
            payload="${rest#"$queue_id"}"
            payload="$(control_ltrim "$payload")"
            payload="$(control_collect_queue_array_payload "$payload")"
            if [[ ! "$queue_id" =~ ^[0-9]+$ ]] || ! control_parse_queue_items "$payload"; then
                echo "usage: /queue add <id> [\"item1\", \"item2\"]"
                return 1
            fi
            control_queue_add_items "$queue_id" CONTROL_QUEUE_PARSED_ITEMS
            ;;
        remove)
            queue_id="${rest%%[[:space:]]*}"
            spec="${rest#"$queue_id"}"
            spec="$(control_ltrim "$spec")"
            if [[ ! "$queue_id" =~ ^[0-9]+$ || -z "$spec" ]]; then
                echo "usage: /queue remove <id> <index-or-range>"
                return 1
            fi
            control_queue_remove_items "$queue_id" "$spec"
            ;;
        dequeue|deque)
            if [[ "$rest" =~ ^([0-9]+)[[:space:]]*$ ]]; then
                control_queue_dequeue_item "${BASH_REMATCH[1]}"
            else
                echo "usage: /queue dequeue <id>"
                return 1
            fi
            ;;
        edit)
            queue_id="${rest%%[[:space:]]*}"
            rest="${rest#"$queue_id"}"
            rest="$(control_ltrim "$rest")"
            index="${rest%%[[:space:]]*}"
            payload="${rest#"$index"}"
            payload="$(control_ltrim "$payload")"
            payload="$(control_collect_queue_array_payload "$payload")"
            if [[ ! "$queue_id" =~ ^[0-9]+$ || ! "$index" =~ ^[1-9][0-9]*$ ]] || ! control_parse_queue_items "$payload"; then
                echo "usage: /queue edit <id> <index> [\"new item\"]"
                return 1
            fi
            if (( ${#CONTROL_QUEUE_PARSED_ITEMS[@]} != 1 )); then
                echo "/queue edit requires exactly one replacement item"
                return 1
            fi
            control_queue_edit_item "$queue_id" "$index" "${CONTROL_QUEUE_PARSED_ITEMS[0]}"
            ;;
        ""|*)
            echo "usage: /queue [\"item1\", \"item2\"]"
            echo "type /help for available commands"
            return 1
            ;;
    esac
}

control_cancel_loop() {
    local loop_id="$1"
    local pid="${LOOP_PIDS[$loop_id]:-}"
    local queue_id

    if [[ -z "$pid" ]]; then
        echo "no active loop with id: $loop_id"
        return 1
    fi

    if [[ "${LOOP_TYPES[$loop_id]:-}" == "queue" ]]; then
        queue_id="${LOOP_QUEUE_IDS[$loop_id]:-}"
        if [[ -z "$queue_id" ]]; then
            echo "no active loop with id: $loop_id"
            return 1
        fi
        if ! control_cancel_queue "$queue_id" >/dev/null; then
            echo "no active loop with id: $loop_id"
            return 1
        fi
        echo "canceled loop #$loop_id"
        control_audit "LOOP #$loop_id canceled (queue #$queue_id)"
        return 0
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    unset "LOOP_PIDS[$loop_id]"
    unset "LOOP_INTERVALS[$loop_id]"
    unset "LOOP_SECONDS[$loop_id]"
    unset "LOOP_PROMPTS[$loop_id]"
    unset "LOOP_TARGETS[$loop_id]"
    unset "LOOP_TYPES[$loop_id]"
    unset "LOOP_QUEUE_IDS[$loop_id]"

    echo "canceled loop #$loop_id"
    control_audit "LOOP #$loop_id canceled"
}

control_list_loops() {
    local found=0
    local id pid preview

    control_prune_queues
    for (( id=1; id<NEXT_LOOP_ID; id++ )); do
        pid="${LOOP_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            if [[ "${LOOP_TYPES[$id]:-}" == "queue" && -n "${LOOP_QUEUE_IDS[$id]:-}" ]]; then
                local queue_id="${LOOP_QUEUE_IDS[$id]}"
                local state_dir="${QUEUE_STATE_DIRS[$queue_id]:-}"
                [[ -n "$state_dir" ]] && rm -rf "$state_dir" 2>/dev/null || true
                unset "QUEUE_PIDS[$queue_id]" "QUEUE_INTERVALS[$queue_id]" "QUEUE_SECONDS[$queue_id]" \
                    "QUEUE_TARGETS[$queue_id]" "QUEUE_TYPES[$queue_id]" "QUEUE_STATE_DIRS[$queue_id]" \
                    "QUEUE_LOOP_IDS[$queue_id]"
            fi
            unset "LOOP_PIDS[$id]"
            unset "LOOP_INTERVALS[$id]"
            unset "LOOP_SECONDS[$id]"
            unset "LOOP_PROMPTS[$id]"
            unset "LOOP_TARGETS[$id]"
            unset "LOOP_TYPES[$id]"
            unset "LOOP_QUEUE_IDS[$id]"
            continue
        fi

        found=1
        preview="$(control_preview "${LOOP_PROMPTS[$id]}")"
        if [[ "${LOOP_TYPES[$id]:-}" == "queue" ]]; then
            printf '#%s every %s to %s: %s (queue #%s)\n' "$id" "${LOOP_INTERVALS[$id]}" "${LOOP_TARGETS[$id]}" "$preview" "${LOOP_QUEUE_IDS[$id]}"
        else
            printf '#%s every %s to %s: %s\n' "$id" "${LOOP_INTERVALS[$id]}" "${LOOP_TARGETS[$id]}" "$preview"
        fi
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
  /queue ["item1", "item2"]     Run queued prompts/slash commands sequentially
  /queue add <id> ["item"]      Append pending queue items
  /queue edit <id> <n> ["item"] Replace one pending queue item
  /queue remove <id> <n|a-b>    Remove pending queue item(s)
  /queue dequeue <id>           Remove the next pending queue item
  /queue show <id>              Show queue items
  /queues                       List active queues
  /loop <interval> <prompt>     Schedule a prompt for agent-1. Intervals: 30s, 15m, 1h, 1d
  /loop <interval> /queue [...]
                                Schedule a queued loop
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

    line="$(control_normalize_line_endings "$line")"
    line="$(control_ltrim "$line")"
    [[ -n "$line" ]] || return 0

    case "$line" in
        /help)
            control_print_help
            ;;
        /queues)
            control_list_queues
            ;;
        /queues\ cancel\ *)
            rest="${line#/queues cancel }"
            rest="$(control_ltrim "$rest")"
            if [[ "$rest" =~ ^([0-9]+)[[:space:]]*$ ]]; then
                control_cancel_queue "${BASH_REMATCH[1]}"
            else
                echo "usage: /queues cancel <id>"
            fi
            ;;
        /queues*)
            echo "usage: /queues or /queues cancel <id>"
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
        /plan|/plan\ *|$'/plan\t'*|$'/plan\n'*)
            rest="${line#/plan}"
            rest="$(control_ltrim "$rest")"
            rest="$(control_collect_plan_prompt "$rest")"
            control_start_plan "$rest"
            ;;
        /queue|/queue\ *|$'/queue\t'*|$'/queue\n'*)
            rest="${line#/queue}"
            control_handle_queue_command "$rest"
            ;;
        /loop*)
            if parsed="$(control_parse_loop_command "$line")"; then
                interval="${parsed%%$'\t'*}"
                rest="${parsed#*$'\t'}"
                seconds="${rest%%$'\t'*}"
                prompt="${rest#*$'\t'}"
                prompt="$(control_collect_loop_prompt "$prompt")"
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

    for id in "${!QUEUE_PIDS[@]}"; do
        pid="${QUEUE_PIDS[$id]:-}"
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        [[ -n "${QUEUE_STATE_DIRS[$id]:-}" ]] && rm -rf "${QUEUE_STATE_DIRS[$id]}" 2>/dev/null || true
    done
}

control_main() {
    local line

    if [[ -z "$SESSION_NAME" || -z "$AUDIT_LOG" ]]; then
        echo "usage: control-pane.sh <session> <audit-log> [standard|worktree]" >&2
        exit 1
    fi

    : >> "$AUDIT_LOG" 2>/dev/null || true

    if [[ -t 0 ]]; then
        HISTFILE=
        HISTSIZE="${HISTSIZE:-1000}"
        set -o history 2>/dev/null || true
        bind '"\e[A": previous-history' 2>/dev/null || true
        bind '"\e[B": next-history' 2>/dev/null || true
        bind 'set enable-bracketed-paste off' 2>/dev/null || true
    fi

    trap control_cleanup EXIT
    trap 'control_cleanup; exit 0' INT TERM
    control_audit "control pane started (mode=$SESSION_MODE)"

    tail -n 40 -f "$AUDIT_LOG" &
    TAIL_PID=$!

    echo ""
    echo "codex-yolo control ready. Type /help for commands."

    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        if ! control_read_line line; then
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
