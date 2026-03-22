package tui

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type tickMsg time.Time

type bannerModel struct {
	version string
	commit  string
}

func newBannerModel(version, commit string) bannerModel {
	return bannerModel{version: version, commit: commit}
}

func (m bannerModel) Init() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m bannerModel) Update(msg tea.Msg) (bannerModel, tea.Cmd) {
	switch msg.(type) {
	case tickMsg:
		return m, func() tea.Msg { return switchScreenMsg{to: screenMenu} }
	case tea.KeyMsg:
		return m, func() tea.Msg { return switchScreenMsg{to: screenMenu} }
	}
	return m, nil
}

func (m bannerModel) View() string {
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorAccent).
		Render("  Kickstart")

	subtitle := lipgloss.NewStyle().
		Foreground(ColorAccent2).
		Render("  System optimization & dev environment setup")

	ver := MutedStyle.Render("  " + m.version + " (" + m.commit + ")")

	return "\n" + title + "\n\n" + subtitle + "\n" + ver + "\n\n" +
		MutedStyle.Render("  Press any key to continue...")
}
