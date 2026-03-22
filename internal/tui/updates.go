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
	"github.com/dpanic/os-kickstart/internal/modules"
)

type updateCheckResult struct {
	moduleID string
	status   string // "[update available]", "[latest]", "[installed]", ""
}

type updateCheckDoneMsg struct {
	results []updateCheckResult
}

type versionChecker struct {
	moduleID   string
	repo       string         // "owner/repo" for GitHub release check
	versionCmd []string       // command to get installed version
	versionRe  *regexp.Regexp // regex to extract semver from command output
}

// checkers defines modules that have GitHub release version tracking.
var versionCheckers = []versionChecker{
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

// runUpdateChecks checks both version updates (GitHub) and installed status for all modules.
func runUpdateChecks(mods []modules.Module) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()

		// Build lookup for version checkers
		versionMap := make(map[string]*versionChecker, len(versionCheckers))
		for i := range versionCheckers {
			versionMap[versionCheckers[i].moduleID] = &versionCheckers[i]
		}

		results := make([]updateCheckResult, len(mods))
		var wg sync.WaitGroup

		for i, mod := range mods {
			wg.Add(1)
			go func(idx int, m modules.Module) {
				defer wg.Done()

				// Check if this module has a version checker (GitHub releases)
				if vc, ok := versionMap[m.ID]; ok {
					checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
					defer checkCancel()
					results[idx] = checkVersion(checkCtx, *vc)
					return
				}

				// Otherwise just check if installed
				if m.InstalledCmd != "" {
					if isInstalled(m.InstalledCmd) {
						results[idx] = updateCheckResult{
							moduleID: m.ID,
							status:   "[installed]",
						}
					} else {
						results[idx] = updateCheckResult{moduleID: m.ID}
					}
					return
				}

				results[idx] = updateCheckResult{moduleID: m.ID}
			}(i, mod)
		}

		wg.Wait()
		return updateCheckDoneMsg{results: results}
	}
}

func checkVersion(ctx context.Context, c versionChecker) updateCheckResult {
	installed := getInstalledVersion(ctx, c.versionCmd, c.versionRe)
	if installed == "" {
		return updateCheckResult{moduleID: c.moduleID}
	}

	latest := getLatestGitHubVersion(ctx, c.repo)
	if latest == "" {
		return updateCheckResult{moduleID: c.moduleID, status: "[installed]"}
	}

	if installed == latest {
		return updateCheckResult{moduleID: c.moduleID, status: fmt.Sprintf("[latest %s]", installed)}
	}

	return updateCheckResult{
		moduleID: c.moduleID,
		status:   fmt.Sprintf("[update %s → %s]", installed, latest),
	}
}

func isInstalled(cmd string) bool {
	_, err := exec.LookPath(cmd)
	return err == nil
}

func getInstalledVersion(ctx context.Context, cmd []string, re *regexp.Regexp) string {
	if len(cmd) == 0 {
		return ""
	}

	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	out, err := c.Output()
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

	parts := strings.Split(loc, "/")
	if len(parts) == 0 {
		return ""
	}

	tag := parts[len(parts)-1]
	// Extract semver from tag — handles "v1.2.3", "go1.22.0", plain "1.2.3"
	re := regexp.MustCompile(`(\d+\.\d+\.\d+)`)
	if m := re.FindString(tag); m != "" {
		return m
	}
	return ""
}
