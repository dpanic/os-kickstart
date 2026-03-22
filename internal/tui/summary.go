package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dpanic/os-kickstart/internal/runner"
)

type summaryModel struct {
	results []runner.Result
}

func newSummaryModel(results []runner.Result) summaryModel {
	return summaryModel{results: results}
}

func (m summaryModel) Init() tea.Cmd { return nil }

func (m summaryModel) Update(msg tea.Msg) (summaryModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "enter":
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m summaryModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	b.WriteString(titleStyle.Render("  Results") + "\n\n")

	succeeded := 0
	failed := 0

	for _, r := range m.results {
		var (
			icon   string
			status string
		)

		if r.ExitCode == 0 {
			icon = OKStyle.Render("  ✓")
			status = OKStyle.Render("OK")
			succeeded++
		} else {
			icon = ErrorStyle.Render("  ✗")
			status = ErrorStyle.Render(fmt.Sprintf("exit %d", r.ExitCode))
			failed++
		}

		duration := MutedStyle.Render(fmt.Sprintf("(%s)", r.Duration.Round(100*1e6))) // round to 100ms
		module := r.Module

		line := fmt.Sprintf("%s %s  %s  %s", icon, module, status, duration)
		b.WriteString(line + "\n")

		if r.LogFile != "" {
			b.WriteString(MutedStyle.Render(fmt.Sprintf("    log: %s", r.LogFile)) + "\n")
		}
	}

	// Summary line
	b.WriteString("\n")
	summary := fmt.Sprintf("  %d succeeded", succeeded)
	if failed > 0 {
		summary += fmt.Sprintf(", %d failed", failed)
	}
	if failed > 0 {
		b.WriteString(ErrorStyle.Render(summary))
	} else {
		b.WriteString(OKStyle.Render(summary))
	}

	b.WriteString("\n\n" + MutedStyle.Render("  q/enter to exit"))

	return b.String()
}
