#!/bin/bash
set -euo pipefail

# Install Neovim + LazyVim starter config + dependencies
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

NVIM_INSTALL_DIR="/opt/nvim-linux-x86_64"

echo "=== Neovim + LazyVim Setup ==="
echo ""

# [1/4] Neovim via Homebrew (macOS) or GitHub release tarball (Linux x86_64)
echo "[1/4] neovim..."
if command -v nvim &>/dev/null && nvim --version &>/dev/null; then
    skip "nvim $(nvim --version | head -1) already installed"
else
    if is_macos; then
        pkg_install neovim
    fi
    if is_linux; then
        install "downloading latest neovim from GitHub releases"
        TMP_DIR=$(mktemp -d /tmp/nvim-XXXXXX)
        NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
        echo "  downloading: $NVIM_URL"
        curl -fsSL "$NVIM_URL" | tar -xz -C "$TMP_DIR"
        sudo rm -rf "$NVIM_INSTALL_DIR"
        sudo mv "$TMP_DIR/nvim-linux-x86_64" "$NVIM_INSTALL_DIR"
        sudo ln -sf "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim
        rm -rf "$TMP_DIR"
        echo "  installed: $(nvim --version | head -1)"
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
if command -v lazygit &>/dev/null; then
    skip "lazygit already installed"
else
    if is_macos; then
        pkg_install lazygit
    fi
    if is_linux; then
        install "downloading latest lazygit from GitHub"
        LAZYGIT_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name"' | sed 's/.*"v\?\([^"]*\)".*/\1/')

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
