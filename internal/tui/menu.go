package tui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dpanic/os-kickstart/internal/modules"
)

type menuItem struct {
	module    modules.Module
	separator bool
	label     string
	Status    string
}

type menuModel struct {
	items      []menuItem
	allMods    []modules.Module
	cursor     int
	selected   map[int]bool
	height     int
	offset     int
	checksRan  bool
	spinner    spinner.Model
	filtering  bool
	filter     string
	visible    []int // indices of visible items when filtering
}

func newMenuModel(mods []modules.Module) menuModel {
	var items []menuItem

	items = append(items, menuItem{separator: true, label: "Optimizations"})
	for _, m := range mods {
		if m.Category == "optimization" {
			items = append(items, menuItem{module: m})
		}
	}

	items = append(items, menuItem{separator: true, label: "Installations"})
	for _, sub := range modules.InstallSubsections() {
		hasItems := false
		for _, m := range mods {
			if m.Category == "installation" && m.Subsection == sub {
				hasItems = true
				break
			}
		}
		if !hasItems {
			continue
		}
		items = append(items, menuItem{separator: true, label: "  " + sub})
		for _, m := range mods {
			if m.Category == "installation" && m.Subsection == sub {
				items = append(items, menuItem{module: m})
			}
		}
	}

	cursor := 0
	for i, item := range items {
		if !item.separator {
			cursor = i
			break
		}
	}

	// Sync installed check — instant, no network
	for i := range items {
		if items[i].separator {
			continue
		}
		cmd := items[i].module.InstalledCmd
		if cmd != "" && isInstalled(cmd) {
			items[i].Status = "[installed]"
		}
	}

	s := spinner.New()
	s.Spinner = spinner.MiniDot
	s.Style = lipgloss.NewStyle().Foreground(ColorAccent2)

	return menuModel{
		items:    items,
		allMods:  mods,
		cursor:   cursor,
		selected: make(map[int]bool),
		height:   25,
		spinner:  s,
	}
}

func (m menuModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, runUpdateChecks(m.allMods))
}

func (m menuModel) Update(msg tea.Msg) (menuModel, tea.Cmd) {
	switch msg := msg.(type) {
	case spinner.TickMsg:
		if !m.checksRan {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}

	case updateCheckDoneMsg:
		m.checksRan = true
		for _, r := range msg.results {
			for i := range m.items {
				if !m.items[i].separator && m.items[i].module.ID == r.moduleID {
					m.items[i].Status = r.status
				}
			}
		}
		return m, nil

	case tea.WindowSizeMsg:
		// Reserve 20% for header/footer chrome, minimum 10 lines for list
		m.height = int(float64(msg.Height) * 0.80)
		if m.height < 10 {
			m.height = 10
		}
		m.fixScroll()

	case tea.KeyMsg:
		// Filter mode input
		if m.filtering {
			switch msg.String() {
			case "esc":
				m.filtering = false
				m.filter = ""
				m.visible = nil
				m.fixScroll()
				return m, nil
			case "backspace":
				if len(m.filter) > 0 {
					m.filter = m.filter[:len(m.filter)-1]
					m.applyFilter()
				}
				return m, nil
			case "enter":
				m.filtering = false
				return m, nil
			default:
				if len(msg.String()) == 1 {
					m.filter += msg.String()
					m.applyFilter()
				}
				return m, nil
			}
		}

		switch msg.String() {
		case "up", "k":
			m.cursor = m.prevSelectable(m.cursor)
			m.fixScroll()
		case "down", "j":
			m.cursor = m.nextSelectable(m.cursor)
			m.fixScroll()
		case " ":
			if !m.items[m.cursor].separator {
				if m.selected[m.cursor] {
					delete(m.selected, m.cursor)
				} else {
					m.selected[m.cursor] = true
				}
			}
		case "ctrl+a":
			allSelected := len(m.selected) == m.selectableCount()
			if allSelected {
				m.selected = make(map[int]bool)
			} else {
				for i, item := range m.items {
					if !item.separator {
						m.selected[i] = true
					}
				}
			}
		case "/":
			m.filtering = true
			m.filter = ""
			return m, nil
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
			if m.filter != "" {
				m.filter = ""
				m.visible = nil
				return m, nil
			}
			return m, tea.Quit
		}
	}

	return m, nil
}

func (m *menuModel) applyFilter() {
	if m.filter == "" {
		m.visible = nil
		return
	}
	lower := strings.ToLower(m.filter)
	m.visible = nil
	for i, item := range m.items {
		if item.separator {
			continue
		}
		if strings.Contains(strings.ToLower(item.module.Label), lower) ||
			strings.Contains(strings.ToLower(item.module.Description), lower) {
			m.visible = append(m.visible, i)
		}
	}
	// Move cursor to first visible item
	if len(m.visible) > 0 {
		m.cursor = m.visible[0]
		m.offset = 0
	}
}

func (m *menuModel) fixScroll() {
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+m.height {
		m.offset = m.cursor - m.height + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

func (m menuModel) selectableCount() int {
	n := 0
	for _, item := range m.items {
		if !item.separator {
			n++
		}
	}
	return n
}

var (
	updateAvailableStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("231"))
	latestStyle          = OKStyle
	installedStyle       = MutedStyle
	sectionStyle         = lipgloss.NewStyle().Bold(true).Foreground(ColorAccent)
	subsectionStyle      = lipgloss.NewStyle().Foreground(ColorAccent2)

	headerBox = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorAccent).
			Foreground(ColorAccent).
			Bold(true).
			Padding(0, 2)
)

func (m menuModel) View() string {
	var b strings.Builder

	// Header box
	byLine := lipgloss.NewStyle().Foreground(ColorMuted).SetString("by dpanic").String()
	title := "OS Kickstart " + byLine
	if !m.checksRan {
		title += "  " + m.spinner.View() + " checking for updates"
	}
	b.WriteString(headerBox.Render(title) + "\n")
	b.WriteString(MutedStyle.Render(" ↑/↓ navigate • space select • ctrl+a all • / filter • enter confirm") + "\n")
	if m.filtering {
		b.WriteString(lipgloss.NewStyle().Foreground(ColorAccent2).Render(" / " + m.filter + "█") + "\n")
	} else if m.filter != "" {
		b.WriteString(lipgloss.NewStyle().Foreground(ColorAccent2).Render(" filter: "+m.filter) +
			MutedStyle.Render(" (esc clear)") + "\n")
	}

	// Build all lines (filtered or full)
	var lines []string
	if m.filter != "" && m.visible != nil {
		for _, idx := range m.visible {
			lines = append(lines, m.renderItem(idx, m.items[idx]))
		}
	} else {
		for i, item := range m.items {
			lines = append(lines, m.renderItem(i, item))
		}
	}

	// Apply scroll window
	end := m.offset + m.height
	if end > len(lines) {
		end = len(lines)
	}
	start := m.offset
	if start > len(lines) {
		start = len(lines)
	}

	for _, line := range lines[start:end] {
		b.WriteString(line + "\n")
	}

	if end < len(lines) {
		b.WriteString(MutedStyle.Render("  ▼ " + fmt.Sprintf("%d more", len(lines)-end)) + "\n")
	}

	// Footer
	count := len(m.selected)
	total := m.selectableCount()
	footer := fmt.Sprintf("\n  %d / %d selected", count, total)

	// Count available updates
	updates := 0
	for _, item := range m.items {
		if strings.HasPrefix(item.Status, "[update") {
			updates++
		}
	}
	if updates > 0 {
		footer += fmt.Sprintf("  •  %d update(s) available", updates)
	}

	b.WriteString(MutedStyle.Render(footer))

	return b.String()
}

func (m menuModel) renderItem(i int, item menuItem) string {
	if item.separator {
		label := item.label
		if !strings.HasPrefix(label, "  ") {
			return sectionStyle.Render(fmt.Sprintf("  ── %s ──", label))
		}
		return subsectionStyle.Render(fmt.Sprintf("    %s", strings.TrimSpace(label)))
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
		case strings.HasPrefix(item.Status, "[update"):
			line += " " + updateAvailableStyle.Render(item.Status)
		case strings.HasPrefix(item.Status, "[latest"):
			line += " " + latestStyle.Render(item.Status)
		case item.Status == "[installed]":
			line += " " + installedStyle.Render(item.Status)
		default:
			line += " " + MutedStyle.Render(item.Status)
		}
	}

	return line
}

func (m menuModel) prevSelectable(from int) int {
	i := from - 1
	for i >= 0 {
		if !m.items[i].separator {
			return i
		}
		i--
	}
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
