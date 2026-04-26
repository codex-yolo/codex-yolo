#!/usr/bin/env bash
# install.sh — Install codex-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash && export PATH="$HOME/.local/bin:$PATH"
#        ./install.sh --local   # install from the current local repo
set -euo pipefail

LOCAL_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL_INSTALL=1 ;;
        *) ;;
    esac
done

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

# Use sudo only if not already root and sudo is available
SUDO=""
if [[ "$IS_TERMUX" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        warn "Not running as root and sudo is not available — package installs may fail"
    fi
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
            $SUDO apt-get update && $SUDO apt-get install -y "$pkg"
        elif command -v dnf &>/dev/null; then
            $SUDO dnf install -y "$pkg"
        elif command -v yum &>/dev/null; then
            $SUDO yum install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            $SUDO pacman -S --noconfirm "$pkg"
        elif command -v apk &>/dev/null; then
            $SUDO apk add "$pkg"
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
if ! command -v curl &>/dev/null; then
    info "curl is not installed — attempting to install"
    install_pkg curl
    command -v curl &>/dev/null || error "curl installation failed — install it manually and re-run"
    info "curl installed successfully"
fi

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
    info "Codex CLI is not installed — installing"
    CODEX_INSTALLED=0

    _ensure_npm() {
        if command -v npm &>/dev/null; then return 0; fi
        info "npm is not installed — attempting to install Node.js"
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            pkg install -y nodejs
        else
            install_pkg nodejs
            # Some distros package npm separately
            command -v npm &>/dev/null || install_pkg npm
        fi
    }

    _ensure_npm
    if command -v npm &>/dev/null; then
        npm install -g @openai/codex 2>/dev/null && CODEX_INSTALLED=1
    fi

    # Verify codex actually works (some platforms install but fail at runtime)
    if [[ "$CODEX_INSTALLED" -eq 1 ]] && ! codex --version &>/dev/null; then
        warn "@openai/codex installed but 'codex --version' failed — falling back to @mmmbuto/codex-cli-termux"
        npm uninstall -g @openai/codex 2>/dev/null || true
        npm install -g @mmmbuto/codex-cli-termux 2>/dev/null && CODEX_INSTALLED=1 || CODEX_INSTALLED=0
    fi

    # If distro Node.js failed (common on aarch64 with 64KB pages),
    # try NodeSource v22 with proper Node.js
    if [[ "$CODEX_INSTALLED" -eq 0 ]] && command -v apt-get &>/dev/null; then
        warn "npm install failed — trying with Node.js 22 via NodeSource"
        # Remove conflicting distro Node.js packages before installing NodeSource
        $SUDO apt-get remove -y nodejs libnode-dev libnode72 2>/dev/null || true
        $SUDO apt-get autoremove -y 2>/dev/null || true
        if curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh 2>/dev/null; then
            $SUDO bash /tmp/nodesource_setup.sh 2>/dev/null
            # Use --force-overwrite in case distro libnode-dev wasn't fully removed
            $SUDO apt-get install -y -o Dpkg::Options::="--force-overwrite" nodejs 2>/dev/null
            rm -f /tmp/nodesource_setup.sh
        fi
        if command -v npm &>/dev/null; then
            npm install -g @openai/codex 2>/dev/null && CODEX_INSTALLED=1
            # Verify codex works after NodeSource install too
            if [[ "$CODEX_INSTALLED" -eq 1 ]] && ! codex --version &>/dev/null; then
                warn "@openai/codex installed but 'codex --version' failed — falling back to @mmmbuto/codex-cli-termux"
                npm uninstall -g @openai/codex 2>/dev/null || true
                npm install -g @mmmbuto/codex-cli-termux 2>/dev/null && CODEX_INSTALLED=1 || CODEX_INSTALLED=0
            fi
        else
            warn "npm is not available — cannot install Codex CLI"
        fi
    fi

    if ! command -v codex &>/dev/null; then
        ARCH="$(uname -m)"
        error "Codex CLI could not be installed (platform: $OS, arch: $ARCH). Install it manually: npm install -g @openai/codex"
    fi
fi

# -------------------------------------------------------------------
# Install / update
# -------------------------------------------------------------------
if [[ "$LOCAL_INSTALL" -eq 1 ]]; then
    LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info "Installing from local repo: $LOCAL_SRC"
    if [[ "$LOCAL_SRC" == "$INSTALL_DIR" ]]; then
        info "Local repo is already the install directory — skipping copy"
    else
        mkdir -p "$INSTALL_DIR"
        rsync -a --exclude='.git' "$LOCAL_SRC/" "$INSTALL_DIR/" 2>/dev/null \
            || cp -a "$LOCAL_SRC"/. "$INSTALL_DIR"/
        info "Copied local repo to $INSTALL_DIR"
    fi
elif [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation in $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch origin 2>/dev/null
    git -C "$INSTALL_DIR" reset --hard origin/main 2>/dev/null || error "Failed to update. Resolve manually in $INSTALL_DIR"
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
# Detect the running shell reliably: $SHELL may be /bin/sh in Docker
# even when the user is actually running bash.
_detect_shell() {
    local sh_name
    sh_name="$(basename "${SHELL:-}")"
    # If $SHELL says sh, check if we're actually running bash/zsh
    if [[ "$sh_name" == "sh" ]] || [[ -z "$sh_name" ]]; then
        if [[ -n "${BASH_VERSION:-}" ]]; then
            sh_name="bash"
        elif [[ -n "${ZSH_VERSION:-}" ]]; then
            sh_name="zsh"
        fi
    fi
    echo "$sh_name"
}

SHELL_NAME="$(_detect_shell)"
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.profile" ;;
esac

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE='fish_add_path $HOME/.local/bin'
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE"
    else
        touch "$RC_FILE"
        printf '\n# Added by codex-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}codex-yolo installed successfully!${RESET}\n"
printf "\n  Activate now (if codex-yolo is not yet available):\n\n"
printf "    source %s\n\n" "$RC_FILE"
printf "  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    codex-yolo \"fix the tests\" \"update docs\"\n\n"

# Export PATH in the current process so that when this script is sourced
# or when the caller does `source <rc_file>`, the binary is immediately available.
export PATH="$BIN_DIR:$PATH"
