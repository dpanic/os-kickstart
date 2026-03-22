package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var modeOptions = []struct {
	mode  mode
	label string
	desc  string
}{
	{modeInstall, "Install", "Fresh installation of selected modules"},
	{modeUpdate, "Update", "Update already installed modules"},
	{modeUninstall, "Uninstall", "Remove selected modules"},
}

type modeModel struct {
	cursor int
}

func newModeModel() modeModel { return modeModel{} }

func (m modeModel) Init() tea.Cmd { return nil }

func (m modeModel) Update(msg tea.Msg) (modeModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(modeOptions)-1 {
				m.cursor++
			}
		case "enter":
			selected := modeOptions[m.cursor].mode
			return m, tea.Batch(
				func() tea.Msg { return selectedModeMsg{mode: selected} },
				func() tea.Msg {
					if selected == modeUninstall {
						return switchScreenMsg{to: screenConfirm}
					}
					return switchScreenMsg{to: screenGitInfo}
				},
			)
		case "esc":
			return m, func() tea.Msg { return switchScreenMsg{to: screenMenu} }
		}
	}
	return m, nil
}

func (m modeModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	b.WriteString(titleStyle.Render("  Select mode") + "\n")
	b.WriteString(MutedStyle.Render("  ↑/↓ navigate • enter confirm • esc back") + "\n\n")

	for i, opt := range modeOptions {
		cursor := "  "
		if i == m.cursor {
			cursor = lipgloss.NewStyle().Foreground(ColorAccent).Render("▸ ")
		}

		label := opt.label
		if i == m.cursor {
			label = lipgloss.NewStyle().Bold(true).Render(label)
		}

		line := fmt.Sprintf("%s%s", cursor, label)
		if opt.desc != "" {
			line += MutedStyle.Render(" — " + opt.desc)
		}
		b.WriteString(line + "\n")
	}

	return b.String()
}
