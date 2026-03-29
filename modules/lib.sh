#!/bin/bash
# Shared helpers for all kickstart scripts
# Source from a module script: source "$REPO_DIR/lib.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

skip()    { echo -e "  ${GREEN}[SKIP]${NC} $1"; }
install() { echo -e "  ${YELLOW}[INSTALL]${NC} $1"; }
update()  { echo -e "  ${CYAN}[UPDATE]${NC} $1"; }
remove()  { echo -e "  ${RED}[REMOVE]${NC} $1"; }

# Action flags: --update refreshes to latest, --uninstall removes
UPDATE=false
UNINSTALL=false
_CLEAN_ARGS=()
parse_update_flag() {
    UPDATE=false
    UNINSTALL=false
    _CLEAN_ARGS=()
    for a in "$@"; do
        if [[ "$a" == "--update" ]]; then
            UPDATE=true
        elif [[ "$a" == "--uninstall" ]]; then
            UNINSTALL=true
        else
            _CLEAN_ARGS+=("$a")
        fi
    done
}

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

# Reliable update for shallow git clones (git pull often fails with divergent branches)
git_update_shallow() {
    local dir="$1"
    local branch
    branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || branch="master"
    git -C "$dir" fetch origin --depth=1 -q
    git -C "$dir" reset --hard "origin/$branch"
}
