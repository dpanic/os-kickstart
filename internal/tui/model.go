package tui

import (
	"io/fs"
	"runtime"

	tea "github.com/charmbracelet/bubbletea"
	kickembed "github.com/dpanic/os-kickstart/internal/embed"
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
	tmpDir    string
	cleanupFn func()
}

// New creates a new root Model.
func New(cfg Config) Model {
	mods := modules.ForOS(runtime.GOOS)
	return Model{
		config: cfg,
		screen: screenMenu,
		menu:   newMenuModel(mods),
		mode:   newModeModel(),
	}
}

var (
	// globalProgram holds the tea.Program reference for sending messages
	// from background goroutines (e.g., real-time script output).
	globalProgram *tea.Program

	// globalCleanup is called on SIGTERM or abnormal exit to remove tmpdir.
	globalCleanup func()
)

// SetProgram injects the tea.Program reference. Must be called
// after tea.NewProgram and before Run.
func SetProgram(p *tea.Program) {
	globalProgram = p
}

// RunCleanup calls the registered cleanup function (tmpdir removal).
func RunCleanup() {
	if globalCleanup != nil {
		globalCleanup()
		globalCleanup = nil
	}
}

// Init returns the initial command for the program.
func (m Model) Init() tea.Cmd {
	return m.menu.Init()
}

// Update handles messages and routes them to the active screen.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Fall through — let active screen also handle window size

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
		switch msg.to {
		case screenGitInfo:
			showWebhook := modules.NeedsWebhook(m.selectedModules)
			if !modules.NeedsUserInfo(m.selectedModules) {
				m.screen = screenConfirm
				m.confirm = newConfirmModel(len(m.selectedModules), m.selectedMode)
				return m, m.confirm.Init()
			}
			m.gitInfo = newGitInfoModel(showWebhook)
			return m, m.gitInfo.Init()
		case screenConfirm:
			m.confirm = newConfirmModel(len(m.selectedModules), m.selectedMode)
			return m, m.confirm.Init()
		}
		return m, m.initScreen(msg.to)

	case selectedModulesMsg:
		m.selectedModules = msg.modules

	case selectedModeMsg:
		m.selectedMode = msg.mode

	case userInfoMsg:
		m.userName = msg.name
		m.userEmail = msg.email
		m.webhookURL = msg.webhook

	case confirmMsg:
		// Extract embedded assets and start execution
		tmpDir, cleanup, err := kickembed.Extract(m.config.Assets)
		if err != nil {
			// Fall back to summary with error
			m.screen = screenSummary
			m.summary = newSummaryModel(nil)
			return m, nil
		}
		m.tmpDir = tmpDir
		m.cleanupFn = cleanup
		globalCleanup = cleanup

		env := map[string]string{
			"KICKSTART_USER_NAME":  m.userName,
			"KICKSTART_USER_EMAIL": m.userEmail,
		}

		m.executor = newExecutorModel(
			m.selectedModules,
			tmpDir,
			m.selectedMode.Flag(),
			env,
			m.webhookURL,
		)
		m.executor.program = globalProgram
		m.screen = screenExecutor
		return m, m.executor.Init()

	case allDoneMsg:
		if m.cleanupFn != nil {
			m.cleanupFn()
			m.cleanupFn = nil
		}
		m.summary = newSummaryModel(m.executor.results)
		m.screen = screenSummary
		return m, m.summary.Init()
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
