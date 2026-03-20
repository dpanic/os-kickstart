#!/bin/bash
# Shared helpers for all kickstart scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

skip()    { echo -e "  ${GREEN}[SKIP]${NC} $1"; }
install() { echo -e "  ${YELLOW}[INSTALL]${NC} $1"; }

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

OS="$(detect_os)"

ensure_brew() {
    if command -v brew &>/dev/null; then
        return
    fi
    echo "Homebrew not found -- installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
}

pkg_install() {
    if [[ "$OS" == "macos" ]]; then
        ensure_brew
        brew install "$@"
    else
        sudo apt-get update -qq
        sudo apt-get install -y "$@"
    fi
}

cask_install() {
    if [[ "$OS" == "macos" ]]; then
        ensure_brew
        brew install --cask "$@"
    else
        echo "cask_install is macOS-only" >&2
        return 1
    fi
}

is_macos() { [[ "$OS" == "macos" ]]; }
is_linux() { [[ "$OS" == "linux" ]]; }
