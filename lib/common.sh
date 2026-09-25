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
CODEX_YOLO_ASK_FOR_APPROVAL="${CODEX_YOLO_ASK_FOR_APPROVAL:-0}"
CODEX_YOLO_APPROVALS_REVIEWER="${CODEX_YOLO_APPROVALS_REVIEWER:-user}"
CODEX_YOLO_NETWORK_ACCESS="${CODEX_YOLO_NETWORK_ACCESS:-1}"
CODEX_YOLO_SANDBOX_PROBE_RESULT="${CODEX_YOLO_SANDBOX_PROBE_RESULT:-}"
CODEX_YOLO_SANDBOX_PROBE_MESSAGE="${CODEX_YOLO_SANDBOX_PROBE_MESSAGE:-}"
CODEX_YOLO_CONTAINER_DETECTED="${CODEX_YOLO_CONTAINER_DETECTED:-}"
CODEX_YOLO_FAKE_BWRAP_DIR="${CODEX_YOLO_FAKE_BWRAP_DIR:-}"
CODEX_YOLO_FAKE_BWRAP_ENABLED="${CODEX_YOLO_FAKE_BWRAP_ENABLED:-0}"
CODEX_YOLO_PERMISSION_PROFILE="${CODEX_YOLO_PERMISSION_PROFILE:-}"
CODEX_YOLO_FULL_ACCESS_ALLOWED="${CODEX_YOLO_FULL_ACCESS_ALLOWED:-}"

codex_yolo_command_works() {
    local cmd="$1"
    shift

    hash -r 2>/dev/null || true
    command -v "$cmd" &>/dev/null || return 1
    "$cmd" "$@" &>/dev/null
}

codex_yolo_codex_cli_works() {
    codex_yolo_command_works codex --version
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
    elif ! codex_yolo_codex_cli_works; then
        log_error "codex (OpenAI Codex CLI) is installed but cannot run; 'codex --version' failed. Re-run the codex-yolo installer or install Node.js and @openai/codex."
        missing=1
    fi
    return $missing
}

# ── best-model auto-selection ────────────────────────────────────────────────
# When no -m/--model is given, the launcher picks the most capable model the
# account can actually use: candidates are probed in order with a minimal
# one-shot `codex exec` call, and the winner is cached so later launches skip
# the probe. Probing beats reading the local model catalog — the catalog lists
# what exists, not what this account/plan is currently allowed to use.
CODEX_YOLO_MODEL_CANDIDATES="${CODEX_YOLO_MODEL_CANDIDATES:-gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5}"
CODEX_YOLO_MODEL_CACHE_TTL="${CODEX_YOLO_MODEL_CACHE_TTL:-86400}"
CODEX_YOLO_MODEL_PROBE_TIMEOUT="${CODEX_YOLO_MODEL_PROBE_TIMEOUT:-60}"

model_cache_file() {
    echo "$HOME/.codex-yolo/model-cache"
}

# Probe whether the account can use a model: one tiny non-interactive request.
# read-only sandbox (nothing to execute), no git-repo requirement (the probe
# may run from any directory), and reasoning effort pinned to low — the probe
# answers "can this account use this model", so a config.toml effort level the
# candidate does not support (e.g. ultra on gpt-5.5) must not fail it; low
# also keeps the probe fast and cheap. Exit 0 = the model answered. Kept as
# its own function so tests can stub it.
codex_yolo_probe_model() {
    local m="$1"
    if command -v timeout &>/dev/null; then
        timeout "$CODEX_YOLO_MODEL_PROBE_TIMEOUT" \
            codex exec --skip-git-repo-check -s read-only -m "$m" \
            -c 'model_reasoning_effort="low"' 'Reply with one word: ok' </dev/null &>/dev/null
    else
        codex exec --skip-git-repo-check -s read-only -m "$m" \
            -c 'model_reasoning_effort="low"' 'Reply with one word: ok' </dev/null &>/dev/null
    fi
}

# Print the best available model from CODEX_YOLO_MODEL_CANDIDATES (probed in
# order, result cached for CODEX_YOLO_MODEL_CACHE_TTL seconds). Prints
# nothing when no candidate works (auth/network down, or none permitted) —
# the launcher then omits --model and Codex uses its own configured default.
# Always returns 0 so `set -e` callers survive a failed resolution.
resolve_best_model() {
    local cache now
    cache="$(model_cache_file)"
    now="$(date +%s)"

    if [[ -f "$cache" ]]; then
        local cached cached_candidates mtime age
        cached="$(head -1 "$cache" 2>/dev/null | tr -d '[:space:]')"
        cached_candidates="$(sed -n '2p' "$cache" 2>/dev/null)"
        mtime="$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)"
        age=$(( now - mtime ))
        # Cache the candidate ordering as well as the winner. This invalidates
        # old one-line caches and makes a newly preferred model take effect
        # immediately instead of waiting for the TTL to expire.
        if [[ -n "$cached" ]] && (( age >= 0 && age < CODEX_YOLO_MODEL_CACHE_TTL )) \
           && [[ "$cached_candidates" == "$CODEX_YOLO_MODEL_CANDIDATES" ]] \
           && [[ " $CODEX_YOLO_MODEL_CANDIDATES " == *" $cached "* ]]; then
            echo "$cached"
            return 0
        fi
    fi

    local m
    for m in $CODEX_YOLO_MODEL_CANDIDATES; do
        log_info "Probing model availability: $m"
        if codex_yolo_probe_model "$m"; then
            mkdir -p "$(dirname "$cache")" 2>/dev/null || true
            printf '%s\n%s\n' "$m" "$CODEX_YOLO_MODEL_CANDIDATES" > "$cache" 2>/dev/null || true
            echo "$m"
            return 0
        fi
        log_warn "Model unavailable: $m — trying next candidate"
    done

    log_warn "No candidate model available ($CODEX_YOLO_MODEL_CANDIDATES) — using Codex's default model"
    return 0
}

# Return an effort the selected model supports. The launcher only applies this
# compatibility fallback when the effort came from its default; an explicit
# incompatible -e/--effort is rejected instead.
codex_yolo_compatible_effort() {
    local model="${1:-}" effort="${2:-}"

    case "$model:$effort" in
        gpt-5.6-luna:ultra)                      printf '%s\n' 'max' ;;
        gpt-5.5:ultra|gpt-5.5:max|\
        gpt-5.4:ultra|gpt-5.4:max|\
        gpt-5.4-mini:ultra|gpt-5.4-mini:max|\
        gpt-5.3-codex-spark:ultra|gpt-5.3-codex-spark:max|\
        gpt-5.3-codex:ultra|gpt-5.3-codex:max|\
        gpt-5.2:ultra|gpt-5.2:max)               printf '%s\n' 'xhigh' ;;
        *)                                       printf '%s\n' "$effort" ;;
    esac
}

# Render the -c override that sets the reasoning effort for an agent command.
# Codex has no dedicated effort flag; the model_reasoning_effort config key is
# the supported knob. The launcher validates known values and its known model
# compatibility fallback before it constructs a command.
codex_yolo_effort_config_arg() {
    local effort="${1:-}"
    [[ -n "$effort" ]] || return 0

    local level="${effort//\"/\\\"}"
    printf -- "-c 'model_reasoning_effort=\"%s\"' " "$level"
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
  [[ "$output" == *"No permissions to create new namespace"* ]] || \
    [[ "$output" == *"No permissions to create a new namespace"* ]] || \
    [[ "$output" == *"Failed to create namespace"* ]] || \
    [[ "$output" == *"Operation not permitted"* ]]
}

codex_yolo_warn_bwrap_prerequisites() {
  local output="$1"
  codex_yolo_bwrap_namespace_error "$output" || return 0
  log_warn "Bubblewrap setup guide: https://learn.chatgpt.com/docs/sandboxing?surface=app#app-prerequisites"
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

    CODEX_YOLO_ASK_FOR_APPROVAL=0
    CODEX_YOLO_APPROVALS_REVIEWER="user"

    case "$policy" in
        auto|"")
            CODEX_YOLO_PERMISSION_PROFILE=""
            CODEX_YOLO_ASK_FOR_APPROVAL=1
            log_info "Codex permissions default: Ask for approval"
            ;;
        ask-for-approval|ask|manual)
            CODEX_YOLO_PERMISSION_PROFILE=""
            CODEX_YOLO_ASK_FOR_APPROVAL=1
            ;;
        full-access)
            CODEX_YOLO_PERMISSION_PROFILE="$policy"
            ;;
        auto-review|codex-auto-review)
            # Auto-review changes who reviews approval requests; it does not
            # require a named filesystem/network permission profile.
            CODEX_YOLO_PERMISSION_PROFILE="codex-auto-review"
            CODEX_YOLO_ASK_FOR_APPROVAL=1
            CODEX_YOLO_APPROVALS_REVIEWER="auto_review"
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
    export CODEX_YOLO_ASK_FOR_APPROVAL
    export CODEX_YOLO_APPROVALS_REVIEWER
}

codex_yolo_permission_config_arg() {
    # An explicit no-sandbox request takes precedence over the safe default.
    if (( ${CODEX_YOLO_BYPASS_CODEX_SANDBOX:-0} )); then
        return 0
    fi

    if (( ${CODEX_YOLO_ASK_FOR_APPROVAL:-0} )); then
        local reviewer="${CODEX_YOLO_APPROVALS_REVIEWER:-user}"
        reviewer="${reviewer//\"/\\\"}"
        printf -- "--sandbox workspace-write --ask-for-approval on-request -c 'approvals_reviewer=\"%s\"' -c 'sandbox_workspace_write.network_access=%s' " \
            "$reviewer" "$(codex_yolo_network_access_value)"
        return 0
    fi

    if [[ -z "${CODEX_YOLO_PERMISSION_PROFILE:-}" ]]; then
        printf -- "--sandbox workspace-write -c 'sandbox_workspace_write.network_access=%s' " \
            "$(codex_yolo_network_access_value)"
        return 0
    fi

    local profile="${CODEX_YOLO_PERMISSION_PROFILE//\"/\\\"}"
    printf -- "-c 'permission_profile=\"%s\"' " "$profile"
}

codex_yolo_network_access_value() {
    case "${CODEX_YOLO_NETWORK_ACCESS:-1}" in
        0|false|no|off) printf 'false\n' ;;
        *)              printf 'true\n' ;;
    esac
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

                # The outer container is already the isolation boundary. Always
                # shadow bwrap after a failed probe: managed requirements may
                # reject --dangerously-bypass-approvals-and-sandbox and force
                # Codex back through bwrap, so the flag alone is not a reliable
                # fallback in Docker. --force-codex-sandbox skips this path.
                codex_yolo_enable_fake_bwrap || return 1
                log_warn "Container Codex sandbox is unavailable; using outer container isolation."
                log_warn "Using fake bwrap shim: $CODEX_YOLO_FAKE_BWRAP_DIR/bwrap"

      log_warn "Sandbox probe: $first_line"
      codex_yolo_warn_bwrap_prerequisites "$CODEX_YOLO_SANDBOX_PROBE_MESSAGE"
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
      codex_yolo_warn_bwrap_prerequisites "$CODEX_YOLO_SANDBOX_PROBE_MESSAGE"
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

# Keep the Codex settings required by codex-yolo in the user-level config.
# Top-level keys must appear before the first TOML table, while feature flags
# belong inside [features], so this cannot be implemented safely by blindly
# appending a block. Reconcile existing values in place and insert missing
# values at the appropriate table boundary instead.
codex_yolo_configure_runtime_defaults() {
    local config_file="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/codex-yolo-config.XXXXXX")" || return 1

    if awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function print_missing_root() {
            if (!have_approval) print "approval_policy = \"on-request\""
            if (!have_sandbox) print "sandbox_mode = \"workspace-write\""
        }
        function print_missing_features() {
            if (!have_shell_tool) print "shell_tool = true"
            if (!have_code_mode_host) print "code_mode_host = true"
        }
        {
            raw = $0
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)

            if (line ~ /^\[/) {
                if (!left_root) {
                    print_missing_root()
                    left_root = 1
                }
                if (in_features) {
                    print_missing_features()
                    in_features = 0
                }

                print raw
                if (line ~ /^\[[[:space:]]*features[[:space:]]*\]$/) {
                    have_features = 1
                    in_features = 1
                }
                next
            }

            if (!left_root && line ~ /^approval_policy[[:space:]]*=/) {
                if (!have_approval) print "approval_policy = \"on-request\""
                have_approval = 1
                next
            }
            if (!left_root && line ~ /^sandbox_mode[[:space:]]*=/) {
                if (!have_sandbox) print "sandbox_mode = \"workspace-write\""
                have_sandbox = 1
                next
            }
            if (in_features && line ~ /^shell_tool[[:space:]]*=/) {
                if (!have_shell_tool) print "shell_tool = true"
                have_shell_tool = 1
                next
            }
            if (in_features && line ~ /^unified_exec[[:space:]]*=/) {
                # Older codex-yolo versions forced unified_exec on. It is on by
                # default on supported systems, while managed workspaces may
                # require it off. Drop the old true override so Codex can apply
                # its default or managed requirement; preserve an explicit false.
                if (!have_unified_exec && line !~ /^unified_exec[[:space:]]*=[[:space:]]*true$/) print raw
                have_unified_exec = 1
                next
            }
            if (in_features && line ~ /^code_mode_host[[:space:]]*=/) {
                if (!have_code_mode_host) print "code_mode_host = true"
                have_code_mode_host = 1
                next
            }

            print raw
        }
        END {
            if (!left_root) print_missing_root()
            if (in_features) print_missing_features()
            if (!have_features) {
                print ""
                print "[features]"
                print "shell_tool = true"
                print "code_mode_host = true"
            }
        }
    ' "$config_file" > "$tmp" && cp "$tmp" "$config_file"; then
        rm -f "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi

    log_info "Configured Codex runtime defaults: $config_file"
}

# stdout is Codex's hook result channel, never a fallback terminal. Stop hooks
# must return JSON even when /dev/tty is unavailable. Grouping the tty write
# also suppresses redirection errors before they can leak into the session.
CODEX_YOLO_STOP_BELL_COMMAND='{ printf "\a" > /dev/tty; } 2>/dev/null || :; printf "{}\n"'
CODEX_YOLO_LEGACY_STOP_BELL_COMMAND='printf "\a" > /dev/tty 2>/dev/null || printf "\a"'

# TOML block wiring Codex's `Stop` lifecycle hook to ring the terminal bell.
# The Stop hook fires when the agent finishes its turn and returns control to
# you. Under yolo mode the approver daemon auto-clears permission prompts, so
# turn completion is the only moment your input is actually requested — we
# deliberately do NOT hook PermissionRequest. The command writes BEL to the
# agent's tmux pane (/dev/tty), skipping the bell if there is no tty.
# A literal (single-quoted) TOML string keeps the command verbatim; the shell
# Codex spawns expands printf's \a to the bell byte. Hook trust remains under
# Codex's normal review flow; changing the command must not forge new trust.
codex_yolo_stop_bell_block() {
    cat <<TOML

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = '${CODEX_YOLO_STOP_BELL_COMMAND}'
timeout = 30
TOML
}

# Repair only the exact literal command emitted by older codex-yolo releases,
# inside their command-hook table. Preserve comments, positions, other hooks,
# and all trust entries (including disabled state). A stale trust hash causes
# Codex to request review of the changed definition, as intended.
#
# This intentionally narrow dependency-free edit is not a TOML parser. Refuse
# migration when multiline strings occur, where apparent tables may be text.
codex_yolo_migrate_stop_bell() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 0
    grep -qF "$CODEX_YOLO_LEGACY_STOP_BELL_COMMAND" "$config_file" || return 0
    local tmp rc=0
    tmp="$(mktemp "${config_file}.bell.XXXXXX")" || return 1
    CY_BELL_OLD="$CODEX_YOLO_LEGACY_STOP_BELL_COMMAND" \
    CY_BELL_NEW="$CODEX_YOLO_STOP_BELL_COMMAND" awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        BEGIN { quote = sprintf("%c", 39); old = quote ENVIRON["CY_BELL_OLD"] quote; new = quote ENVIRON["CY_BELL_NEW"] quote }
        {
            raw = $0
            if (index(raw, "\"\"\"") || index(raw, quote quote quote)) uncertain = 1
            line = raw
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)
            if (line ~ /^\[/) {
                hook = (line ~ /^\[\[[[:space:]]*hooks\.Stop\.hooks[[:space:]]*\]\]$/)
                command_type = 0
            }
            if (hook && line == "type = \"command\"") command_type = 1
            if (hook && command_type && line ~ /^command[[:space:]]*=/) {
                value = line
                sub(/^command[[:space:]]*=[[:space:]]*/, "", value)
                if (value == old) {
                    pos = index(raw, old)
                    raw = substr(raw, 1, pos - 1) new substr(raw, pos + length(old))
                    changed = 1
                }
            }
            print raw
        }
        END { if (uncertain) exit 3; if (!changed) exit 2 }
    ' "$config_file" > "$tmp" || rc=$?
    if [[ "$rc" == 0 ]]; then
        cp "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
        log_info "Repaired Codex bell hook JSON output; review the changed hook in Codex: $config_file"
    elif [[ "$rc" == 3 ]] && grep -qF "$CODEX_YOLO_LEGACY_STOP_BELL_COMMAND" "$config_file"; then
        log_info "Bell hook migration skipped for multiline TOML; update the Stop command manually: $config_file"
    fi
    rm -f "$tmp"
    [[ "$rc" == 0 || "$rc" == 2 || "$rc" == 3 ]]
}

# True if the config already references a hooks.Stop table — array-of-tables
# [[hooks.Stop]], table [hooks.Stop], or nested [hooks.Stop.hooks] (commented
# lines and trailing comments ignored). When present we leave the user's hook
# configuration entirely alone rather than risk a duplicate/conflicting table.
codex_yolo_config_has_stop_hook() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1

    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)
            if (line ~ /^\[\[?[[:space:]]*hooks\.Stop([.]|[[:space:]]*\])/) { found = 1; exit }
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"
}

# ── PermissionRequest hook — off-screen approval-dialog markers ──────────────
# Codex fires the PermissionRequest lifecycle hook whenever it shows an
# approval dialog, with a JSON payload on stdin (hook_event_name, tool_name,
# tool_input, ...). The command below records the dialog as a per-pane marker
# file — <CODEX_YOLO_WAITING_DIR>/<TMUX_PANE>, line 1 an epoch timestamp,
# line 2 the payload with newlines stripped — written atomically (temp file +
# mv) so the approver daemon never reads a half-written marker. The daemon
# uses these markers to recognize dialogs rendered off-screen (e.g. a diff
# taller than the pane), which the capture-based detectors can never see.
#
# The command is deliberately STATIC — the session-specific marker directory
# comes from the CODEX_YOLO_WAITING_DIR environment variable the launcher
# sets on each agent pane, never from the command text — so its trust hash is
# one constant for the existing permission-marker hook.
# Outside a codex-yolo session (no CODEX_YOLO_WAITING_DIR, or no TMUX_PANE)
# the hook exits 0 without writing anything, and it never surfaces errors
# into the Codex session. Single-quoted TOML literal: the command must not
# contain single quotes.
CODEX_YOLO_PERMISSION_HOOK_COMMAND='p=$(cat 2>/dev/null); case "$p" in *PermissionRequest*) d="${CODEX_YOLO_WAITING_DIR:-}"; [ -n "$d" ] || exit 0; [ -n "${TMUX_PANE:-}" ] || exit 0; mkdir -p "$d" 2>/dev/null || exit 0; t="$d/.tmp.$$.$TMUX_PANE"; { date +%s; printf "%s" "$p" | tr -d "\r\n"; echo; } > "$t" 2>/dev/null && mv "$t" "$d/$TMUX_PANE" 2>/dev/null ;; esac; exit 0'

# IMPORTANT: this hash is tied to CODEX_YOLO_PERMISSION_HOOK_COMMAND above
# (Codex computes it purely from the hook definition — type/command/timeout —
# so it is identical across machines and config paths).
# If the command or timeout ever changes, regenerate it by launching `codex`
# once, choosing "Review hooks" → trusting the hook, and copying the
# resulting trusted_hash from ~/.codex/config.toml.
CODEX_YOLO_PERMISSION_HOOK_TRUSTED_HASH="sha256:be2d5630ba8f23f4308f10b3263c1df99a7379e3fed5e844fa0f81bda5d7d638"

codex_yolo_permission_hook_block() {
    cat <<TOML

[[hooks.PermissionRequest]]

[[hooks.PermissionRequest.hooks]]
type = "command"
command = '${CODEX_YOLO_PERMISSION_HOOK_COMMAND}'
timeout = 30
TOML
}

# Trust entry marking the appended PermissionRequest hook as already
# reviewed. Mirrors what Codex writes after a manual "Review hooks" trust
# (the bell hook uses normal review instead). The lookup key embeds the config
# path and the hook's position (event:table_index:hook_index) — ours is the
# first PermissionRequest group we append, hence :0:0.
codex_yolo_permission_hook_trust_block() {
    local config_file="$1"
    cat <<TOML

[hooks.state."${config_file}:permission_request:0:0"]
trusted_hash = "${CODEX_YOLO_PERMISSION_HOOK_TRUSTED_HASH}"
TOML
}

codex_yolo_config_has_permission_hook_trust() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1
    grep -qF "$CODEX_YOLO_PERMISSION_HOOK_TRUSTED_HASH" "$config_file"
}

codex_yolo_config_has_permission_hook_command() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1
    grep -qF 'CODEX_YOLO_WAITING_DIR' "$config_file"
}

# True if the config already references a hooks.PermissionRequest table —
# then we leave the user's hook configuration entirely alone (and our :0:0
# trust key would target their hook, not ours).
codex_yolo_config_has_permission_request_hook() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1

    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+#.*$/, "", line)
            line = trim(line)
            if (line ~ /^\[\[?[[:space:]]*hooks\.PermissionRequest([.]|[[:space:]]*\])/) { found = 1; exit }
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"
}

# Append the existing PermissionRequest marker hook and pre-trust it: the
# hook is left untouched if any
# hooks.PermissionRequest config already exists, and the trust entry is added
# only for our own command when it is not yet trusted.
codex_yolo_configure_permission_hook() {
    local config_file="$1"

    if ! codex_yolo_config_has_permission_request_hook "$config_file"; then
        codex_yolo_permission_hook_block >> "$config_file" || return 1
        log_info "Configured Codex approval-marker hook (hooks.PermissionRequest): $config_file"
    fi

    if codex_yolo_config_has_permission_hook_command "$config_file" \
        && ! codex_yolo_config_has_permission_hook_trust "$config_file"; then
        codex_yolo_permission_hook_trust_block "$config_file" >> "$config_file" || return 1
        log_info "Pre-trusted Codex approval-marker hook: $config_file"
    fi
}

# Repair our older Stop command, or append it if no Stop hook exists. Leave
# custom hooks and all review/enablement state alone. The appended TOML blocks
# cannot be absorbed into an earlier table.
codex_yolo_configure_stop_bell() {
    local config_file="$1"

    codex_yolo_migrate_stop_bell "$config_file" || return 1
    if ! codex_yolo_config_has_stop_hook "$config_file"; then
        codex_yolo_stop_bell_block >> "$config_file" || return 1
        log_info "Configured Codex turn-complete bell (hooks.Stop): $config_file"
    fi
}

# Ensure the Codex CLI config directory, config.toml, and codex-yolo defaults exist.
ensure_codex_config() {
    local config_dir="$HOME/.codex"
    local config_file="$config_dir/config.toml"

    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" 2>/dev/null || true
        log_info "Created Codex config directory: $config_dir"
    fi

    # If no config exists, create it before reconciling the runtime defaults.
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" <<'TOML'
# Codex CLI configuration — managed by codex-yolo
# The approver daemon handles permission prompts at the terminal level.
# This preserves sandbox protection while auto-approving prompts.
TOML
        log_info "Created minimal Codex config: $config_file"
    fi

    codex_yolo_configure_runtime_defaults "$config_file"
    codex_yolo_configure_tui_status_line "$config_file"

    # Ring the terminal bell when an agent finishes its turn. Opt out with
    # CODEX_YOLO_NO_BELL=1 (mirrors the CODEX_YOLO_SKIP_* convention).
    if [[ -z "${CODEX_YOLO_NO_BELL:-}" ]]; then
        codex_yolo_configure_stop_bell "$config_file"
    fi

    # Record approval dialogs as per-pane marker files so the approver daemon
    # can recognize dialogs rendered off-screen (see approver-daemon.sh). The
    # hook only acts inside codex-yolo sessions (it needs CODEX_YOLO_WAITING_DIR
    # from the pane environment). Opt out with CODEX_YOLO_NO_PERMISSION_HOOK=1.
    if [[ -z "${CODEX_YOLO_NO_PERMISSION_HOOK:-}" ]]; then
        codex_yolo_configure_permission_hook "$config_file"
    fi
}
