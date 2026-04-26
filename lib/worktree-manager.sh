#!/usr/bin/env bash
# worktree-manager.sh — Create, list, and clean up git worktrees for parallel agents
#
# State file format (one per session, stored in log_dir):
#   Line 1: repo root path
#   Line 2: base branch name
#   Line 3+: <branch> <worktree-path>   (space-separated)

_WT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_WT_LIB_DIR/common.sh"

# ── paths ────────────────────────────────────────────────────────────────────

wt_state_file() {
    echo "$(log_dir)/codex-yolo-wt-${1}.state"
}

wt_done_marker() {
    local session="$1" index="$2"
    echo "$(log_dir)/codex-yolo-done-${session}-${index}"
}

# Worktrees live in a sibling directory: <repo>-worktrees/<session>/
wt_base_dir() {
    local repo_root="$1" session="$2"
    echo "${repo_root}-worktrees/${session}"
}

# ── git helpers ──────────────────────────────────────────────────────────────

wt_validate_repo() {
    local dir="$1"
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not a git repository: $dir"
        return 1
    fi
}

wt_current_branch() {
    git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null
}

wt_repo_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# ── state file readers ───────────────────────────────────────────────────────

wt_read_repo_dir() {
    head -1 "$(wt_state_file "$1")"
}

wt_read_base_branch() {
    sed -n '2p' "$(wt_state_file "$1")"
}

# Output branch/path pairs (line 3+)
wt_list() {
    local sf
    sf="$(wt_state_file "$1")"
    [[ -f "$sf" ]] || return 1
    tail -n +3 "$sf"
}

wt_path_for() {
    local line
    line="$(sed -n "$(($2 + 2))p" "$(wt_state_file "$1")")"
    echo "${line#* }"
}

wt_branch_for() {
    local line
    line="$(sed -n "$(($2 + 2))p" "$(wt_state_file "$1")")"
    echo "${line%% *}"
}

# ── lifecycle ────────────────────────────────────────────────────────────────

wt_create_all() {
    local repo_dir="$1" session="$2" base_branch="$3" count="$4"

    local repo_root
    repo_root="$(wt_repo_root "$repo_dir")"

    local wt_base
    wt_base="$(wt_base_dir "$repo_root" "$session")"
    mkdir -p "$wt_base"

    local state_file
    state_file="$(wt_state_file "$session")"
    printf '%s\n%s\n' "$repo_root" "$base_branch" > "$state_file"

    local i
    for (( i=1; i<=count; i++ )); do
        local branch="${session}-${i}"
        local wt_path="${wt_base}/${branch}"

        if git -C "$repo_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
            log_error "Branch already exists: $branch"
            wt_cleanup "$session"
            return 1
        fi

        if ! git -C "$repo_root" worktree add -b "$branch" "$wt_path" "$base_branch" 2>&1; then
            log_error "Failed to create worktree: $branch"
            wt_cleanup "$session"
            return 1
        fi

        echo "${branch} ${wt_path}" >> "$state_file"
        log_info "Created worktree: $branch -> $wt_path"
    done
}

wt_cleanup() {
    local session="$1"
    local state_file
    state_file="$(wt_state_file "$session")"
    [[ -f "$state_file" ]] || return 0

    local repo_root
    repo_root="$(head -1 "$state_file")"

    while IFS=' ' read -r branch wt_path; do
        [[ -z "$branch" ]] && continue
        if [[ -d "$wt_path" ]]; then
            git -C "$repo_root" worktree remove --force "$wt_path" 2>/dev/null || \
                log_warn "Could not remove worktree: $wt_path"
        fi
        git -C "$repo_root" branch -D "$branch" 2>/dev/null || \
            log_warn "Could not delete branch: $branch"
        log_info "Cleaned up: $branch"
    done < <(tail -n +3 "$state_file")

    # Remove worktree directories if empty.
    local wt_base
    wt_base="$(wt_base_dir "$repo_root" "$session")"
    rmdir "$wt_base" 2>/dev/null || true
    rmdir "$(dirname "$wt_base")" 2>/dev/null || true

    rm -f "$(log_dir)/codex-yolo-done-${session}-"* 2>/dev/null
    rm -f "$state_file"

    log_info "Worktree cleanup complete for session: $session"
}
