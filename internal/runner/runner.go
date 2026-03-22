package runner

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]`)

// StripANSI removes ANSI escape codes from a string.
func StripANSI(s string) string {
	return ansiRe.ReplaceAllString(s, "")
}

// Result holds the outcome of a script execution.
type Result struct {
	Module   string
	ExitCode int
	Output   string
	Duration time.Duration
	LogFile  string
}

// Params configures a single script run.
type Params struct {
	TmpDir     string
	Script     string            // relative to modules/, e.g. "shell/install.sh"
	Components []string          // sub-components to pass as args
	Mode       string            // "--update" or "--uninstall" or ""
	Env        map[string]string // extra env vars
	OnLine     func(string)      // called per line (ANSI-stripped), may be nil
	LogDir     string            // if set, writes log file here
	Sudo       bool              // run with sudo bash
}

// Run executes a shell script and captures its output.
func Run(ctx context.Context, p Params) (Result, error) {
	scriptPath := filepath.Join(p.TmpDir, "modules", p.Script)

	args := []string{}
	if p.Sudo {
		args = append(args, "bash", scriptPath)
	} else {
		args = append(args, scriptPath)
	}
	args = append(args, p.Components...)
	if p.Mode != "" {
		args = append(args, p.Mode)
	}

	var cmd *exec.Cmd
	if p.Sudo {
		cmd = exec.CommandContext(ctx, "sudo", args...)
	} else {
		cmd = exec.CommandContext(ctx, "bash", args...)
	}

	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	// Kill the entire process group on context cancellation so child
	// processes (e.g. sleep) don't keep pipes open and block Wait.
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.WaitDelay = 3 * time.Second

	// Environment
	cmd.Env = os.Environ()
	for k, v := range p.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	// Pipe stdout+stderr combined
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw

	// Log file setup
	var logFile *os.File
	var logPath string
	if p.LogDir != "" {
		if err := os.MkdirAll(p.LogDir, 0o755); err != nil {
			return Result{}, fmt.Errorf("create log dir: %w", err)
		}
		name := strings.ReplaceAll(p.Script, "/", "-")
		name = strings.TrimSuffix(name, ".sh")
		logPath = filepath.Join(
			p.LogDir,
			fmt.Sprintf("%s-%s.log", name, time.Now().Format("20060102-150405")),
		)
		var err error
		logFile, err = os.Create(logPath)
		if err != nil {
			return Result{}, fmt.Errorf("create log file: %w", err)
		}
		defer logFile.Close()
	}

	start := time.Now()
	if err := cmd.Start(); err != nil {
		pw.Close()
		return Result{}, fmt.Errorf("start script: %w", err)
	}

	// Read output line by line
	var output strings.Builder
	done := make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(pr)
		for scanner.Scan() {
			raw := scanner.Text()
			output.WriteString(raw + "\n")

			if logFile != nil {
				logFile.WriteString(raw + "\n")
			}
			if p.OnLine != nil {
				p.OnLine(StripANSI(raw))
			}
		}
	}()

	waitErr := cmd.Wait()
	pw.Close()
	<-done

	exitCode := 0
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = -1
		}
	}

	return Result{
		Module:   p.Script,
		ExitCode: exitCode,
		Output:   output.String(),
		Duration: time.Since(start),
		LogFile:  logPath,
	}, nil
}
