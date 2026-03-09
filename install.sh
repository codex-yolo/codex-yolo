#!/usr/bin/env bash
# install.sh — Install codex-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash && source ~/.bashrc
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

# Detect Termux (Android) — no sudo, uses pkg
IS_TERMUX=0
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
    IS_TERMUX=1
fi

# Install a package using the appropriate package manager
# Usage: install_pkg <package_name>
install_pkg() {
    local pkg="$1"
    local os="$(uname -s)"
    if [[ "$os" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install "$pkg"
        else
            error "$pkg is required. Install Homebrew (https://brew.sh) then run: brew install $pkg"
        fi
    elif [[ "$os" == Linux* ]]; then
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            pkg install -y "$pkg"
        elif command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y "$pkg"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "$pkg"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm "$pkg"
        elif command -v apk &>/dev/null; then
            sudo apk add "$pkg"
        else
            error "$pkg is required but no supported package manager found. Install $pkg manually."
        fi
    else
        error "$pkg is required. Install it manually for your platform."
    fi
}

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
if ! command -v git &>/dev/null; then
    info "git is not installed — attempting to install"
    install_pkg git
    command -v git &>/dev/null || error "git installation failed — install it manually and re-run"
    info "git installed successfully"
fi

# -------------------------------------------------------------------
# Detect OS
# -------------------------------------------------------------------
OS="$(uname -s)"
IS_WSL=0
case "$OS" in
    Linux*)
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            info "Detected platform: Termux (Android)"
        elif grep -qi microsoft /proc/version 2>/dev/null; then
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
    install_pkg tmux
    command -v tmux &>/dev/null || error "tmux installation failed — install it manually and re-run"
    info "tmux installed successfully"
fi

# -------------------------------------------------------------------
# Install Codex CLI if missing
# -------------------------------------------------------------------
if ! command -v codex &>/dev/null; then
    info "Codex CLI is not installed — installing via npm"
    if [[ "$IS_TERMUX" -eq 1 ]]; then
        if ! command -v npm &>/dev/null; then
            info "npm is not installed — installing via pkg"
            pkg install -y nodejs
        fi
        # Codex CLI ships platform-specific native binaries as optional deps.
        # On Termux the standard linux-arm64 binary fails under Android's
        # linker, so npm silently skips it.  We must patch the launcher to
        # avoid the hard "Missing optional dependency" throw at startup.
        npm install -g @openai/codex || error "Failed to install Codex CLI"
        # Locate the installed entrypoint and patch out the native-binary check
        CODEX_BIN="$(npm root -g)/@openai/codex/bin/codex.js"
        if [[ -f "$CODEX_BIN" ]]; then
            # The launcher throws when the platform package is missing.
            # Replace the throw with a no-op so the pure-JS fallback is used.
            if grep -q 'throw new Error.*Missing optional dependency' "$CODEX_BIN" 2>/dev/null; then
                sed -i 's/throw new Error.*Missing optional dependency[^)]*)/\/\/ patched for Termux: native binary unavailable/' "$CODEX_BIN"
                info "Patched Codex CLI for Termux compatibility"
            fi
        fi
    else
        if ! command -v npm &>/dev/null; then
            error "npm is required to install Codex CLI. Install Node.js/npm first: https://nodejs.org"
        fi
        npm install -g @openai/codex || error "Failed to install Codex CLI"
    fi
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
# Detect shell config file
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.profile" ;;
esac

PATH_NEEDED=0
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    PATH_NEEDED=1

    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE='fish_add_path $HOME/.local/bin'
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE"
    else
        printf '\n# Added by codex-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}codex-yolo installed successfully!${RESET}\n"

if [[ "$PATH_NEEDED" -eq 1 ]]; then
printf "\n  Run this to start using codex-yolo now:\n\n"
printf "    source %s\n\n" "$RC_FILE"
fi
printf "  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    codex-yolo \"fix the tests\" \"update docs\"\n\n"
