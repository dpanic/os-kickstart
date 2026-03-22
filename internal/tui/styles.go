package tui

import "github.com/charmbracelet/lipgloss"

var (
	ColorAccent  = lipgloss.Color("212") // pink
	ColorAccent2 = lipgloss.Color("39")  // cyan
	ColorOK      = lipgloss.Color("78")  // green
	ColorWarn    = lipgloss.Color("208") // orange
	ColorError   = lipgloss.Color("196") // red
	ColorMuted   = lipgloss.Color("240") // gray
	ColorBarBg   = lipgloss.Color("236") // dark gray background for bars
	ColorBarFg   = lipgloss.Color("252") // light text on bars

	OKStyle = lipgloss.NewStyle().
		Foreground(ColorOK)

	ErrorStyle = lipgloss.NewStyle().
			Foreground(ColorError)

	MutedStyle = lipgloss.NewStyle().
			Foreground(ColorMuted)

	// Header styles
	HeaderTitleStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorAccent)

	HeaderByLineStyle = lipgloss.NewStyle().
				Foreground(ColorMuted)

	HeaderSpinnerLabel = lipgloss.NewStyle().
				Foreground(ColorAccent2).
				Italic(true)

	HeaderBorderStyle = lipgloss.NewStyle().
				Border(lipgloss.DoubleBorder()).
				BorderForeground(ColorAccent).
				Padding(0, 2)

	// Footer status bar style
	FooterBarStyle = lipgloss.NewStyle().
			Background(ColorBarBg).
			Foreground(ColorBarFg).
			Padding(0, 1)

	FooterUpdateStyle = lipgloss.NewStyle().
				Background(ColorBarBg).
				Foreground(ColorWarn).
				Bold(true)

	FooterCountStyle = lipgloss.NewStyle().
				Background(ColorBarBg).
				Foreground(ColorBarFg)

	// Help text style (keybindings)
	HelpKeyStyle = lipgloss.NewStyle().
			Foreground(ColorAccent2).
			Bold(true)

	HelpDescStyle = lipgloss.NewStyle().
			Foreground(ColorMuted)

	HelpSepStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("238"))
)
