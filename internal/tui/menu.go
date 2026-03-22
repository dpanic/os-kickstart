package tui

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dpanic/os-kickstart/internal/modules"
	"golang.org/x/term"
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
	width      int
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

	items = append(items, menuItem{separator: true, label: ""}) // spacer
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
		mod := items[i].module
		if mod.InstalledCmd != "" && isInstalled(mod.InstalledCmd) {
			items[i].Status = "[installed]"
		} else if mod.InstalledCheck != "" {
			path := os.ExpandEnv(mod.InstalledCheck)
			if _, err := os.Stat(path); err == nil {
				items[i].Status = "[installed]"
			}
		} else if mod.InstalledGrepFile != "" {
			parts := strings.SplitN(mod.InstalledGrepFile, ":", 2)
			if len(parts) == 2 {
				data, err := os.ReadFile(parts[0])
				if err == nil && strings.Contains(string(data), parts[1]) {
					items[i].Status = "[installed]"
				}
			}
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
		height:   detectTermHeight(),
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
			if r.status == "" {
				continue
			}
			for i := range m.items {
				if !m.items[i].separator && m.items[i].module.ID == r.moduleID {
					current := m.items[i].Status
					// Only upgrade: update > installed+ver > installed > empty
					if strings.HasPrefix(r.status, "[update") {
						m.items[i].Status = r.status
					} else if strings.Contains(r.status, " ") && !strings.Contains(current, " ") {
						// New has version, current doesn't
						m.items[i].Status = r.status
					} else if current == "" {
						m.items[i].Status = r.status
					}
				}
			}
		}
		return m, nil

	case tea.WindowSizeMsg:
		m.width = msg.Width
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

func detectTermHeight() int {
	_, h, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || h <= 0 {
		h = 30
	}
	usable := int(float64(h) * 0.80)
	if usable < 10 {
		usable = 10
	}
	return usable
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
	// Scroll by 1 to keep cursor visible
	for m.cursor < m.offset {
		m.offset--
	}
	for m.cursor >= m.offset+m.height {
		m.offset++
	}

	// Clamp
	if m.offset < 0 {
		m.offset = 0
	}
	max := len(m.items) - m.height
	if max < 0 {
		max = 0
	}
	if m.offset > max {
		m.offset = max
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
)

func (m menuModel) View() string {
	var b strings.Builder
	w := m.width
	if w <= 0 {
		w = 80
	}

	// ── Header ──────────────────────────────────────────────────
	titleText := HeaderTitleStyle.Render("OS Kickstart")
	byText := HeaderByLineStyle.Render(" by dpanic")
	headerLeft := lipgloss.JoinHorizontal(lipgloss.Center, titleText, byText)

	if !m.checksRan {
		spinnerText := HeaderSpinnerLabel.Render(" checking for updates")
		headerLeft = lipgloss.JoinHorizontal(
			lipgloss.Center,
			headerLeft,
			"  ",
			m.spinner.View(),
			spinnerText,
		)
	}

	header := HeaderBorderStyle.Width(w - 4).Render(headerLeft)
	b.WriteString(header + "\n")

	// ── Help bar ────────────────────────────────────────────────
	helpParts := []struct {
		key  string
		desc string
	}{
		{"↑/↓", "navigate"},
		{"space", "select"},
		{"ctrl+a", "all"},
		{"/", "filter"},
		{"enter", "confirm"},
		{"q", "quit"},
	}
	var helpSegments []string
	sep := HelpSepStyle.Render(" · ")
	for _, h := range helpParts {
		helpSegments = append(
			helpSegments,
			HelpKeyStyle.Render(h.key)+" "+HelpDescStyle.Render(h.desc),
		)
	}
	helpLine := " " + strings.Join(helpSegments, sep)
	b.WriteString(helpLine + "\n")

	// ── Filter bar ──────────────────────────────────────────────
	if m.filtering {
		b.WriteString(
			lipgloss.NewStyle().Foreground(ColorAccent2).Render(" / "+m.filter+"█") + "\n",
		)
	} else if m.filter != "" {
		b.WriteString(
			lipgloss.NewStyle().Foreground(ColorAccent2).Render(" filter: "+m.filter) +
				MutedStyle.Render(" (esc clear)") + "\n",
		)
	}

	// ── List ────────────────────────────────────────────────────
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

	// Apply scroll window — always render exactly m.height lines to prevent flicker
	start := m.offset
	if start > len(lines) {
		start = len(lines)
	}
	end := start + m.height
	if end > len(lines) {
		end = len(lines)
	}

	// Sticky section header — show current section if its separator scrolled off
	if m.filter == "" && start > 0 {
		currentSection := ""
		for idx := start; idx >= 0; idx-- {
			if idx < len(m.items) && m.items[idx].separator && m.items[idx].label != "" && !strings.HasPrefix(m.items[idx].label, "  ") {
				currentSection = m.items[idx].label
				break
			}
		}
		if currentSection != "" {
			b.WriteString(sectionStyle.Render(fmt.Sprintf("  ── %s ──", currentSection)) + "\n")
		}
	}

	rendered := 0
	for _, line := range lines[start:end] {
		b.WriteString(line + "\n")
		rendered++
	}

	// Show scroll indicator or pad
	if end < len(lines) {
		b.WriteString(MutedStyle.Render(fmt.Sprintf("  ▼ %d more", len(lines)-end)) + "\n")
		rendered++
	}

	// Pad remaining lines to keep total height constant
	for rendered < m.height+1 {
		b.WriteString("\n")
		rendered++
	}

	// ── Footer status bar ───────────────────────────────────────
	count := len(m.selected)
	total := m.selectableCount()
	leftText := FooterCountStyle.Render(fmt.Sprintf(" %d / %d selected", count, total))

	updates := 0
	for _, item := range m.items {
		if strings.HasPrefix(item.Status, "[update") {
			updates++
		}
	}

	rightText := ""
	if updates > 0 {
		rightText = FooterUpdateStyle.Render(
			fmt.Sprintf("%d update(s) available ", updates),
		)
	}

	// Pad the bar to fill the full terminal width
	leftWidth := lipgloss.Width(leftText)
	rightWidth := lipgloss.Width(rightText)
	gap := w - leftWidth - rightWidth
	if gap < 0 {
		gap = 0
	}

	footerBar := FooterBarStyle.Width(w).Render(
		leftText + strings.Repeat(" ", gap) + rightText,
	)
	b.WriteString("\n" + footerBar)

	return b.String()
}

func (m menuModel) renderItem(i int, item menuItem) string {
	if item.separator {
		label := item.label
		if label == "" {
			return "" // spacer
		}
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
	} else if strings.HasPrefix(item.Status, "[installed") {
		checkbox = MutedStyle.Render("[✓]")
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
		case strings.HasPrefix(item.Status, "[installed"):
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
