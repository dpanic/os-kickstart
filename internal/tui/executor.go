package tui

import (
	"context"
	"fmt"
	"io/fs"
	"strings"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dpanic/os-kickstart/internal/modules"
	"github.com/dpanic/os-kickstart/internal/runner"
)

const maxOutputLines = 5

type executorModel struct {
	groups   []modules.ScriptGroup
	results  []runner.Result
	current  int
	output   []string // last N lines of current script
	spinner  spinner.Model
	progress progress.Model
	done     bool

	// Execution context
	tmpDir string
	mode   string
	env    map[string]string
	cancel context.CancelFunc
	assets fs.FS
}

func newExecutorModel(
	selected []modules.Module,
	tmpDir string,
	modeFlag string,
	env map[string]string,
	assets fs.FS,
) executorModel {
	groups := modules.GroupByScript(selected)

	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(ColorAccent)

	p := progress.New(progress.WithDefaultGradient())

	return executorModel{
		groups:   groups,
		results:  make([]runner.Result, 0, len(groups)),
		spinner:  s,
		progress: p,
		tmpDir:   tmpDir,
		mode:     modeFlag,
		env:      env,
		assets:   assets,
	}
}

func (m executorModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.runCurrent())
}

func (m executorModel) Update(msg tea.Msg) (executorModel, tea.Cmd) {
	switch msg := msg.(type) {
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case progress.FrameMsg:
		model, cmd := m.progress.Update(msg)
		m.progress = model.(progress.Model)
		return m, cmd

	case scriptOutputMsg:
		m.output = append(m.output, msg.line)
		if len(m.output) > maxOutputLines {
			m.output = m.output[len(m.output)-maxOutputLines:]
		}
		return m, nil

	case scriptDoneMsg:
		m.results = append(m.results, msg.result)
		m.current++
		m.output = nil

		if m.current >= len(m.groups) {
			m.done = true
			return m, func() tea.Msg { return allDoneMsg{} }
		}
		return m, m.runCurrent()

	case tea.WindowSizeMsg:
		m.progress.Width = msg.Width - 10
		if m.progress.Width < 20 {
			m.progress.Width = 20
		}
		return m, nil
	}

	return m, nil
}

func (m executorModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	b.WriteString(titleStyle.Render("  Running scripts...") + "\n\n")

	for i, g := range m.groups {
		var icon string
		var labelStyle lipgloss.Style

		switch {
		case i < m.current:
			if m.results[i].ExitCode == 0 {
				icon = OKStyle.Render("  \u2713 ")
			} else {
				icon = ErrorStyle.Render("  \u2717 ")
			}
			labelStyle = lipgloss.NewStyle()
		case i == m.current:
			icon = "  " + m.spinner.View() + " "
			labelStyle = lipgloss.NewStyle().Bold(true)
		default:
			icon = MutedStyle.Render("  \u25CB ")
			labelStyle = MutedStyle
		}

		label := g.Label
		if len(g.Components) > 1 {
			label = g.Label + " +" + fmt.Sprintf("%d", len(g.Components)-1)
		}

		b.WriteString(icon + labelStyle.Render(label) + "\n")

		// Show live output for current script
		if i == m.current && len(m.output) > 0 {
			for _, line := range m.output {
				truncated := line
				if len(truncated) > 80 {
					truncated = truncated[:77] + "..."
				}
				b.WriteString(MutedStyle.Render("    \u2502 "+truncated) + "\n")
			}
		}
	}

	// Progress bar
	total := len(m.groups)
	pct := float64(m.current) / float64(total)
	b.WriteString("\n  " + m.progress.ViewAs(pct))
	b.WriteString(MutedStyle.Render(fmt.Sprintf("  %d/%d", m.current, total)))

	return b.String()
}

func (m executorModel) runCurrent() tea.Cmd {
	if m.current >= len(m.groups) {
		return nil
	}

	g := m.groups[m.current]
	tmpDir := m.tmpDir
	modeFlag := m.mode
	env := m.env
	sudo := g.NeedsSudo

	return func() tea.Msg {
		result, err := runner.Run(context.Background(), runner.Params{
			TmpDir:     tmpDir,
			Script:     g.Script,
			Components: g.Components,
			Mode:       modeFlag,
			Env:        env,
			LogDir:     "logs",
			Sudo:       sudo,
		})
		if err != nil {
			return scriptDoneMsg{result: runner.Result{
				Module:   g.Script,
				ExitCode: -1,
				Output:   err.Error(),
			}}
		}
		return scriptDoneMsg{result: result}
	}
}
