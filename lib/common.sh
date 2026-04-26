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

CODEX_YOLO_BYPASS_CODEX_SANDBOX="${CODEX_YOLO_BYPASS_CODEX_SANDBOX:-0}"
CODEX_YOLO_FORCE_CODEX_SANDBOX="${CODEX_YOLO_FORCE_CODEX_SANDBOX:-0}"
CODEX_YOLO_SANDBOX_PROBE_RESULT="${CODEX_YOLO_SANDBOX_PROBE_RESULT:-}"
CODEX_YOLO_SANDBOX_PROBE_MESSAGE="${CODEX_YOLO_SANDBOX_PROBE_MESSAGE:-}"
CODEX_YOLO_CONTAINER_DETECTED="${CODEX_YOLO_CONTAINER_DETECTED:-}"
CODEX_YOLO_FAKE_BWRAP_DIR="${CODEX_YOLO_FAKE_BWRAP_DIR:-}"
CODEX_YOLO_FAKE_BWRAP_ENABLED="${CODEX_YOLO_FAKE_BWRAP_ENABLED:-0}"

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

# Check if git supports merge-tree --write-tree (requires git 2.38+).
check_git_merge_tree() {
    local version
    version="$(git version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+')" || return 1
    local major minor
    IFS='.' read -r major minor <<< "$version"
    (( major > 2 || (major == 2 && minor >= 38) ))
}

codex_yolo_running_in_container() {
    if [[ -n "${CODEX_YOLO_CONTAINER_DETECTED:-}" ]]; then
        [[ "$CODEX_YOLO_CONTAINER_DETECTED" == "1" ]]
        return
    fi

    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0

    if grep -qaE 'docker|kubepods|containerd|libpod|lxc' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    return 1
}

codex_yolo_bwrap_namespace_error() {
    local output="$1"
    [[ "$output" == *"No permissions to create a new namespace"* ]] || \
    [[ "$output" == *"Failed to create namespace"* ]] || \
    [[ "$output" == *"Operation not permitted"* ]]
}

codex_yolo_enable_fake_bwrap() {
    local shim_dir="${CODEX_YOLO_FAKE_BWRAP_DIR:-}"
    if [[ -z "$shim_dir" ]]; then
        shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-yolo-fake-bwrap.XXXXXX")" || return 1
    else
        mkdir -p "$shim_dir" 2>/dev/null || return 1
    fi

    cat > "$shim_dir/bwrap" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            exec "$@"
            ;;
    esac
    shift
done

echo "codex-yolo fake bwrap: no command after --" >&2
exit 127
SH
    chmod +x "$shim_dir/bwrap" || return 1

    CODEX_YOLO_FAKE_BWRAP_DIR="$shim_dir"
    CODEX_YOLO_FAKE_BWRAP_ENABLED=1
    export CODEX_YOLO_FAKE_BWRAP_DIR CODEX_YOLO_FAKE_BWRAP_ENABLED
}

codex_yolo_command_prefix() {
    if [[ -z "${CODEX_YOLO_FAKE_BWRAP_DIR:-}" ]]; then
        return 0
    fi

    local dir="${CODEX_YOLO_FAKE_BWRAP_DIR//\'/\'\\\'\'}"
    printf "PATH='%s':\"\$PATH\" " "$dir"
}

codex_linux_sandbox_works() {
    local os
    os="${CODEX_YOLO_TEST_UNAME_S:-$(uname -s 2>/dev/null || true)}"
    if [[ "$os" != "Linux" ]]; then
        return 0
    fi

    if [[ -n "${CODEX_YOLO_SANDBOX_PROBE_RESULT:-}" ]]; then
        if [[ "$CODEX_YOLO_SANDBOX_PROBE_RESULT" == "ok" ]]; then
            return 0
        fi
        return 1
    fi

    local output
    if output="$(codex sandbox linux true 2>&1)"; then
        CODEX_YOLO_SANDBOX_PROBE_RESULT="ok"
        CODEX_YOLO_SANDBOX_PROBE_MESSAGE=""
        return 0
    fi

    CODEX_YOLO_SANDBOX_PROBE_RESULT="fail"
    CODEX_YOLO_SANDBOX_PROBE_MESSAGE="$output"
    return 1
}

configure_codex_sandbox() {
    local policy="${1:-auto}"

    CODEX_YOLO_BYPASS_CODEX_SANDBOX=0
    CODEX_YOLO_FORCE_CODEX_SANDBOX=0

    case "$policy" in
        auto)
            if codex_yolo_running_in_container; then
                if codex_linux_sandbox_works; then
                    return 0
                fi

                CODEX_YOLO_BYPASS_CODEX_SANDBOX=1
                local first_line="${CODEX_YOLO_SANDBOX_PROBE_MESSAGE%%$'\n'*}"
                [[ -z "$first_line" ]] && first_line="codex sandbox linux true failed"

                if codex_yolo_bwrap_namespace_error "$CODEX_YOLO_SANDBOX_PROBE_MESSAGE"; then
                    codex_yolo_enable_fake_bwrap || return 1
                    log_warn "Container bwrap is unavailable; using fake bwrap shim: $CODEX_YOLO_FAKE_BWRAP_DIR/bwrap"
                else
                    log_warn "Container detected; launching agents without Codex sandboxing."
                fi

                log_warn "Sandbox probe: $first_line"
                log_warn "Use --force-codex-sandbox to require Codex sandboxing anyway."
                return 0
            fi

            if codex_linux_sandbox_works; then
                return 0
            fi

            CODEX_YOLO_BYPASS_CODEX_SANDBOX=1
            local first_line="${CODEX_YOLO_SANDBOX_PROBE_MESSAGE%%$'\n'*}"
            [[ -z "$first_line" ]] && first_line="codex sandbox linux true failed"
            log_warn "Codex Linux sandbox is unavailable; launching agents without Codex sandboxing."
            log_warn "Sandbox probe: $first_line"
            log_warn "Use --force-codex-sandbox to require Codex sandboxing instead."
            ;;
        off|none|no|disabled)
            CODEX_YOLO_BYPASS_CODEX_SANDBOX=1
            log_warn "Codex sandbox disabled by option; rely on external isolation."
            ;;
        force)
            CODEX_YOLO_FORCE_CODEX_SANDBOX=1
            ;;
        *)
            log_error "Unknown Codex sandbox policy: $policy"
            return 1
            ;;
    esac
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
