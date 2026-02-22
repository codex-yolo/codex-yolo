#!/usr/bin/env bash
# common.sh — Shared utilities for codex-yolo

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
    _RED='\033[0;31m'
    _YELLOW='\033[0;33m'
    _BLUE='\033[0;34m'
    _RESET='\033[0m'
else
    _RED='' _YELLOW='' _BLUE='' _RESET=''
fi

log_info() {
    printf "${_BLUE}[%s INFO]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_warn() {
    printf "${_YELLOW}[%s WARN]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_error() {
    printf "${_RED}[%s ERROR]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

check_prereqs() {
    local missing=0
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is not installed"
        missing=1
    fi
    if ! command -v codex &>/dev/null; then
        log_error "codex (OpenAI Codex CLI) is not installed"
        missing=1
    fi
    return $missing
}

# Return a writable directory for audit logs.
# Prefers /tmp; falls back to ~/.codex-yolo/logs (e.g. Termux where /tmp is not writable).
log_dir() {
    if touch /tmp/.codex-yolo-probe 2>/dev/null; then
        rm -f /tmp/.codex-yolo-probe
        echo "/tmp"
    else
        local d="$HOME/.codex-yolo/logs"
        mkdir -p "$d" 2>/dev/null || true
        echo "$d"
    fi
}

resolve_script_dir() {
    local src="${BASH_SOURCE[1]:-$0}"
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    echo "$dir"
}

# Ensure the Codex CLI config directory and config.toml exist.
# Does NOT override approval_policy (the daemon handles prompts at the terminal level).
# This just ensures the config directory is present so Codex doesn't error on first run.
ensure_codex_config() {
    local config_dir="$HOME/.codex"
    local config_file="$config_dir/config.toml"

    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" 2>/dev/null || true
        log_info "Created Codex config directory: $config_dir"
    fi

    # If no config exists, create a minimal one with default approval policy.
    # We do NOT set approval_policy=never because the daemon approach is
    # more flexible — it auto-approves while preserving sandbox protection.
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" <<'TOML'
# Codex CLI configuration — managed by codex-yolo
# The approver daemon handles permission prompts at the terminal level.
# This preserves sandbox protection while auto-approving prompts.
TOML
        log_info "Created minimal Codex config: $config_file"
    fi
}
