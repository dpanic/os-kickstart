<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 24.04" />
  <img src="https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS" />
  <img src="https://img.shields.io/badge/Go-Binary-00ADD8?style=flat-square&logo=go&logoColor=white" alt="Go" />
  <img src="https://img.shields.io/badge/TUI-Bubble_Tea-FF69B4?style=flat-square" alt="Bubble Tea TUI" />
</p>

# OS Kickstart

> **One binary to bootstrap a full dev environment on Ubuntu or macOS.**

by **Dusan Panic** \<dpanic@gmail.com\>

---

## Quick Start

**Download the latest release:**

```bash
curl -sSL https://github.com/dpanic/os-kickstart/releases/latest/download/kickstart_linux_amd64.tar.gz | tar xz
./kickstart
```

**Or build from source:**

```bash
git clone https://github.com/dpanic/os-kickstart.git
cd os-kickstart
make build
./kickstart
```

**Or install via Go:**

```bash
go install github.com/dpanic/os-kickstart@latest
```

---

## Features

- **Single binary** — all shell scripts and configs embedded via `go:embed`, zero dependencies
- **Interactive TUI** — multi-select menu with categories, search filter, scroll viewport
- **Install / Update / Uninstall** — fresh install, refresh to latest, or clean removal
- **Idempotent** — safe to re-run, skips what's already installed
- **Cross-platform** — Ubuntu 24.04 + macOS (Linux-only items auto-hidden on Mac)
- **Async update checks** — checks GitHub releases and go.dev for new versions in background
- **Installed detection** — shows `[installed X.Y.Z]` for tools already on the system

---

## What's Included

### Optimizations *(Linux only)*

| Module | Description |
|--------|-------------|
| GNOME Optimize | Disable animations, sounds, hot corners, non-essential extensions |
| Nautilus Optimize | Restrict Tracker indexing, limit thumbnails, clear cache |
| AppArmor Setup | Learning mode + Slack reminder after 7 days |
| Kernel sysctl | Network, memory, conntrack tuning |
| Kernel limits | File descriptor & process limits |
| Kernel I/O scheduler | `none` for SSD/NVMe |
| Kernel autotune | RAM-based dynamic kernel params at boot |
| SSH hardening | OpenSSH server hardening (disables password auth) |

### Installations

#### Shell

| Component | Description |
|-----------|-------------|
| zsh + oh-my-zsh | Modern shell with plugin framework |
| fzf | Fuzzy finder |
| starship | Cross-shell prompt with custom config |
| direnv | Per-directory environment variables |
| zsh plugins | autosuggestions + syntax-highlighting |
| nvm | Node.js version manager |
| byobu + tmux | Terminal multiplexer with mouse support *(Linux)* |
| git config | LFS, SSH-over-HTTPS, gitconfig template |

#### Terminal

| Tool | Description |
|------|-------------|
| ncdu | Interactive disk usage analyzer |
| Yazi | Blazing-fast terminal file manager |

#### Dev Tools

| Tool | Description |
|------|-------------|
| Docker | Engine + Compose + BuildX + daemon config |
| Go | Latest from go.dev |
| Neovim + LazyVim | IDE-grade editor with ripgrep, fd, lazygit |

#### Browsers & Apps *(Linux only)*

| App | Description |
|-----|-------------|
| Google Chrome | APT repo |
| Brave | APT repo |
| Signal Desktop | APT repo |
| PeaZip | Archive manager (200+ formats) |

---

## TUI Controls

| Key | Action |
|-----|--------|
| `Up/Down` | Navigate |
| `Space` | Toggle selection |
| `Ctrl+A` | Select / deselect all |
| `/` | Filter / search |
| `Enter` | Confirm |
| `Esc` | Clear filter / go back |
| `q` | Quit |

---

## Modes

After selecting items, choose a mode:

| Mode | Description |
|------|-------------|
| **Install** | Fresh install, skips already-installed items |
| **Update** | Refresh to latest versions |
| **Uninstall** | Remove installed tools, revert optimizations from backups |

Status badges in the menu:

- `[installed X.Y.Z]` — installed with version
- **`[update X.Y.Z -> A.B.C]`** — newer version available (bold white)
- `[installed]` — installed, version unknown

---

## Requirements

| | Requirement |
|-|-------------|
| Linux | Ubuntu 24.04 with GNOME 46 |
| macOS | macOS with Homebrew |
| Network | Internet connection for downloads |

---

## Build & Release

```bash
make build           # Build binary
make test            # Run tests
make run             # Run from source
make release-local   # GoReleaser snapshot
```

Releases are automated via GitHub Actions — push a `v*` tag to create a release with binaries for linux/amd64, linux/arm64, darwin/amd64, darwin/arm64.

---

## Safety

- Existing `~/.zshrc` is never overwritten (instructions printed instead)
- Existing `~/.config/nvim` is backed up before LazyVim clone
- Snap-related AppArmor profiles stay in enforce mode
- **Uninstall** restores system configs from `.bak-kickstart` backups
- Docker data (`/var/lib/docker`) is preserved on uninstall

---

## License

MIT

---

<p align="center">
  <sub>Built with <a href="https://github.com/charmbracelet/bubbletea">Bubble Tea</a></sub>
</p>
