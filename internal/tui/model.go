package tui

import (
	"io/fs"
	"runtime"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/dpanic/os-kickstart/internal/modules"
)

// Config holds parameters passed from main.go.
type Config struct {
	Assets  fs.FS
	Version string
	Commit  string
}

// Model is the root Bubble Tea model.
type Model struct {
	config Config
	screen screen
	width  int
	height int

	// Screen models
	banner   bannerModel
	menu     menuModel
	mode     modeModel
	gitInfo  gitInfoModel
	confirm  confirmModel
	executor executorModel
	summary  summaryModel

	// Shared state
	selectedModules []modules.Module
	selectedMode    mode
	userName        string
	userEmail       string
	webhookURL      string
	tmpDir          string
	cleanupFn       func()
}

// New creates a new root Model.
func New(cfg Config) Model {
	mods := modules.ForOS(runtime.GOOS)
	return Model{
		config: cfg,
		screen: screenBanner,
		banner: newBannerModel(cfg.Version, cfg.Commit),
		menu:   newMenuModel(mods),
		mode:   newModeModel(),
	}
}

// Init returns the initial command for the program.
func (m Model) Init() tea.Cmd {
	return m.banner.Init()
}

// Update handles messages and routes them to the active screen.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			if m.cleanupFn != nil {
				m.cleanupFn()
			}
			return m, tea.Quit
		}
	}

	// Route to active screen
	var cmd tea.Cmd
	switch m.screen {
	case screenBanner:
		m.banner, cmd = m.banner.Update(msg)
	case screenMenu:
		m.menu, cmd = m.menu.Update(msg)
	case screenMode:
		m.mode, cmd = m.mode.Update(msg)
	case screenGitInfo:
		m.gitInfo, cmd = m.gitInfo.Update(msg)
	case screenConfirm:
		m.confirm, cmd = m.confirm.Update(msg)
	case screenExecutor:
		m.executor, cmd = m.executor.Update(msg)
	case screenSummary:
		m.summary, cmd = m.summary.Update(msg)
	}

	// Handle screen transition messages
	switch msg := msg.(type) {
	case switchScreenMsg:
		m.screen = msg.to
		return m, m.initScreen(msg.to)
	case selectedModulesMsg:
		m.selectedModules = msg.modules
	case selectedModeMsg:
		m.selectedMode = msg.mode
	case userInfoMsg:
		m.userName = msg.name
		m.userEmail = msg.email
		m.webhookURL = msg.webhook
	}

	return m, cmd
}

// View renders the active screen.
func (m Model) View() string {
	switch m.screen {
	case screenBanner:
		return m.banner.View()
	case screenMenu:
		return m.menu.View()
	case screenMode:
		return m.mode.View()
	case screenGitInfo:
		return m.gitInfo.View()
	case screenConfirm:
		return m.confirm.View()
	case screenExecutor:
		return m.executor.View()
	case screenSummary:
		return m.summary.View()
	}
	return ""
}

func (m Model) initScreen(s screen) tea.Cmd {
	switch s {
	case screenBanner:
		return m.banner.Init()
	case screenMenu:
		return m.menu.Init()
	case screenMode:
		return m.mode.Init()
	case screenGitInfo:
		return m.gitInfo.Init()
	case screenConfirm:
		return m.confirm.Init()
	case screenExecutor:
		return m.executor.Init()
	case screenSummary:
		return m.summary.Init()
	}
	return nil
}
