package modules_test

import (
	"testing"

	"github.com/dpanic/os-kickstart/internal/modules"
)

func TestAllModules_ReturnsNonEmpty(t *testing.T) {
	t.Parallel()
	mods := modules.AllModules()
	if len(mods) == 0 {
		t.Fatal("expected non-empty module list")
	}
}

func TestAllModules_HasOptimizationsAndInstallations(t *testing.T) {
	t.Parallel()
	mods := modules.AllModules()
	hasOpt := false
	hasInst := false
	for _, m := range mods {
		if m.Category == "optimization" {
			hasOpt = true
		}
		if m.Category == "installation" {
			hasInst = true
		}
	}
	if !hasOpt {
		t.Error("expected at least one optimization module")
	}
	if !hasInst {
		t.Error("expected at least one installation module")
	}
}

func TestForOS_FiltersLinuxOnlyOnDarwin(t *testing.T) {
	t.Parallel()
	mods := modules.ForOS("darwin")
	for _, m := range mods {
		if m.OS == "linux" {
			t.Errorf("linux-only module %q should not appear on darwin", m.ID)
		}
	}
}

func TestForOS_IncludesAllAndLinuxOnLinux(t *testing.T) {
	t.Parallel()
	mods := modules.ForOS("linux")
	hasLinux := false
	hasAll := false
	for _, m := range mods {
		if m.OS == "linux" {
			hasLinux = true
		}
		if m.OS == "all" {
			hasAll = true
		}
	}
	if !hasLinux {
		t.Error("expected linux-specific modules on linux")
	}
	if !hasAll {
		t.Error("expected cross-platform modules on linux")
	}
}

func TestKernelCpufreq_LinuxNoSudo(t *testing.T) {
	t.Parallel()
	var found modules.Module
	ok := false
	for _, m := range modules.AllModules() {
		if m.ID == "kernel-cpufreq" {
			found = m
			ok = true
			break
		}
	}
	if !ok {
		t.Fatal("expected kernel-cpufreq module")
	}
	if found.OS != "linux" {
		t.Errorf("OS = %q, want linux", found.OS)
	}
	if found.NeedsSudo {
		t.Error("NeedsSudo should be false; the script calls sudo itself")
	}
	if found.Script != "kernel/optimize.sh" {
		t.Errorf("Script = %q, want kernel/optimize.sh", found.Script)
	}
	if len(found.Components) != 1 || found.Components[0] != "cpufreq" {
		t.Errorf("Components = %v, want [cpufreq]", found.Components)
	}
	if found.InstalledCheck != "/etc/systemd/system/kickstart-cpu-governor.service" {
		t.Errorf("InstalledCheck = %q", found.InstalledCheck)
	}
}

func TestNeedsSudo_AllowedModulesOnly(t *testing.T) {
	t.Parallel()
	mods := modules.AllModules()
	allowed := map[string]bool{
		"apparmor/setup.sh":   true,
		"apparmor/monitor.sh": true,
		"usb/monitor.sh":      true,
	}
	for _, m := range mods {
		if m.NeedsSudo && !allowed[m.Script] {
			t.Errorf("module %q has NeedsSudo but is not in the allowed list", m.ID)
		}
	}
}

func TestGroupByScript_MergesComponents(t *testing.T) {
	t.Parallel()
	selected := []modules.Module{
		{ID: "shell-zsh", Script: "shell/install.sh", Components: []string{"zsh"}},
		{ID: "shell-fzf", Script: "shell/install.sh", Components: []string{"fzf"}},
		{ID: "docker", Script: "docker/install.sh"},
	}
	groups := modules.GroupByScript(selected)
	if len(groups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(groups))
	}
	if len(groups[0].Components) != 2 {
		t.Errorf("expected 2 components for shell, got %d", len(groups[0].Components))
	}
	if groups[0].Components[0] != "zsh" || groups[0].Components[1] != "fzf" {
		t.Errorf("wrong components: %v", groups[0].Components)
	}
	if len(groups[1].Components) != 0 {
		t.Errorf("docker should have no components, got %v", groups[1].Components)
	}
}

func TestNeedsUserInfo_ShellGitAndApparmor(t *testing.T) {
	t.Parallel()
	if modules.NeedsUserInfo([]modules.Module{{ID: "docker"}}) {
		t.Error("docker should not need user info")
	}
	if !modules.NeedsUserInfo([]modules.Module{{ID: "shell-git"}}) {
		t.Error("shell-git should need user info")
	}
	if !modules.NeedsUserInfo([]modules.Module{{ID: "apparmor"}}) {
		t.Error("apparmor should need user info")
	}
	if !modules.NeedsUserInfo([]modules.Module{{ID: "apparmor-monitor"}}) {
		t.Error("apparmor-monitor should need user info")
	}
}

func TestNeedsWebhook_ApparmorModules(t *testing.T) {
	t.Parallel()
	if modules.NeedsWebhook([]modules.Module{{ID: "docker"}}) {
		t.Error("docker should not need webhook")
	}
	if !modules.NeedsWebhook([]modules.Module{{ID: "apparmor"}}) {
		t.Error("apparmor should need webhook")
	}
	if !modules.NeedsWebhook([]modules.Module{{ID: "apparmor-monitor"}}) {
		t.Error("apparmor-monitor should need webhook")
	}
}
