// Package sudo primes the sudo credential cache once at startup and
// refreshes it in the background so privileged module scripts do not
// interrupt the TUI with a mid-run password prompt.
package sudo

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"
)

// Prime prompts for sudo credentials once (if needed) and starts a
// keep-alive goroutine that refreshes the cache every minute.
//
// The returned cancel function stops the keep-alive and MUST be called
// by the caller (typically via defer) on shutdown.
//
// No-op when:
//   - the sudo binary is not on PATH (e.g. macOS without sudo);
//   - the process is already root (sudo -v is a cheap success but we
//     still start keep-alive so the cache stays warm uniformly);
//   - the prime call fails (e.g. user cancels). The caller continues —
//     individual scripts that need sudo will prompt as usual.
func Prime() (cancel func()) {
	if _, err := exec.LookPath("sudo"); err != nil {
		return func() {}
	}

	fmt.Println("Caching sudo credentials so installer can run without interruption...")
	cmd := exec.Command("sudo", "-v")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "sudo refresh failed (%v); you may be prompted again later.\n", err)
		return func() {}
	}

	ctx, ctxCancel := context.WithCancel(context.Background())
	go keepAlive(ctx)
	return ctxCancel
}

func keepAlive(ctx context.Context) {
	t := time.NewTicker(60 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = exec.Command("sudo", "-n", "true").Run()
		}
	}
}
