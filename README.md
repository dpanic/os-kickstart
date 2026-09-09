<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 24.04" />
  <img src="https://img.shields.io/badge/Ubuntu-26.04-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 26.04" />
  <img src="https://img.shields.io/badge/macOS-Supported-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS" />
  <img src="https://img.shields.io/badge/Go-Binary-00ADD8?style=flat-square&logo=go&logoColor=white" alt="Go" />
  <img src="https://img.shields.io/badge/TUI-Bubble_Tea-FF69B4?style=flat-square" alt="Bubble Tea TUI" />
</p>

# OS Kickstart

> **One binary to bootstrap a full dev environment on Ubuntu or macOS.**

by **Dusan Panic** \<dpanic@gmail.com\>

<p align="center">
  <img src="demo.gif" alt="OS Kickstart TUI demo" width="720" />
</p>

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
- **Cross-platform** — Ubuntu 24.04 & 26.04 + macOS (Linux-only items auto-hidden on Mac)
- **Async update checks** — checks GitHub releases and go.dev for new versions in background
- **Installed detection** — shows `[installed X.Y.Z]` for tools already on the system

---

## What's Included

### Optimizations *(Linux only)*

| Module | Description |
|--------|-------------|
| GNOME Optimize | Disable animations, sounds, hot corners; flat mouse accel; faster key repeat |
| Nautilus Optimize | Restrict Tracker indexing, limit thumbnails, clear cache |
| AppArmor Setup | Learning mode + Slack reminder after 7 days |
| Kernel sysctl | Network, memory, conntrack tuning |
| Kernel limits | File descriptor & process limits |
| Kernel I/O scheduler | `none` for SSD/NVMe |
| Kernel autotune | RAM-based dynamic kernel params at boot |
| Kernel CPU governor | Performance pin, pre-boost freq cap, user RTTIME (see below) |
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

## Kernel CPU governor *(Linux, opt-in)*

Pins the CPU for desktop input latency. Skipped on laptop/tablet chassis (types 8, 9, 10, 14, 30–32); override with `KICKSTART_CPU_GOVERNOR=force`.

| Knob | What kickstart does |
|------|---------------------|
| Governor | `performance` on every cpufreq policy |
| Max freq | **Pre-boost only** — ACPI `nominal_freq` (AMD) or `base_frequency` (Intel). Turbo stays unreachable even though global `boost` stays `1` (so power-profiles-daemon can still write per-policy `boost`; `boost=0` makes those writes `EINVAL`) |
| Min freq | `amd_pstate_lowest_nonlinear_freq` when present, otherwise `cpuinfo_min_freq` |
| PPD | `powerprofilesctl set performance` |
| Watcher | `kickstart-cpu-governor.path` re-runs the pin when `/var/lib/power-profiles-daemon/state.ini` changes (sysfs has no inotify) |
| RTTIME | `/etc/systemd/user.conf.d/10-kickstart-rttime.conf` — `DefaultLimitRTTIME=200000`. rtkit refuses a realtime request from a client whose `RLIMIT_RTTIME` is infinity, and systemd's default *is* infinity, so this is what lets pipewire get RT at all. It also turns a runaway RT thread into `SIGXCPU`/`SIGKILL` instead of a pinned core. **Needs a reboot when `loginctl show-user $UID -p Linger` is `yes`, otherwise a new login.** |

No `DefaultLimitRTPRIO`. It is not needed — rtkit holds `CAP_SYS_NICE` and grants `SCHED_RR` regardless of the client's `RLIMIT_RTPRIO` — and it cannot work from `user.conf.d` anyway: the user manager inherits a hard limit of `0` from `user@.service` and cannot raise its own hard limit, so systemd clamps it. `systemctl --user show -p DefaultLimitRTPRIO` reports `95` while `/proc/<pid>/limits` still reads `0`. Setting it for real (from `/etc/systemd/system/user@.service.d/`) would grant every process in the session `SCHED_FIFO` up to 95 — above every threaded IRQ handler at FIFO 50 — for no benefit.

A handmade `/etc/systemd/system/cpu-freq-cap.service`, if present, is disabled (not deleted). Uninstall stops the units, restores `powersave` + full freq range, sets PPD `balanced`, removes the RTTIME drop-in, and prints how to re-enable your `cpu-freq-cap.service`.

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
| Linux | Ubuntu 24.04 (GNOME 46) or 26.04 LTS "Resolute Raccoon" (GNOME 50) — **tested on both** |
| macOS | macOS with Homebrew |
| Network | Internet connection for downloads |

> **Ubuntu 26.04 support:** all modules are tested on Ubuntu 26.04 (kernel 7.0, GNOME 50, OpenSSH 10.2, AppArmor 5.0). See the `fix(modules): Ubuntu 26.04 (resolute) compatibility` work for the specific adaptations.

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
- CPU governor pin is a no-op on laptops unless `KICKSTART_CPU_GOVERNOR=force`
- User RTTIME needs a reboot when linger is on (`user@UID.service` survives logout), else a new login; it bounds a runaway RT thread with `SIGXCPU`/`SIGKILL`
- GNOME uninstall restores mouse accel `default` and keyboard delay/repeat `500`/`30`

---

## License

MIT

---

<p align="center">
  <sub>Built with <a href="https://github.com/charmbracelet/bubbletea">Bubble Tea</a></sub>
</p>
