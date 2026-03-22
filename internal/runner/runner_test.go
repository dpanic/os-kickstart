package runner_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dpanic/os-kickstart/internal/runner"
)

func writeScript(t *testing.T, dir, relPath, content string) string {
	t.Helper()
	full := filepath.Join(dir, relPath)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	return full
}

func TestRun_CapturesOutput(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/run.sh", "#!/bin/bash\necho hello\necho world")

	var lines []string
	onLine := func(line string) { lines = append(lines, line) }

	result, err := runner.Run(context.Background(), runner.Params{
		TmpDir: dir,
		Script: "test/run.sh",
		OnLine: onLine,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 0 {
		t.Errorf("expected exit 0, got %d", result.ExitCode)
	}
	if len(lines) < 2 {
		t.Fatalf("expected >=2 lines, got %d", len(lines))
	}
	if lines[0] != "hello" {
		t.Errorf("expected 'hello', got %q", lines[0])
	}
}

func TestRun_CapturesExitCode(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/fail.sh", "#!/bin/bash\nexit 42")

	result, err := runner.Run(context.Background(), runner.Params{
		TmpDir: dir,
		Script: "test/fail.sh",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 42 {
		t.Errorf("expected exit 42, got %d", result.ExitCode)
	}
}

func TestRun_PassesComponents(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/args.sh", "#!/bin/bash\necho \"$@\"")

	var lines []string
	onLine := func(line string) { lines = append(lines, line) }

	_, err := runner.Run(context.Background(), runner.Params{
		TmpDir:     dir,
		Script:     "test/args.sh",
		Components: []string{"zsh", "fzf"},
		Mode:       "--update",
		OnLine:     onLine,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) == 0 {
		t.Fatal("expected output")
	}
	if !strings.Contains(lines[0], "zsh") || !strings.Contains(lines[0], "fzf") || !strings.Contains(lines[0], "--update") {
		t.Errorf("expected args with components and mode, got %q", lines[0])
	}
}

func TestRun_ContextCancellation(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/slow.sh", "#!/bin/bash\nsleep 60")

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	result, err := runner.Run(ctx, runner.Params{
		TmpDir: dir,
		Script: "test/slow.sh",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode == 0 {
		t.Error("expected non-zero exit on cancellation")
	}
	if result.Duration > 5*time.Second {
		t.Error("cancellation took too long")
	}
}

func TestRun_WritesLogFile(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	logDir := t.TempDir()
	writeScript(t, dir, "modules/test/log.sh", "#!/bin/bash\necho logme")

	result, err := runner.Run(context.Background(), runner.Params{
		TmpDir: dir,
		Script: "test/log.sh",
		LogDir: logDir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.LogFile == "" {
		t.Fatal("expected log file path")
	}
	data, err := os.ReadFile(result.LogFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "logme") {
		t.Error("log file should contain script output")
	}
}

func TestRun_EnvVars(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/env.sh", "#!/bin/bash\necho $KICKSTART_USER_NAME")

	var lines []string
	onLine := func(line string) { lines = append(lines, line) }

	_, err := runner.Run(context.Background(), runner.Params{
		TmpDir: dir,
		Script: "test/env.sh",
		Env:    map[string]string{"KICKSTART_USER_NAME": "TestUser"},
		OnLine: onLine,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) == 0 || lines[0] != "TestUser" {
		t.Errorf("expected 'TestUser', got %v", lines)
	}
}

func TestRun_StripANSI(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeScript(t, dir, "modules/test/color.sh", `#!/bin/bash
printf '\033[32mgreen\033[0m\n'`)

	var lines []string
	onLine := func(line string) { lines = append(lines, line) }

	_, err := runner.Run(context.Background(), runner.Params{
		TmpDir: dir,
		Script: "test/color.sh",
		OnLine: onLine,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) == 0 {
		t.Fatal("expected output")
	}
	if strings.Contains(lines[0], "\033") {
		t.Error("ANSI codes should be stripped for OnLine callback")
	}
	if lines[0] != "green" {
		t.Errorf("expected 'green', got %q", lines[0])
	}
}
