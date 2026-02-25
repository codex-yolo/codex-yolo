#!/usr/bin/env bash
# install.sh — Install codex-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash
set -euo pipefail

REPO="https://github.com/codex-yolo/codex-yolo.git"
INSTALL_DIR="${CODEX_YOLO_HOME:-$HOME/.codex-yolo}"
BIN_DIR="$HOME/.local/bin"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}WARNING:${RESET} %s\n" "$*"; }
error() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
command -v git  &>/dev/null || error "git is required but not installed"

# -------------------------------------------------------------------
# Detect OS
# -------------------------------------------------------------------
OS="$(uname -s)"
IS_WSL=0
case "$OS" in
    Linux*)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            info "Detected platform: WSL (Windows Subsystem for Linux)"
            IS_WSL=1
        else
            info "Detected platform: Linux"
        fi
        ;;
    Darwin*)
        info "Detected platform: macOS"
        ;;
    *)
        warn "Unrecognized platform: $OS — proceeding anyway"
        ;;
esac

# -------------------------------------------------------------------
# Install tmux if missing
# -------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
    info "tmux is not installed — attempting to install"
    if [[ "$OS" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install tmux
        else
            error "tmux is required. Install Homebrew (https://brew.sh) then run: brew install tmux"
        fi
    elif [[ "$OS" == Linux* ]]; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y tmux
        elif command -v yum &>/dev/null; then
            sudo yum install -y tmux
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm tmux
        elif command -v apk &>/dev/null; then
            sudo apk add tmux
        else
            error "tmux is required but no supported package manager found. Install tmux manually."
        fi
    else
        error "tmux is required. Install it manually for your platform."
    fi
    command -v tmux &>/dev/null || error "tmux installation failed — install it manually and re-run"
    info "tmux installed successfully"
fi

# -------------------------------------------------------------------
# Install Codex CLI if missing
# -------------------------------------------------------------------
if ! command -v codex &>/dev/null; then
    info "Codex CLI is not installed — installing via npm"
    if ! command -v npm &>/dev/null; then
        error "npm is required to install Codex CLI. Install Node.js/npm first: https://nodejs.org"
    fi
    npm install -g @openai/codex || error "Failed to install Codex CLI"
    command -v codex &>/dev/null || warn "Codex CLI installed but not found in PATH — you may need to restart your shell"
fi

# -------------------------------------------------------------------
# Install / update
# -------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation in $INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout . 2>/dev/null
    git -C "$INSTALL_DIR" pull --ff-only || error "Failed to update. Resolve manually in $INSTALL_DIR"
else
    if [[ -d "$INSTALL_DIR" ]]; then
        error "$INSTALL_DIR already exists but is not a git repo. Remove it first and re-run."
    fi
    info "Cloning codex-yolo into $INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR" || error "Failed to clone repository"
fi

chmod +x "$INSTALL_DIR/codex-yolo"

# -------------------------------------------------------------------
# Symlink into PATH
# -------------------------------------------------------------------
mkdir -p "$BIN_DIR"

ln -sf "$INSTALL_DIR/codex-yolo" "$BIN_DIR/codex-yolo"
info "Linked codex-yolo → $BIN_DIR/codex-yolo"

# -------------------------------------------------------------------
# Ensure ~/.local/bin is in PATH
# -------------------------------------------------------------------
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    warn "$BIN_DIR is not in your PATH"

    # Detect shell config file
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        bash) RC_FILE="$HOME/.bashrc" ;;
        fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
        *)    RC_FILE="$HOME/.profile" ;;
    esac

    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE='fish_add_path $HOME/.local/bin'
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE — you may need to restart your shell"
    else
        printf '\n# Added by codex-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
        warn "Restart your shell or run: source $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}codex-yolo installed successfully!${RESET}\n"
printf "\n  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    codex-yolo \"fix the tests\" \"update docs\"\n\n"
