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
	logoStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorAccent).
		PaddingLeft(2)

	logo := logoStyle.Render("OS Kickstart by dpanic")

	subtitle := lipgloss.NewStyle().
		Foreground(ColorAccent2).
		PaddingLeft(2).
		Render("System optimization & dev environment setup")

	ver := m.version
	if m.commit != "none" && m.commit != "" {
		ver += " (" + m.commit + ")"
	}
	verLine := MutedStyle.Render("  " + ver)

	return "\n\n" + logo + "\n\n" + subtitle + "\n" + verLine
}
