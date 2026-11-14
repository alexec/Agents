package hostinstall

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The browser step (#5228) says once, in the log, why a server keeps Chrome for Testing
// headless, and never fails the install. The fake server has no sudo, so it installs
// nothing here.
func TestTheBrowserStepSaysWhyItInstallsNothing(t *testing.T) {
	// The fake server is this machine. GitHub's Linux runners have Chrome and Xvfb
	// already: then the step has nothing to do and says nothing.
	_, chrome := exec.LookPath("google-chrome-stable")
	_, xvfb := exec.LookPath("Xvfb")
	installed := chrome == nil && xvfb == nil
	for _, tc := range []struct{ uname, says string }{
		{"Linux aarch64", "Google ships no Chrome for Linux Linux aarch64."},
		// Not root and no sudo: on a Mac, not Debian; on a Linux runner, no root.
		{"x86_64", "The agents' browser here stays Chrome for Testing headless:"},
	} {
		f := newFake(t)
		f.env["FAKE_SSH_UNAME"] = tc.uname
		server := installer{sshCommand{executable: filepath.Join(f.dir, "ssh"), name: "devbox", env: f.environ()}}
		var lines []string
		server.installBrowser(context.Background(), func(format string, args ...any) {
			lines = append(lines, fmt.Sprintf(format, args...))
		}, "Dev box")
		if installed {
			if len(lines) != 0 {
				t.Fatalf("%s, Chrome and Xvfb there: %q", tc.uname, lines)
			}
			continue
		}
		if len(lines) != 1 || !strings.HasPrefix(lines[0], "Dev box: The agents' browser here stays Chrome for Testing headless:") ||
			!strings.Contains(lines[0], tc.says) {
			t.Fatalf("%s: %q", tc.uname, lines)
		}
	}
}

// The step goes to sh whatever the login shell is, with the function and its call.
func TestTheBrowserStepRunsInSh(t *testing.T) {
	if !strings.Contains(browserScript, "install_browser() {") || !strings.HasSuffix(browserScript, "}\n") {
		t.Fatal("browser.sh is not the install_browser function")
	}
}
