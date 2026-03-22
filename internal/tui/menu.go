package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dpanic/os-kickstart/internal/modules"
)

type menuItem struct {
	module    modules.Module
	separator bool   // true = this is a section header, not selectable
	label     string // for separators
	Status    string // update check result: "[update available]", "[latest]", etc.
}

type menuModel struct {
	items    []menuItem
	cursor   int
	selected map[int]bool
	height   int
}

func newMenuModel(mods []modules.Module) menuModel {
	var items []menuItem

	// Add optimization section.
	items = append(items, menuItem{separator: true, label: "Optimizations"})
	for _, m := range mods {
		if m.Category == "optimization" {
			items = append(items, menuItem{module: m})
		}
	}

	// Add installation section.
	items = append(items, menuItem{separator: true, label: "Installations"})
	for _, m := range mods {
		if m.Category == "installation" {
			items = append(items, menuItem{module: m})
		}
	}

	// Set cursor to first non-separator item.
	cursor := 0
	for i, item := range items {
		if !item.separator {
			cursor = i
			break
		}
	}

	return menuModel{
		items:    items,
		cursor:   cursor,
		selected: make(map[int]bool),
		height:   20,
	}
}

func (m menuModel) Init() tea.Cmd { return runUpdateChecks() }

func (m menuModel) Update(msg tea.Msg) (menuModel, tea.Cmd) {
	switch msg := msg.(type) {
	case updateCheckDoneMsg:
		for _, r := range msg.results {
			for i := range m.items {
				if !m.items[i].separator && m.items[i].module.ID == r.moduleID {
					m.items[i].Status = r.status
				}
			}
		}
		return m, nil

	case tea.WindowSizeMsg:
		m.height = msg.Height - 6 // leave room for header/footer
		if m.height < 10 {
			m.height = 10
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			m.cursor = m.prevSelectable(m.cursor)
		case "down", "j":
			m.cursor = m.nextSelectable(m.cursor)
		case " ":
			if !m.items[m.cursor].separator {
				if m.selected[m.cursor] {
					delete(m.selected, m.cursor)
				} else {
					m.selected[m.cursor] = true
				}
			}
		case "enter":
			selected := m.getSelected()
			if len(selected) == 0 {
				return m, nil
			}
			return m, tea.Batch(
				func() tea.Msg { return selectedModulesMsg{modules: selected} },
				func() tea.Msg { return switchScreenMsg{to: screenMode} },
			)
		case "q", "esc":
			return m, tea.Quit
		}
	}

	return m, nil
}

func (m menuModel) View() string {
	var b strings.Builder

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	b.WriteString(titleStyle.Render("  Select modules to install") + "\n")
	b.WriteString(MutedStyle.Render("  ↑/↓ navigate • space select • enter confirm") + "\n\n")

	for i, item := range m.items {
		if item.separator {
			sep := fmt.Sprintf("  ── %s ──", item.label)
			b.WriteString(MutedStyle.Render(sep) + "\n")
			continue
		}

		cursor := "  "
		if i == m.cursor {
			cursor = lipgloss.NewStyle().Foreground(ColorAccent).Render("▸ ")
		}

		checkbox := "[ ]"
		if m.selected[i] {
			checkbox = lipgloss.NewStyle().Foreground(ColorOK).Render("[✓]")
		}

		label := item.module.Label
		if i == m.cursor {
			label = lipgloss.NewStyle().Bold(true).Render(label)
		}

		line := fmt.Sprintf("%s%s %s", cursor, checkbox, label)

		if item.module.Description != "" {
			line += MutedStyle.Render(" — " + item.module.Description)
		}

		if item.Status != "" {
			switch {
			case strings.Contains(item.Status, "update:"):
				line += " " + lipgloss.NewStyle().Foreground(ColorWarn).Render(item.Status)
			case item.Status == "[latest]":
				line += " " + OKStyle.Render(item.Status)
			default:
				line += " " + MutedStyle.Render(item.Status)
			}
		}

		b.WriteString(line + "\n")
	}

	count := len(m.selected)
	footer := fmt.Sprintf("\n  %d selected", count)
	b.WriteString(MutedStyle.Render(footer))

	return b.String()
}

func (m menuModel) prevSelectable(from int) int {
	i := from - 1
	for i >= 0 {
		if !m.items[i].separator {
			return i
		}
		i--
	}
	// Wrap to bottom.
	i = len(m.items) - 1
	for i > from {
		if !m.items[i].separator {
			return i
		}
		i--
	}
	return from
}

func (m menuModel) nextSelectable(from int) int {
	i := from + 1
	for i < len(m.items) {
		if !m.items[i].separator {
			return i
		}
		i++
	}
	// Wrap to top.
	i = 0
	for i < from {
		if !m.items[i].separator {
			return i
		}
		i++
	}
	return from
}

func (m menuModel) getSelected() []modules.Module {
	var result []modules.Module
	for i, item := range m.items {
		if m.selected[i] && !item.separator {
			result = append(result, item.module)
		}
	}
	return result
}
