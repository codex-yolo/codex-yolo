#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
eval "$(sed -n '/^build_agent_cmd()/,/^}/p' "$SCRIPT_DIR/codex-yolo")"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

CODEX_YOLO_BYPASS_CODEX_SANDBOX=0
CODEX_YOLO_FORCE_CODEX_SANDBOX=0
configure_codex_permissions auto >/dev/null

[[ -z "$CODEX_YOLO_PERMISSION_PROFILE" ]] || fail "default should not select a named permission profile"
[[ "$CODEX_YOLO_ASK_FOR_APPROVAL" == "1" ]] || fail "default should enable Ask for approval"

permission_args="$(codex_yolo_permission_config_arg)"
[[ "$permission_args" == *"--sandbox workspace-write"* ]] || fail "default should use workspace-write"
[[ "$permission_args" == *"--ask-for-approval on-request"* ]] || fail "default should use on-request approvals"
[[ "$permission_args" == *'approvals_reviewer="user"'* ]] || fail "default should use user review"

agent_cmd="$(build_agent_cmd "" "" "")"
[[ "$agent_cmd" == *"--sandbox workspace-write"* ]] || fail "agent command is missing workspace-write"
[[ "$agent_cmd" == *"--ask-for-approval on-request"* ]] || fail "agent command is missing on-request approvals"
[[ "$agent_cmd" != *"--yolo"* ]] || fail "default agent command must not request yolo"

configure_codex_permissions full-access >/dev/null
[[ "$CODEX_YOLO_ASK_FOR_APPROVAL" == "0" ]] || fail "explicit Full Access should disable the manual default"
[[ "$CODEX_YOLO_PERMISSION_PROFILE" == "full-access" ]] || fail "explicit Full Access profile was not preserved"

configure_codex_permissions auto >/dev/null
CODEX_YOLO_BYPASS_CODEX_SANDBOX=1
[[ -z "$(codex_yolo_permission_config_arg)" ]] || fail "explicit no-sandbox mode should suppress manual approval flags"

printf 'PASS: default permissions use Ask for approval\n'
