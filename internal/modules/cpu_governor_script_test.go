package modules_test

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

func TestCPUGovernorScript(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	script := filepath.Join(root, "modules", "kernel", "cpu-governor-test.sh")
	cmd := exec.Command("bash", script)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cpu-governor-test.sh: %v\n%s", err, out)
	}
}
