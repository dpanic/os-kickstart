#!/bin/bash
set -euo pipefail

# Install Neovim + LazyVim starter config + dependencies
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"

NVIM_INSTALL_DIR="/opt/nvim-linux-x86_64"

parse_update_flag "$@"

TITLE="Setup"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== Neovim + LazyVim $TITLE ==="
echo ""

if [[ "$UNINSTALL" == true ]]; then
    # neovim
    if command -v nvim &>/dev/null; then
        remove "removing neovim"
        if is_macos; then
            brew uninstall neovim 2>/dev/null || true
        elif is_linux; then
            sudo rm -rf "$NVIM_INSTALL_DIR" /usr/local/bin/nvim
        fi
    else
        skip "neovim not installed"
    fi

    # lazygit
    if command -v lazygit &>/dev/null; then
        remove "removing lazygit"
        if is_macos; then
            brew uninstall lazygit 2>/dev/null || true
        elif is_linux; then
            sudo rm -f /usr/local/bin/lazygit
        fi
    else
        skip "lazygit not installed"
    fi

    # ripgrep + fd
    if is_linux; then
        command -v rg &>/dev/null && { remove "removing ripgrep"; sudo apt-get remove -y ripgrep 2>/dev/null || true; }
        (command -v fdfind &>/dev/null || command -v fd &>/dev/null) && { remove "removing fd-find"; sudo apt-get remove -y fd-find 2>/dev/null || true; }
    elif is_macos; then
        command -v rg &>/dev/null && { remove "removing ripgrep"; brew uninstall ripgrep 2>/dev/null || true; }
        command -v fd &>/dev/null && { remove "removing fd"; brew uninstall fd 2>/dev/null || true; }
    fi

    # nvim config
    if [[ -d "$HOME/.config/nvim" ]]; then
        remove "removing ~/.config/nvim"
        rm -rf "$HOME/.config/nvim"
    fi

    # nvim data
    if [[ -d "$HOME/.local/share/nvim" ]]; then
        remove "removing ~/.local/share/nvim"
        rm -rf "$HOME/.local/share/nvim"
    fi

    echo ""
    echo "=== Neovim uninstall complete ==="
    exit 0
fi

# [1/4] Neovim via Homebrew (macOS) or GitHub release tarball (Linux x86_64)
echo "[1/4] neovim..."
install_nvim_linux() {
    local label="$1"
    $label "downloading latest neovim from GitHub releases"
    TMP_DIR=$(mktemp -d /tmp/nvim-XXXXXX)
    NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
    echo "  downloading: $NVIM_URL"
    curl -fsSL "$NVIM_URL" | tar -xz -C "$TMP_DIR"
    sudo rm -rf "$NVIM_INSTALL_DIR"
    sudo mv "$TMP_DIR/nvim-linux-x86_64" "$NVIM_INSTALL_DIR"
    sudo ln -sf "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim
    rm -rf "$TMP_DIR"
    echo "  installed: $(nvim --version | head -1)"
}

if command -v nvim &>/dev/null && nvim --version &>/dev/null; then
    if [[ "$UPDATE" == true ]]; then
        if is_macos; then
            update "updating neovim via brew"
            brew upgrade neovim 2>/dev/null || skip "neovim already at latest"
        elif is_linux; then
            install_nvim_linux update
        fi
    else
        skip "nvim $(nvim --version | head -1) already installed"
    fi
else
    if is_macos; then
        pkg_install neovim
    elif is_linux; then
        install_nvim_linux install
    fi
fi

# [2/4] ripgrep + fd (brew: fd; apt: fd-find)
echo "[2/4] ripgrep + fd-find..."
PKGS_TO_INSTALL=()
if command -v rg &>/dev/null; then
    skip "ripgrep $(rg --version | head -1) already installed"
else
    PKGS_TO_INSTALL+=(ripgrep)
fi

if command -v fdfind &>/dev/null || command -v fd &>/dev/null; then
    skip "fd-find already installed"
else
    if is_macos; then
        PKGS_TO_INSTALL+=(fd)
    else
        PKGS_TO_INSTALL+=(fd-find)
    fi
fi

if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
    install "installing ${PKGS_TO_INSTALL[*]}"
    pkg_install "${PKGS_TO_INSTALL[@]}"
fi

# [3/4] lazygit
echo "[3/4] lazygit..."
install_lazygit_linux() {
    local label="$1"
    $label "downloading latest lazygit from GitHub"
    LAZYGIT_VERSION=$(curl -fsSI https://github.com/jesseduffield/lazygit/releases/latest 2>/dev/null \
        | grep -i '^location:' | sed 's|.*/v||' | tr -d '\r\n')

    if [[ -z "$LAZYGIT_VERSION" ]]; then
        echo "  ERROR: could not determine latest lazygit version"
        exit 1
    fi

    TMP_DIR=$(mktemp -d /tmp/lazygit-XXXXXX)
    LAZYGIT_URL="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    echo "  downloading: $LAZYGIT_URL"
    curl -fsSL "$LAZYGIT_URL" | tar -xz -C "$TMP_DIR"
    sudo mv "$TMP_DIR/lazygit" /usr/local/bin/lazygit
    sudo chmod +x /usr/local/bin/lazygit
    rm -rf "$TMP_DIR"
    echo "  installed: lazygit $LAZYGIT_VERSION"
}

if command -v lazygit &>/dev/null; then
    if [[ "$UPDATE" == true ]]; then
        if is_macos; then
            update "updating lazygit via brew"
            brew upgrade lazygit 2>/dev/null || skip "lazygit already at latest"
        elif is_linux; then
            install_lazygit_linux update
        fi
    else
        skip "lazygit already installed"
    fi
else
    if is_macos; then
        pkg_install lazygit
    elif is_linux; then
        install_lazygit_linux install
    fi
fi

# [4/4] LazyVim starter config
echo "[4/4] LazyVim config..."
NVIM_CONFIG="$HOME/.config/nvim"
if [[ -d "$NVIM_CONFIG" ]]; then
    if [[ -f "$NVIM_CONFIG/lazyvim.json" ]] || [[ -f "$NVIM_CONFIG/lazy-lock.json" ]]; then
        skip "LazyVim config already present at ~/.config/nvim/"
    else
        BACKUP="${NVIM_CONFIG}.bak.$(date +%s)"
        install "backing up existing nvim config to $BACKUP"
        mv "$NVIM_CONFIG" "$BACKUP"
        git clone --depth=1 https://github.com/LazyVim/starter "$NVIM_CONFIG"
        rm -rf "$NVIM_CONFIG/.git"
    fi
else
    install "cloning LazyVim starter to ~/.config/nvim/"
    git clone --depth=1 https://github.com/LazyVim/starter "$NVIM_CONFIG"
    rm -rf "$NVIM_CONFIG/.git"
fi

echo ""
echo "=== Neovim + LazyVim setup complete ==="
echo ""
echo "Run 'nvim' to launch. LazyVim will auto-install plugins on first start."
echo ""
echo "Recommended: add to your .zshrc:"
echo '  export EDITOR=nvim'
