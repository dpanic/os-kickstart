package main

import (
	"embed"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/dpanic/os-kickstart/internal/tui"
)

//go:embed all:modules
var assets embed.FS

var (
	version = "dev"
	commit  = "none"
)

func main() {
	m := tui.New(tui.Config{
		Assets:  assets,
		Version: version,
		Commit:  commit,
	})

	p := tea.NewProgram(m, tea.WithAltScreen())
	tui.SetProgram(p)

	// Handle SIGTERM for tmpdir cleanup
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM)
	go func() {
		<-sigCh
		tui.RunCleanup()
		os.Exit(1)
	}()

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		tui.RunCleanup()
		os.Exit(1)
	}
}
