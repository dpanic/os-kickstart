package modules_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func readRepoFile(t *testing.T, parts ...string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(append([]string{repoRoot(t)}, parts...)...))
	if err != nil {
		t.Fatalf("read %v: %v", parts, err)
	}
	return string(b)
}

// DefaultLimitRTPRIO in user.conf.d is silently clamped to the hard limit the user manager
// inherited from user@.service (0), so it reads back as 95 from `systemctl --user show` while
// /proc/<pid>/limits stays 0. It was shipped for years on the false premise that mutter and
// pipewire need it; rtkit holds CAP_SYS_NICE and grants SCHED_RR without it.
func TestRTTimeDropInHasNoRTPrio(t *testing.T) {
	t.Parallel()
	conf := readRepoFile(t, "modules", "kernel", "10-kickstart-rttime.conf")

	body := stripConfComments(conf)
	if strings.Contains(body, "DefaultLimitRTPRIO") {
		t.Error("10-kickstart-rttime.conf sets DefaultLimitRTPRIO: it cannot apply from user.conf.d and is not needed")
	}
	if !strings.Contains(body, "[Manager]") {
		t.Error("10-kickstart-rttime.conf must use [Manager]: it installs into user.conf.d, not as a unit drop-in")
	}
	// Below rtkit's --rttime-usec-max the realtime path aborts on setrlimit(RLIMIT_RTTIME).
	if !strings.Contains(body, "DefaultLimitRTTIME=200000") {
		t.Error("10-kickstart-rttime.conf must set DefaultLimitRTTIME=200000 to match rtkit's RTTimeUSecMax")
	}
}

// The RTPRIO drop-in shipped to a path where it could never work and nothing ever checked.
// Install and revert drifting apart is the general shape of that bug, so pin the symmetry.
func TestCPUFreqInstallAndRevertPathsMatch(t *testing.T) {
	t.Parallel()
	script := readRepoFile(t, "modules", "kernel", "optimize.sh")

	revert := section(t, script, `if [[ "$UNINSTALL" == true ]]; then`, "# ── sysctl drop-in")
	install := section(t, script, "# ── cpufreq ", "")

	for _, p := range systemPaths(install) {
		if !strings.Contains(revert, p) {
			t.Errorf("cpufreq install writes %s but the revert block never removes it", p)
		}
	}
}

var (
	confCommentRe = regexp.MustCompile(`(?m)^\s*#.*$`)
	systemPathRe  = regexp.MustCompile(`/(?:etc|usr)/[A-Za-z0-9._@/-]+`)
)

func stripConfComments(s string) string { return confCommentRe.ReplaceAllString(s, "") }

func section(t *testing.T, s, start, end string) string {
	t.Helper()
	i := strings.Index(s, start)
	if i < 0 {
		t.Fatalf("optimize.sh: marker %q not found", start)
	}
	s = s[i:]
	if end == "" {
		return s
	}
	j := strings.Index(s, end)
	if j < 0 {
		t.Fatalf("optimize.sh: marker %q not found after %q", end, start)
	}
	return s[:j]
}

func systemPaths(block string) []string {
	seen := map[string]bool{}
	var out []string
	for _, m := range systemPathRe.FindAllString(block, -1) {
		// Directories are created, not installed, so revert has nothing to remove for them.
		if strings.HasSuffix(m, "/") || filepath.Ext(m) == "" {
			continue
		}
		if !seen[m] {
			seen[m] = true
			out = append(out, m)
		}
	}
	return out
}
