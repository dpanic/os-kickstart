#!/bin/bash
set -euo pipefail

# Install shell tooling: zsh, oh-my-zsh, fzf, starship, direnv, plugins, nvm, byobu, git
# Author: Dusan Panic <dpanic@gmail.com>
# Replicates a full zsh dev environment from scratch
# Safe to re-run -- idempotent (skips already-installed components)
#
# Usage:
#   ./install-shell-tools.sh              # install everything
#   ./install-shell-tools.sh fzf byobu    # install only listed components

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

ALL_COMPONENTS=(zsh fzf starship direnv plugins nvm byobu git)
parse_update_flag "$@"
COMPONENTS=("${_CLEAN_ARGS[@]}")
if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    COMPONENTS=("${ALL_COMPONENTS[@]}")
fi

want() {
    local c
    for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done
    return 1
}

STEP=0
count_steps() {
    local total=0
    for c in "${ALL_COMPONENTS[@]}"; do want "$c" && total=$((total + 1)); done
    echo "$total"
}
TOTAL=$(count_steps)
next() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $1..."; }

TITLE="Setup"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== Shell Tools $TITLE ==="
echo "  Components: ${COMPONENTS[*]}"
echo ""

# ── Uninstall mode ────────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == true ]]; then
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    if want "plugins"; then
        echo "[REMOVE] zsh plugins..."
        [[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]] && \
            { remove "zsh-autosuggestions"; rm -rf "$ZSH_CUSTOM/plugins/zsh-autosuggestions"; } || skip "zsh-autosuggestions not found"
        [[ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]] && \
            { remove "zsh-syntax-highlighting"; rm -rf "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"; } || skip "zsh-syntax-highlighting not found"
    fi

    if want "nvm"; then
        echo "[REMOVE] nvm..."
        if [[ -d "$HOME/.nvm" ]]; then
            remove "removing ~/.nvm"
            rm -rf "$HOME/.nvm"
        else
            skip "nvm not installed"
        fi
    fi

    if want "fzf"; then
        echo "[REMOVE] fzf..."
        if [[ -d "$HOME/.fzf" ]]; then
            remove "uninstalling fzf"
            "$HOME/.fzf/uninstall" --all 2>/dev/null || true
            rm -rf "$HOME/.fzf"
        else
            skip "fzf not installed"
        fi
    fi

    if want "starship"; then
        echo "[REMOVE] starship..."
        if command -v starship &>/dev/null; then
            remove "removing starship binary"
            sudo rm -f "$(command -v starship)"
        else
            skip "starship not installed"
        fi
    fi

    if want "direnv"; then
        echo "[REMOVE] direnv..."
        if command -v direnv &>/dev/null; then
            remove "removing direnv"
            if is_macos; then brew uninstall direnv 2>/dev/null || true
            else sudo apt-get remove -y direnv 2>/dev/null || true; fi
        else
            skip "direnv not installed"
        fi
    fi

    if want "git"; then
        echo "[REMOVE] git-lfs..."
        if command -v git-lfs &>/dev/null; then
            remove "removing git-lfs"
            if is_macos; then brew uninstall git-lfs 2>/dev/null || true
            else sudo apt-get remove -y git-lfs 2>/dev/null || true; fi
        else
            skip "git-lfs not installed"
        fi
    fi

    if want "byobu"; then
        echo "[REMOVE] byobu..."
        if command -v byobu &>/dev/null; then
            remove "removing byobu"
            if is_linux; then sudo apt-get remove -y byobu 2>/dev/null || true; fi
            [[ -d "$HOME/.byobu" ]] && { remove "removing ~/.byobu"; rm -rf "$HOME/.byobu"; }
        else
            skip "byobu not installed"
        fi
    fi

    if want "zsh"; then
        echo "[REMOVE] oh-my-zsh..."
        if [[ -d "$HOME/.oh-my-zsh" ]]; then
            remove "removing ~/.oh-my-zsh"
            rm -rf "$HOME/.oh-my-zsh"
        else
            skip "oh-my-zsh not installed"
        fi
        echo "  note: zsh package and default shell left intact"
    fi

    echo ""
    echo "=== Shell tools uninstall complete ==="
    exit 0
fi

# ── zsh + oh-my-zsh ──────────────────────────────────────────────────────────
if want "zsh"; then
    next "zsh + oh-my-zsh"

    if command -v zsh &>/dev/null; then
        skip "zsh $(zsh --version | head -1) already installed"
    else
        if is_linux; then
            install "installing zsh"
            pkg_install zsh
        fi
    fi

    if [[ "$(basename "$SHELL")" != "zsh" ]]; then
        install "setting zsh as default shell (requires password)"
        chsh -s "$(command -v zsh)"
    else
        skip "zsh is already the default shell"
    fi

    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        if [[ "$UPDATE" == true ]]; then
            update "updating oh-my-zsh"
            git_update_shallow "$HOME/.oh-my-zsh"
        else
            skip "oh-my-zsh already installed at ~/.oh-my-zsh"
        fi
    else
        install "cloning oh-my-zsh"
        git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
    fi
fi

# ── fzf ───────────────────────────────────────────────────────────────────────
if want "fzf"; then
    next "fzf"

    if [[ -d "$HOME/.fzf" ]]; then
        if [[ "$UPDATE" == true ]]; then
            update "updating fzf"
            git_update_shallow "$HOME/.fzf"
            "$HOME/.fzf/install" --all --no-bash --no-fish
        else
            skip "fzf already installed at ~/.fzf"
        fi
    else
        install "cloning fzf from git"
        git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
        "$HOME/.fzf/install" --all --no-bash --no-fish
    fi
fi

# ── starship ──────────────────────────────────────────────────────────────────
if want "starship"; then
    next "starship"

    if command -v starship &>/dev/null; then
        if [[ "$UPDATE" == true ]]; then
            update "updating starship"
            curl -fsSL https://starship.rs/install.sh | sh -s -- -y
        else
            skip "starship $(starship --version | head -1) already installed"
        fi
    else
        install "installing starship"
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y
    fi

    mkdir -p "$HOME/.config"
    if [[ -f "$HOME/.config/starship.toml" ]]; then
        skip "~/.config/starship.toml already exists (not overwriting)"
    else
        install "copying starship.toml"
        cp "$SCRIPT_DIR/starship.toml" "$HOME/.config/starship.toml"
    fi
fi

# ── direnv ────────────────────────────────────────────────────────────────────
if want "direnv"; then
    next "direnv"

    if command -v direnv &>/dev/null; then
        skip "direnv $(direnv version) already installed"
    else
        install "installing direnv"
        pkg_install direnv
    fi
fi

# ── zsh plugins ───────────────────────────────────────────────────────────────
if want "plugins"; then
    next "zsh plugins"

    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    if [[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        if [[ "$UPDATE" == true ]]; then
            update "updating zsh-autosuggestions"
            git_update_shallow "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
        else
            skip "zsh-autosuggestions already installed"
        fi
    else
        install "cloning zsh-autosuggestions"
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
            "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    fi

    if [[ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
        if [[ "$UPDATE" == true ]]; then
            update "updating zsh-syntax-highlighting"
            git_update_shallow "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
        else
            skip "zsh-syntax-highlighting already installed"
        fi
    else
        install "cloning zsh-syntax-highlighting"
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
            "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    fi
fi

# ── nvm ───────────────────────────────────────────────────────────────────────
if want "nvm"; then
    next "nvm"

    if [[ -d "$HOME/.nvm" ]]; then
        if [[ "$UPDATE" == true ]]; then
            update "updating nvm to latest"
            LATEST_NVM=$(curl -fsSI https://github.com/nvm-sh/nvm/releases/latest 2>/dev/null \
                | grep -i '^location:' | sed 's|.*/||' | tr -d '\r\n')
            git -C "$HOME/.nvm" fetch origin --depth=1 --tags -q
            git -C "$HOME/.nvm" checkout "$LATEST_NVM" 2>/dev/null
        else
            skip "nvm already installed at ~/.nvm"
        fi
    else
        install "installing nvm"
        LATEST_NVM=$(curl -fsSI https://github.com/nvm-sh/nvm/releases/latest 2>/dev/null \
            | grep -i '^location:' | sed 's|.*/||' | tr -d '\r\n')
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${LATEST_NVM}/install.sh" | PROFILE=/dev/null bash
    fi
fi

# ── byobu + tmux (Linux: byobu + configs; macOS: tmux only) ───────────────────
if want "byobu"; then
    next "byobu + tmux"

    if is_linux; then
        PKGS=()
        if command -v byobu &>/dev/null; then
            skip "byobu already installed"
        else
            PKGS+=(byobu)
        fi

        if command -v tmux &>/dev/null; then
            skip "tmux $(tmux -V) already installed"
        else
            PKGS+=(tmux)
        fi

        if [[ ${#PKGS[@]} -gt 0 ]]; then
            install "installing ${PKGS[*]}"
            pkg_install "${PKGS[@]}"
        fi

        BYOBU_DIR="$HOME/.byobu"
        BYOBU_CONFIGS=(".tmux.conf" ".ctrl-a-workaround" "backend" "color.tmux" "datetime.tmux" "keybindings" "keybindings.tmux" "status")

        if [[ -d "$BYOBU_DIR" ]]; then
            local_changed=0
            for cfg in "${BYOBU_CONFIGS[@]}"; do
                src="$SCRIPT_DIR/byobu/$cfg"
                dst="$BYOBU_DIR/$cfg"
                if [[ ! -f "$src" ]]; then
                    continue
                fi
                if [[ -f "$dst" ]] && diff -q "$src" "$dst" &>/dev/null; then
                    continue
                fi
                if [[ -f "$dst" ]]; then
                    install "updating $cfg (old backed up to ${cfg}.bak)"
                    cp "$dst" "${dst}.bak"
                else
                    install "copying $cfg"
                fi
                cp "$src" "$dst"
                local_changed=$((local_changed + 1))
            done
            if [[ $local_changed -eq 0 ]]; then
                skip "byobu config already up to date"
            fi
        else
            install "creating ~/.byobu/ with configs"
            mkdir -p "$BYOBU_DIR"
            for cfg in "${BYOBU_CONFIGS[@]}"; do
                src="$SCRIPT_DIR/byobu/$cfg"
                [[ -f "$src" ]] && cp "$src" "$BYOBU_DIR/$cfg"
            done
        fi

        if [[ -f "$BYOBU_DIR/backend" ]] && grep -q "tmux" "$BYOBU_DIR/backend"; then
            skip "byobu backend already set to tmux"
        else
            install "setting byobu backend to tmux"
            echo "BYOBU_BACKEND=tmux" > "$BYOBU_DIR/backend"
        fi
    fi

    if is_macos; then
        if command -v tmux &>/dev/null; then
            skip "tmux $(tmux -V) already installed"
        else
            install "installing tmux via brew"
            pkg_install tmux
        fi
    fi
fi

# ── git config ────────────────────────────────────────────────────────────────
if want "git"; then
    next "git config"

    if [[ -f "$HOME/.gitconfig" ]]; then
        skip "~/.gitconfig already exists (not overwriting)"
        echo "  Review template: $SCRIPT_DIR/gitconfig.template"
    else
        install "copying gitconfig.template -> ~/.gitconfig"
        cp "$SCRIPT_DIR/gitconfig.template" "$HOME/.gitconfig"
    fi

    if [[ -n "${KICKSTART_USER_NAME:-}" ]]; then
        git config --global user.name "$KICKSTART_USER_NAME"
        echo "  git user.name = $KICKSTART_USER_NAME"
    fi
    if [[ -n "${KICKSTART_USER_EMAIL:-}" ]]; then
        git config --global user.email "$KICKSTART_USER_EMAIL"
        echo "  git user.email = $KICKSTART_USER_EMAIL"
    fi
    if [[ -z "${KICKSTART_USER_NAME:-}" && -z "${KICKSTART_USER_EMAIL:-}" ]]; then
        current_name=$(git config --global user.name 2>/dev/null || true)
        if [[ "$current_name" == "CHANGEME" || -z "$current_name" ]]; then
            echo ""
            echo "  IMPORTANT: set your git identity:"
            echo '    git config --global user.name "Your Name"'
            echo '    git config --global user.email "your@email.com"'
        fi
    fi

    if command -v git-lfs &>/dev/null; then
        skip "git-lfs already installed"
    else
        install "installing git-lfs"
        pkg_install git-lfs
        git lfs install
    fi
fi

# ── .zshrc template ──────────────────────────────────────────────────────────
if want "zsh"; then
    if [[ -f "$HOME/.zshrc" ]]; then
        skip "~/.zshrc already exists (not overwriting)"
        echo ""
        echo "  To see what the template includes, run:"
        echo "    diff ~/.zshrc $SCRIPT_DIR/zshrc.template"
        echo ""
        echo "  Key lines to ensure are in your .zshrc:"
        echo "    plugins=(fzf git zsh-autosuggestions zsh-syntax-highlighting)"
        echo '    eval "$(starship init zsh)"'
        echo '    eval "$(direnv hook zsh)"'
        echo '    [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh'
    else
        install "copying zshrc.template -> ~/.zshrc"
        cp "$SCRIPT_DIR/zshrc.template" "$HOME/.zshrc"
    fi
fi

echo ""
echo "=== Shell tools setup complete ==="
echo "  Installed: ${COMPONENTS[*]}"
echo ""
want "byobu" && echo "  byobu  -- launch terminal multiplexer"
echo "Start a new terminal or run: exec zsh"
