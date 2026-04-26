#!/usr/bin/env bash
# conflict-daemon.sh — Background monitor that detects merge conflicts between worktrees
#
# Uses git merge-tree --write-tree (git 2.38+) to simulate merges without
# touching the index or working tree. Purely read-only.
#
# Usage: conflict-daemon.sh <session-name> [poll-interval] [audit-log]

set -u  # No set -e — daemon must survive transient errors

_CD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CD_LIB_DIR/common.sh"
source "$_CD_LIB_DIR/worktree-manager.sh"

SESSION_NAME="${1:?Usage: conflict-daemon.sh <session-name> [poll-interval] [audit-log]}"
POLL_INTERVAL="${2:-5}"
AUDIT_LOG="${3:-$(log_dir)/codex-yolo-${SESSION_NAME}.log}"

REPO_DIR="$(wt_read_repo_dir "$SESSION_NAME")"

trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] Conflict daemon exited (session=$SESSION_NAME)" >> "$AUDIT_LOG" 2>/dev/null' EXIT

audit_conflict() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONFLICT $msg" >> "$AUDIT_LOG" 2>/dev/null || true
}

# Check for conflicts between two branches.
# Exit 0 + stdout = conflicts found (CONFLICT lines printed).
# Exit 1 = clean merge. Exit 2 = error.
check_pair() {
    local branch_a="$1" branch_b="$2"

    local output rc=0
    output="$(git -C "$REPO_DIR" merge-tree --write-tree "$branch_a" "$branch_b" 2>&1)" || rc=$?

    case $rc in
        0) return 1 ;;
        1) echo "$output" | grep 'CONFLICT' 2>/dev/null || echo "(conflict details unavailable)"
           return 0 ;;
        *) return 2 ;;
    esac
}

main_loop() {
    log_info "Conflict daemon started for session '$SESSION_NAME' (poll=${POLL_INTERVAL}s)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Conflict daemon started for session=$SESSION_NAME" >> "$AUDIT_LOG"

    while true; do
        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            log_warn "Session '$SESSION_NAME' gone, conflict daemon exiting"
            break
        fi

        local branches=()
        while IFS=' ' read -r branch _path; do
            [[ -n "$branch" ]] && branches+=("$branch")
        done < <(wt_list "$SESSION_NAME" 2>/dev/null)

        local n=${#branches[@]}
        local conflicts_found=0

        local i j
        for (( i=0; i<n; i++ )); do
            for (( j=i+1; j<n; j++ )); do
                local ba="${branches[$i]}" bb="${branches[$j]}"
                local details
                if details="$(check_pair "$ba" "$bb")"; then
                    conflicts_found=$((conflicts_found + 1))
                    audit_conflict "$ba <> $bb: $details"
                fi
            done
        done

        if (( conflicts_found > 0 )); then
            local pairs=$(( n * (n-1) / 2 ))
            audit_conflict "scan: $conflicts_found/$pairs pairs have conflicts"
        fi

        sleep "$POLL_INTERVAL"
    done
}

main_loop
