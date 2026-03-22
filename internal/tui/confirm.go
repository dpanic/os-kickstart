package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type confirmModel struct {
	count int
	mode  mode
}

func newConfirmModel(count int, m mode) confirmModel {
	return confirmModel{count: count, mode: m}
}

func (m confirmModel) Init() tea.Cmd { return nil }

func (m confirmModel) Update(msg tea.Msg) (confirmModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "y", "Y", "enter":
			return m, func() tea.Msg { return confirmMsg{confirmed: true} }
		case "n", "N", "esc":
			return m, func() tea.Msg { return switchScreenMsg{to: screenMenu} }
		}
	}
	return m, nil
}

func (m confirmModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	b.WriteString(titleStyle.Render("  Confirm") + "\n\n")

	warnStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorWarn)
	msg := fmt.Sprintf("  Run %d script(s) in %s mode?", m.count, m.mode.String())
	b.WriteString(warnStyle.Render(msg) + "\n\n")

	b.WriteString(MutedStyle.Render("  y/enter confirm • n/esc cancel"))

	return b.String()
}
