package tui

import (
	"os/exec"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type gitInfoModel struct {
	inputs       []textinput.Model
	focused      int
	showIdentity bool
	showWebhook  bool
	err          string
}

func newGitInfoModel(showIdentity, showWebhook bool) gitInfoModel {
	var inputs []textinput.Model

	if showIdentity {
		nameInput := textinput.New()
		nameInput.Placeholder = "Full Name"
		nameInput.Focus()
		nameInput.CharLimit = 100
		nameInput.Width = 40

		emailInput := textinput.New()
		emailInput.Placeholder = "email@example.com"
		emailInput.CharLimit = 100
		emailInput.Width = 40

		// Pre-fill from git config.
		if name, err := exec.Command("git", "config", "--global", "user.name").Output(); err == nil {
			nameInput.SetValue(strings.TrimSpace(string(name)))
		}
		if email, err := exec.Command("git", "config", "--global", "user.email").Output(); err == nil {
			emailInput.SetValue(strings.TrimSpace(string(email)))
		}

		inputs = append(inputs, nameInput, emailInput)
	}

	if showWebhook {
		webhookInput := textinput.New()
		webhookInput.Placeholder = "https://hooks.slack.com/..."
		webhookInput.CharLimit = 200
		webhookInput.Width = 60
		if !showIdentity {
			webhookInput.Focus()
		}
		inputs = append(inputs, webhookInput)
	}

	return gitInfoModel{
		inputs:       inputs,
		showIdentity: showIdentity,
		showWebhook:  showWebhook,
	}
}

func (m gitInfoModel) Init() tea.Cmd {
	return textinput.Blink
}

func (m gitInfoModel) Update(msg tea.Msg) (gitInfoModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "tab", "shift+tab":
			if msg.String() == "tab" {
				m.focused = (m.focused + 1) % len(m.inputs)
			} else {
				m.focused = (m.focused - 1 + len(m.inputs)) % len(m.inputs)
			}
			cmds := make([]tea.Cmd, len(m.inputs))
			for i := range m.inputs {
				if i == m.focused {
					cmds[i] = m.inputs[i].Focus()
				} else {
					m.inputs[i].Blur()
				}
			}
			return m, tea.Batch(cmds...)

		case "enter":
			var name, email, webhook string
			idx := 0
			if m.showIdentity {
				name = strings.TrimSpace(m.inputs[idx].Value())
				email = strings.TrimSpace(m.inputs[idx+1].Value())
				if name == "" || email == "" {
					m.err = "Name and email are required"
					return m, nil
				}
				idx += 2
			}
			if m.showWebhook {
				webhook = strings.TrimSpace(m.inputs[idx].Value())
				if webhook == "" {
					m.err = "Webhook URL is required"
					return m, nil
				}
			}
			return m, tea.Batch(
				func() tea.Msg {
					return userInfoMsg{
						name:    name,
						email:   email,
						webhook: webhook,
					}
				},
				func() tea.Msg {
					return switchScreenMsg{to: screenConfirm}
				},
			)

		case "esc":
			return m, func() tea.Msg {
				return switchScreenMsg{to: screenMode}
			}
		}
	}

	// Update the focused input.
	var cmd tea.Cmd
	m.inputs[m.focused], cmd = m.inputs[m.focused].Update(msg)
	return m, cmd
}

func (m gitInfoModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(ColorAccent)
	title := "  Configuration"
	switch {
	case m.showIdentity && m.showWebhook:
		title = "  Git & Webhook Configuration"
	case m.showIdentity:
		title = "  Git Configuration"
	case m.showWebhook:
		title = "  Webhook Configuration"
	}
	b.WriteString(titleStyle.Render(title) + "\n")
	b.WriteString(MutedStyle.Render("  tab switch • enter confirm • esc back") + "\n\n")

	var labels []string
	if m.showIdentity {
		labels = append(labels, "  Name:    ", "  Email:   ")
	}
	if m.showWebhook {
		labels = append(labels, "  Webhook: ")
	}

	for i, input := range m.inputs {
		label := labels[i]
		if i == m.focused {
			label = lipgloss.NewStyle().
				Foreground(ColorAccent2).
				Render(label)
		}
		b.WriteString(label + input.View() + "\n")
	}

	if m.err != "" {
		b.WriteString("\n" + ErrorStyle.Render("  ⚠ "+m.err))
	}

	return b.String()
}
