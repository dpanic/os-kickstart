# Kickstart

by **Dusan Panic** \<dpanic@gmail.com\>

Bootstrap a full dev environment on **Ubuntu 24.04** or **macOS** in one shot.

## Quick start

```bash
git clone https://github.com/dpanic/ubuntu-kickstart.git
cd ubuntu-kickstart
./main.sh
```

`main.sh` launches an interactive TUI (powered by [gum](https://github.com/charmbracelet/gum)) where you pick which scripts to run. It auto-installs `gum` if missing (via apt on Linux, Homebrew on macOS).

## Platform support

| Script | Linux | macOS |
|--------|:-----:|:-----:|
| gnome-optimize.sh | ✓ | — |
| nautilus-optimize.sh | ✓ | — |
| apparmor-setup.sh | ✓ | — |
| install-shell-tools.sh | ✓ | ✓ |
| install-terminal-tools.sh | ✓ | ✓ (tmux only, no byobu) |
| install-docker.sh | ✓ (Engine) | ✓ (Desktop) |
| install-yazi.sh | ✓ | ✓ |
| install-neovim.sh | ✓ | ✓ |
| install-peazip.sh | ✓ | — |

Linux-only scripts are automatically hidden from the menu on macOS.

## Scripts

### System Optimization (Linux only)

#### `gnome-optimize.sh`

Disables GNOME animations, event sounds, hot corners, and non-essential shell extensions.

Edit the `KEEP_EXTENSIONS` array at the top to customize which extensions to keep.

#### `nautilus-optimize.sh`

Restricts Tracker file indexing (removes `~/Downloads` and recursive `$HOME` from index), limits thumbnail generation to local files under 1MB, and clears the thumbnail cache.

#### `apparmor-setup.sh`

Installs AppArmor utilities, switches all profiles to complain (learning) mode, and sets a systemd timer to send a Slack reminder after 7 days. Does **not** auto-enforce -- you review with `aa-logprof` and enforce manually.

```bash
sudo ./apparmor-setup.sh https://hooks.slack.com/services/T.../B.../xxx
```

### Dev Tools

#### `install-shell-tools.sh`

Sets up a complete zsh environment: oh-my-zsh, fzf (from git), starship prompt, direnv, zsh-autosuggestions, zsh-syntax-highlighting, nvm, and git config (LFS, SSH-over-HTTPS). Deploys starship.toml, gitconfig, and a reference .zshrc template.

On macOS, zsh is already the default shell; the script skips the zsh install and proceeds with the rest.

#### `install-terminal-tools.sh`

Linux: installs [byobu](https://www.byobu.org/) (tmux backend) + [ncdu](https://dev.yorhel.nl/ncdu). Deploys byobu config with mouse support and custom status bar.

macOS: installs tmux + ncdu via Homebrew (byobu is not available on macOS).

#### `install-docker.sh`

Linux: installs [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) + Compose + BuildX from the official Docker apt repo. Adds current user to the docker group and deploys an optimized `daemon.json`.

macOS: installs [Docker Desktop](https://www.docker.com/products/docker-desktop/) via `brew install --cask docker`.

#### `install-yazi.sh`

Installs [Yazi](https://github.com/sxyazi/yazi) terminal file manager. Linux uses the latest GitHub release (.deb), macOS uses Homebrew. Creates a cd-on-exit shell wrapper.

#### `install-neovim.sh`

Installs Neovim + [LazyVim](https://www.lazyvim.org/) starter config + dependencies (ripgrep, fd, lazygit). Linux downloads the tarball from GitHub releases, macOS uses Homebrew. Backs up existing nvim config if present.

#### `install-peazip.sh`

Linux only. Installs [PeaZip](https://peazip.github.io/) archiver from the latest GitHub release (.deb). Handles 200+ archive formats and integrates with Nautilus context menu.

## File structure

```
ubuntu-kickstart/
├── main.sh                           # TUI launcher (gum)
├── scripts/
│   ├── lib.sh                        # Shared helpers (OS detection, pkg_install)
│   ├── gnome-optimize.sh             # GNOME desktop optimization (Linux)
│   ├── nautilus-optimize.sh          # Nautilus / Tracker optimization (Linux)
│   ├── apparmor-setup.sh             # AppArmor learning mode setup (Linux)
│   ├── install-shell-tools.sh        # zsh + oh-my-zsh + fzf + starship + direnv + nvm + git
│   ├── install-terminal-tools.sh     # byobu + tmux + ncdu
│   ├── install-docker.sh             # Docker Engine/Desktop
│   ├── install-yazi.sh               # Yazi terminal file manager
│   ├── install-neovim.sh             # Neovim + LazyVim + deps
│   └── install-peazip.sh             # PeaZip archiver (Linux)
├── configs/
│   ├── starship.toml                 # Starship prompt config
│   ├── zshrc.template                # Reference .zshrc with plugins & integrations
│   ├── gitconfig.template            # Git config (LFS, SSH-over-HTTPS)
│   ├── docker-daemon.json            # Docker daemon config (logging, concurrency)
│   └── byobu/                        # Byobu/tmux config (mouse, keybindings, status bar)
└── README.md
```

## Requirements

- **Linux**: Ubuntu 24.04 with GNOME 46
- **macOS**: Homebrew (auto-installed if missing)
- `apparmor-setup.sh` requires root (sudo) and a Slack webhook URL
- Internet connection required (scripts download from GitHub / Homebrew)

## What stays untouched

- No packages are removed, only settings are changed
- Existing `~/.zshrc` is never overwritten (instructions printed instead)
- Existing `~/.config/nvim` is backed up before LazyVim clone
- Snap-related AppArmor profiles stay in enforce mode (kernel-level)
