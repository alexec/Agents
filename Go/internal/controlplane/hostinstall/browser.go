package hostinstall

import (
	"context"
	_ "embed"
	"strings"
)

// browserScript defines install_browser: Google Chrome stable and Xvfb for the agents'
// browser on Linux (#5209, #5228), when the server has root or sudo with no password.
// install.sh holds the same text, for a server that joins with a code.
//
//go:embed browser.sh
var browserFile string

// browserScript is browser.sh without the line that tells shellcheck its shell.
var browserScript = strings.TrimPrefix(browserFile, browserDirective)

const browserDirective = "# shellcheck shell=sh\n"

// installBrowser runs install_browser on the server, in sh whatever the person's login
// shell is. It never fails the install: a server without Chrome keeps Chrome for
// Testing headless. What it says goes to the log.
func (i installer) installBrowser(ctx context.Context, log func(string, ...any), name string) {
	out, err := i.run(ctx, "sh -c "+quote(browserScript+"install_browser"))
	if log == nil {
		return
	}
	if err != nil {
		log("%s: the agents' browser was not installed: %v", name, err)
		return
	}
	if said := strings.TrimSpace(out.stdout); said != "" {
		log("%s: %s", name, said)
	}
}
