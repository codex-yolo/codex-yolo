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
CODEX_YOLO_PERMISSION_PROFILE="${CODEX_YOLO_PERMISSION_PROFILE:-}"
CODEX_YOLO_FULL_ACCESS_ALLOWED="${CODEX_YOLO_FULL_ACCESS_ALLOWED:-}"

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

codex_yolo_full_access_allowed() {
    if [[ -n "${CODEX_YOLO_FULL_ACCESS_ALLOWED:-}" ]]; then
        [[ "$CODEX_YOLO_FULL_ACCESS_ALLOWED" == "1" ]]
        return
    fi

    local cache_file="$HOME/.codex/cloud-requirements-cache.json"
    [[ -f "$cache_file" ]] || return 0

    local host
    host="$(hostname 2>/dev/null || true)"

    if command -v python3 >/dev/null 2>&1; then
        local rc=0
        if python3 - "$cache_file" "$host" <<'PY'
import fnmatch
import json
import re
import sys

cache_file, host = sys.argv[1], sys.argv[2]
try:
    with open(cache_file, "r", encoding="utf-8") as f:
        contents = json.load(f).get("signed_payload", {}).get("contents", "")
except Exception:
    sys.exit(2)

def modes(block):
    match = re.search(r"allowed_sandbox_modes\s*=\s*\[(.*?)\]", block, re.S)
    if not match:
        return None
    return re.findall(r'"([^"]+)"', match.group(1))

def list_values(block, key):
    match = re.search(rf"{key}\s*=\s*\[(.*?)\]", block, re.S)
    if not match:
        return None
    return re.findall(r'"([^"]+)"', match.group(1))

def scalar_value(block, key):
    match = re.search(rf"{key}\s*=\s*\"([^\"]+)\"", block)
    if not match:
        return None
    return match.group(1)

def approval_never_allowed(block):
    for key in (
        "allowed_approval_policies",
        "allowed_approval_policy",
        "allowed_approval_modes",
        "allowed_approval_mode",
    ):
        values = list_values(block, key)
        if values is not None:
            return "never" in values

    value = scalar_value(block, "approval_policy")
    if value is not None:
        return value == "never"

    return None

def full_access_decision(block):
    block_modes = modes(block)
    sandbox_ok = None if block_modes is None else "danger-full-access" in block_modes
    approval_ok = approval_never_allowed(block)

    if sandbox_ok is False or approval_ok is False:
        return False
    if sandbox_ok is None and approval_ok is None:
        return None
    return True

parts = contents.split("[[remote_sandbox_config]]")
top_decision = full_access_decision(parts[0])

for block in parts[1:]:
    match = re.search(r"hostname_patterns\s*=\s*\[(.*?)\]", block, re.S)
    if not match:
        continue
    patterns = re.findall(r'"([^"]+)"', match.group(1))
    if any(fnmatch.fnmatch(host, pattern) for pattern in patterns):
        block_decision = full_access_decision(block)
        if block_decision is None:
            continue
        sys.exit(0 if block_decision else 1)

if top_decision is None:
    sys.exit(2)
sys.exit(0 if top_decision else 1)
PY
        then
            return 0
        else
            rc=$?
        fi
        case $rc in
            1) return 1 ;;
        esac
    fi

    # If the requirements cache cannot be parsed, optimistically request Full Access.
    # Codex will still enforce any managed requirements at startup.
    return 0
}

configure_codex_permissions() {
    local policy="${1:-auto}"

    case "$policy" in
        auto|"")
            if codex_yolo_full_access_allowed; then
                CODEX_YOLO_PERMISSION_PROFILE="full-access"
                log_info "Codex permissions default: Full Access"
            else
                CODEX_YOLO_PERMISSION_PROFILE="codex-auto-review"
                log_info "Codex permissions default: Auto-review (Full Access unavailable)"
            fi
            ;;
        full-access|codex-auto-review)
            CODEX_YOLO_PERMISSION_PROFILE="$policy"
            ;;
        auto-review)
            CODEX_YOLO_PERMISSION_PROFILE="codex-auto-review"
            ;;
        none|default|off)
            CODEX_YOLO_PERMISSION_PROFILE=""
            ;;
        *)
            log_error "Unknown Codex permissions profile: $policy"
            return 1
            ;;
    esac

    export CODEX_YOLO_PERMISSION_PROFILE
}

codex_yolo_permission_config_arg() {
    [[ -n "${CODEX_YOLO_PERMISSION_PROFILE:-}" ]] || return 0

    local profile="${CODEX_YOLO_PERMISSION_PROFILE//\"/\\\"}"
    printf -- "-c 'permission_profile=\"%s\"' " "$profile"
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

codex_yolo_tui_status_line() {
    printf '%s\n' 'status_line = ["model-with-reasoning", "current-dir", "total-output-tokens", "run-state", "context-remaining", "context-used", "codex-version", "used-tokens", "total-input-tokens", "task-progress"]'
}

codex_yolo_config_has_tui_table() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1

    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)
            if (line ~ /^\[[[:space:]]*tui[[:space:]]*\]$/) {
                found = 1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"
}

codex_yolo_config_has_tui_status_line() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1

    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)

            if (line ~ /^\[[[:space:]]*tui[[:space:]]*\]$/) {
                in_tui = 1
                next
            }
            if (line ~ /^\[/) {
                in_tui = 0
                next
            }
            if (in_tui && line ~ /^status_line[[:space:]]*=/) {
                found = 1
                exit
            }
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"
}

codex_yolo_configure_tui_status_line() {
    local config_file="$1"
    local status_line
    status_line="$(codex_yolo_tui_status_line)"

    if codex_yolo_config_has_tui_status_line "$config_file"; then
        return 0
    fi

    if codex_yolo_config_has_tui_table "$config_file"; then
        local tmp
        tmp="$(mktemp "${TMPDIR:-/tmp}/codex-yolo-config.XXXXXX")" || return 1

        if awk -v status_line="$status_line" '
            function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
            {
                raw = $0
                line = $0
                sub(/[[:space:]]+#.*$/, "", line)
                line = trim(line)

                if (!inserted && in_tui && line ~ /^\[/) {
                    print status_line
                    inserted = 1
                    in_tui = 0
                }

                print raw

                if (line ~ /^\[[[:space:]]*tui[[:space:]]*\]$/) {
                    in_tui = 1
                    next
                }
                if (line ~ /^\[/) {
                    in_tui = 0
                    next
                }
            }
            END {
                if (in_tui && !inserted) {
                    print status_line
                }
            }
        ' "$config_file" > "$tmp" && cp "$tmp" "$config_file"; then
            rm -f "$tmp"
        else
            rm -f "$tmp"
            return 1
        fi
    elif [[ -s "$config_file" ]]; then
        printf '\n[tui]\n%s\n' "$status_line" >> "$config_file" || return 1
    else
        printf '[tui]\n%s\n' "$status_line" >> "$config_file" || return 1
    fi

    log_info "Configured Codex TUI status line: $config_file"
}

# Ensure the Codex CLI config directory, config.toml, and codex-yolo defaults exist.
# Does NOT override approval_policy (the daemon handles prompts at the terminal level).
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

    codex_yolo_configure_tui_status_line "$config_file"
}
