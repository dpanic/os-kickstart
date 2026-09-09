package modules_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetdevBudgetScript(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	cmd := exec.Command("bash", filepath.Join(root, "modules", "kernel", "netdev-budget-test.sh"))
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("netdev-budget-test.sh: %v\n%s", err, out)
	}
}

// netdev_budget_usecs is HZ-derived and the kernel refuses anything below its own
// default, so no static value is portable -- a line in the .conf is wrong by
// construction, whatever number it carries.
func TestNetdevBudgetOwnedOnlyByAutotune(t *testing.T) {
	t.Parallel()
	conf := stripConfComments(readRepoFile(t, "modules", "kernel", "90-kickstart.conf"))
	if strings.Contains(conf, "net.core.netdev_budget") {
		t.Error("90-kickstart.conf sets netdev_budget*: autotune.sh owns it, the value depends on HZ")
	}
	auto := readRepoFile(t, "modules", "kernel", "autotune.sh")
	if !strings.Contains(auto, "kickstart_netdev_apply\n") {
		t.Error("autotune.sh never calls kickstart_netdev_apply, so nothing restores the default")
	}
}
