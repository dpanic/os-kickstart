package tui

import (
	"context"
	"fmt"
	"net/http"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type updateCheckResult struct {
	moduleID string
	status   string // "[update: x → y]", "[latest]", "[installed]", ""
}

type updateCheckDoneMsg struct {
	results []updateCheckResult
}

type updateChecker struct {
	repo       string         // "owner/repo"
	moduleID   string
	versionCmd []string       // command to get installed version
	versionRe  *regexp.Regexp // regex to extract semver from command output
}

var checkers = []updateChecker{
	{
		moduleID:   "shell-starship",
		repo:       "starship/starship",
		versionCmd: []string{"starship", "--version"},
		versionRe:  regexp.MustCompile(`(\d+\.\d+\.\d+)`),
	},
	{
		moduleID:   "shell-fzf",
		repo:       "junegunn/fzf",
		versionCmd: []string{"fzf", "--version"},
		versionRe:  regexp.MustCompile(`(\d+\.\d+\.\d+)`),
	},
	{
		moduleID:   "go",
		repo:       "golang/go",
		versionCmd: []string{"go", "version"},
		versionRe:  regexp.MustCompile(`go(\d+\.\d+\.\d+)`),
	},
	{
		moduleID:   "yazi",
		repo:       "sxyazi/yazi",
		versionCmd: []string{"yazi", "--version"},
		versionRe:  regexp.MustCompile(`(\d+\.\d+\.\d+)`),
	},
	{
		moduleID:   "neovim",
		repo:       "neovim/neovim",
		versionCmd: []string{"nvim", "--version"},
		versionRe:  regexp.MustCompile(`v(\d+\.\d+\.\d+)`),
	},
	{
		moduleID:   "peazip",
		repo:       "peazip/PeaZip",
		versionCmd: []string{"peazip", "--version"},
		versionRe:  regexp.MustCompile(`(\d+\.\d+\.\d+)`),
	},
}

// runUpdateChecks returns a Cmd that checks all registered modules for
// available updates by comparing the locally installed version against
// the latest GitHub release tag.
func runUpdateChecks() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		results := make([]updateCheckResult, len(checkers))
		var wg sync.WaitGroup

		for i, c := range checkers {
			wg.Add(1)
			go func(idx int, chk updateChecker) {
				defer wg.Done()
				checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
				defer checkCancel()
				results[idx] = checkOne(checkCtx, chk)
			}(i, c)
		}

		wg.Wait()
		return updateCheckDoneMsg{results: results}
	}
}

func checkOne(ctx context.Context, c updateChecker) updateCheckResult {
	installed := getInstalledVersion(c.versionCmd, c.versionRe)
	if installed == "" {
		// Not installed — no badge.
		return updateCheckResult{moduleID: c.moduleID, status: ""}
	}

	latest := getLatestGitHubVersion(ctx, c.repo)
	if latest == "" {
		// Could not reach GitHub — show what we know.
		return updateCheckResult{moduleID: c.moduleID, status: "[installed]"}
	}

	if installed == latest {
		return updateCheckResult{moduleID: c.moduleID, status: "[latest]"}
	}

	return updateCheckResult{
		moduleID: c.moduleID,
		status:   fmt.Sprintf("[update: %s → %s]", installed, latest),
	}
}

func getInstalledVersion(cmd []string, re *regexp.Regexp) string {
	if len(cmd) == 0 {
		return ""
	}

	out, err := exec.Command(cmd[0], cmd[1:]...).Output()
	if err != nil {
		return ""
	}

	matches := re.FindStringSubmatch(string(out))
	if len(matches) < 2 {
		return ""
	}
	return matches[1]
}

// getLatestGitHubVersion performs an HTTP HEAD to the releases/latest
// endpoint, stops at the 302 redirect, and extracts the version tag
// from the Location header.
func getLatestGitHubVersion(ctx context.Context, repo string) string {
	url := fmt.Sprintf("https://github.com/%s/releases/latest", repo)

	client := &http.Client{
		Timeout: 5 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return ""
	}

	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	loc := resp.Header.Get("Location")
	if loc == "" {
		return ""
	}

	// Location looks like: .../releases/tag/v1.2.3
	parts := strings.Split(loc, "/")
	if len(parts) == 0 {
		return ""
	}

	tag := parts[len(parts)-1]
	tag = strings.TrimPrefix(tag, "v")
	tag = strings.TrimPrefix(tag, "go") // golang/go tags: go1.22.0
	return tag
}
