package modules

// Module describes a selectable item in the TUI menu.
type Module struct {
	ID           string   // unique key, e.g. "kernel-sysctl"
	Script       string   // relative path, e.g. "kernel/optimize.sh"
	Components   []string // sub-components or nil for standalone
	Label        string   // display name in menu
	Description  string   // short description
	Category     string   // "optimization" or "installation"
	Subsection   string   // grouping within category (e.g. "Shell", "Dev Tools")
	OS           string   // "all", "linux", "darwin"
	NeedsSudo    bool     // invoke with sudo bash
	InstalledCmd   string // command to check if installed (empty = no check)
	InstalledCheck string // file path to check if applied (empty = no check)
}

// AllModules returns the full registry, unfiltered.
func AllModules() []Module {
	return []Module{
		// ── Optimizations ──
		{ID: "gnome", Script: "gnome/optimize.sh", Label: "GNOME Optimize", Description: "disable animations, sounds, hot corners", Category: "optimization", OS: "linux", InstalledCmd: "gsettings"},
		{ID: "nautilus", Script: "nautilus/optimize.sh", Label: "Nautilus Optimize", Description: "restrict Tracker, limit thumbnails", Category: "optimization", OS: "linux", InstalledCmd: "nautilus"},
		{ID: "apparmor", Script: "apparmor/setup.sh", Label: "AppArmor Setup", Description: "learning mode with Slack reminder", Category: "optimization", OS: "linux", NeedsSudo: true, InstalledCmd: "apparmor_status"},
		{ID: "kernel-sysctl", Script: "kernel/optimize.sh", Components: []string{"sysctl"}, Label: "Kernel ▸ sysctl.conf", Description: "network, memory, conntrack tuning", Category: "optimization", OS: "linux", InstalledCheck: "/etc/sysctl.conf.bak-kickstart"},
		{ID: "kernel-limits", Script: "kernel/optimize.sh", Components: []string{"limits"}, Label: "Kernel ▸ limits", Description: "file descriptor & process limits", Category: "optimization", OS: "linux", InstalledCheck: "/etc/security/limits.conf.bak-kickstart"},
		{ID: "kernel-scheduler", Script: "kernel/optimize.sh", Components: []string{"scheduler"}, Label: "Kernel ▸ I/O scheduler", Description: "none (SSD/NVMe)", Category: "optimization", OS: "linux", InstalledCheck: "/etc/udev/rules.d/60-scheduler.rules"},
		{ID: "kernel-autotune", Script: "kernel/optimize.sh", Components: []string{"autotune"}, Label: "Kernel ▸ autotune", Description: "RAM-based autotune service", Category: "optimization", OS: "linux", InstalledCheck: "/etc/systemd/system/autotune.service"},
		{ID: "sshd", Script: "sshd/setup.sh", Label: "SSH ▸ sshd hardening", Description: "disables password auth", Category: "optimization", OS: "linux", InstalledCmd: "sshd"},

		// ── Installations / Shell ──
		{ID: "shell-zsh", Script: "shell/install.sh", Components: []string{"zsh"}, Label: "zsh + oh-my-zsh", Category: "installation", Subsection: "Shell", OS: "all", InstalledCmd: "zsh"},
		{ID: "shell-fzf", Script: "shell/install.sh", Components: []string{"fzf"}, Label: "fzf", Description: "fuzzy finder", Category: "installation", Subsection: "Shell", OS: "all", InstalledCmd: "fzf"},
		{ID: "shell-starship", Script: "shell/install.sh", Components: []string{"starship"}, Label: "starship prompt", Category: "installation", Subsection: "Shell", OS: "all", InstalledCmd: "starship"},
		{ID: "shell-direnv", Script: "shell/install.sh", Components: []string{"direnv"}, Label: "direnv", Category: "installation", Subsection: "Shell", OS: "all", InstalledCmd: "direnv"},
		{ID: "shell-plugins", Script: "shell/install.sh", Components: []string{"plugins"}, Label: "zsh plugins", Description: "autosuggestions, syntax-highlighting", Category: "installation", Subsection: "Shell", OS: "all", InstalledCheck: "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"},
		{ID: "shell-nvm", Script: "shell/install.sh", Components: []string{"nvm"}, Label: "nvm", Description: "Node version manager", Category: "installation", Subsection: "Shell", OS: "all", InstalledCheck: "$HOME/.nvm/nvm.sh"},
		{ID: "shell-git", Script: "shell/install.sh", Components: []string{"git"}, Label: "git config", Description: "LFS, SSH-over-HTTPS", Category: "installation", Subsection: "Shell", OS: "all", InstalledCmd: "git"},
		{ID: "shell-byobu", Script: "shell/install.sh", Components: []string{"byobu"}, Label: "byobu + tmux", Category: "installation", Subsection: "Shell", OS: "linux", InstalledCmd: "byobu"},

		// ── Installations / Terminal ──
		{ID: "terminal-ncdu", Script: "terminal/install.sh", Components: []string{"ncdu"}, Label: "ncdu", Description: "disk analyzer", Category: "installation", Subsection: "Terminal", OS: "all", InstalledCmd: "ncdu"},
		{ID: "yazi", Script: "yazi/install.sh", Label: "Yazi", Description: "terminal file manager", Category: "installation", Subsection: "Terminal", OS: "all", InstalledCmd: "yazi"},

		// ── Installations / Dev Tools ──
		{ID: "docker", Script: "docker/install.sh", Label: "Docker", Description: "engine, compose, buildx, daemon config", Category: "installation", Subsection: "Dev Tools", OS: "all", InstalledCmd: "docker"},
		{ID: "go", Script: "go/install.sh", Label: "Go", Description: "programming language from go.dev", Category: "installation", Subsection: "Dev Tools", OS: "all", InstalledCmd: "go"},
		{ID: "neovim", Script: "neovim/install.sh", Label: "Neovim + LazyVim", Description: "editor with IDE features", Category: "installation", Subsection: "Dev Tools", OS: "all", InstalledCmd: "nvim"},

		// ── Installations / Browsers & Apps ──
		{ID: "browser-chrome", Script: "browsers/install.sh", Components: []string{"chrome"}, Label: "Google Chrome", Category: "installation", Subsection: "Browsers & Apps", OS: "linux", InstalledCmd: "google-chrome"},
		{ID: "browser-brave", Script: "browsers/install.sh", Components: []string{"brave"}, Label: "Brave", Category: "installation", Subsection: "Browsers & Apps", OS: "linux", InstalledCmd: "brave-browser"},
		{ID: "app-signal", Script: "browsers/install.sh", Components: []string{"signal"}, Label: "Signal Desktop", Category: "installation", Subsection: "Browsers & Apps", OS: "linux", InstalledCmd: "signal-desktop"},
		{ID: "peazip", Script: "peazip/install.sh", Label: "PeaZip", Description: "archive manager (200+ formats)", Category: "installation", Subsection: "Browsers & Apps", OS: "linux", InstalledCmd: "peazip"},
	}
}

// ForOS returns modules matching the given OS ("linux" or "darwin").
func ForOS(goos string) []Module {
	all := AllModules()
	filtered := make([]Module, 0, len(all))
	for _, m := range all {
		if m.OS == "all" || m.OS == goos {
			filtered = append(filtered, m)
		}
	}
	return filtered
}

// NeedsUserInfo returns true if any module in the selection requires the GitInfo screen.
func NeedsUserInfo(selected []Module) bool {
	for _, m := range selected {
		if m.ID == "shell-git" || m.ID == "apparmor" {
			return true
		}
	}
	return false
}

// NeedsWebhook returns true if apparmor is in the selection.
func NeedsWebhook(selected []Module) bool {
	for _, m := range selected {
		if m.ID == "apparmor" {
			return true
		}
	}
	return false
}

// InstallSubsections returns the ordered list of subsection names for installations.
func InstallSubsections() []string {
	return []string{"Shell", "Terminal", "Dev Tools", "Browsers & Apps"}
}

// ScriptGroup represents a single script invocation with merged components.
type ScriptGroup struct {
	Script     string
	Components []string
	Label      string
	NeedsSudo  bool
	ModuleIDs  []string
}

// GroupByScript merges selected modules that share the same script path.
func GroupByScript(selected []Module) []ScriptGroup {
	seen := map[string]int{}
	var groups []ScriptGroup

	for _, m := range selected {
		key := m.Script
		if idx, ok := seen[key]; ok && len(m.Components) > 0 {
			groups[idx].Components = append(groups[idx].Components, m.Components...)
			groups[idx].ModuleIDs = append(groups[idx].ModuleIDs, m.ID)
		} else {
			seen[key] = len(groups)
			groups = append(groups, ScriptGroup{
				Script:     m.Script,
				Components: append([]string{}, m.Components...),
				Label:      m.Label,
				NeedsSudo:  m.NeedsSudo,
				ModuleIDs:  []string{m.ID},
			})
		}
	}
	return groups
}
