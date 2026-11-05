package agentsd

import (
	"embed"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// The machine's browser (#3533): one Chromium, started on first use and stopped when
// idle (internal/browser). Node and @playwright/mcp come as a Node toolset, pinned here
// and carried in this binary, so a Linux machine gets them with agentsd itself; the
// runtimes' toolset installer puts them in <tools>/browser beside Claude's and Codex's.
// Playwright's own installer then fetches the Chromium that matches.

//go:embed browsertoolset
var browserToolsetFiles embed.FS

// browserToolsetID is the toolset's runtimeID: its folder under the tools.
const browserToolsetID = "browser"

// startBrowser makes the machine's browser. It starts nothing.
func (d *Daemon) startBrowser() {
	d.browser = browser.New(d.Store.Loc.Cache, d.Store.Loc.Root, d.installBrowserToolset, d.browserBusy, loginEnvironment)
}

// installBrowserToolset installs the pinned toolset, unless it is whole already.
func (d *Daemon) installBrowserToolset(progress func(string)) (browser.Toolset, error) {
	if toolsHome == "" {
		return browser.Toolset{}, installFailure("The browser can't be installed on " + thisMachine() + ".")
	}
	folder := filepath.Join(d.Store.Loc.Cache, "browser", "toolsets")
	if err := writeBrowserToolset(filepath.Join(folder, browserToolsetID)); err != nil {
		return browser.Toolset{}, err
	}
	t := loadToolsets(folder)[browserToolsetID]
	if t == nil {
		return browser.Toolset{}, installFailure("This build of agentsd carries no browser toolset.")
	}
	if err := t.installNode(progress); err != nil {
		return browser.Toolset{}, err
	}
	t.tidy()
	cur := filepath.Join(toolsHome, browserToolsetID, "current")
	return browser.Toolset{
		Node:     filepath.Join(cur, "node", "bin", "node"),
		Packages: filepath.Join(cur, "lib", "node_modules"),
	}, nil
}

// writeBrowserToolset lays the embedded manifest, package.json, lock and Mac Node pin in
// dir, where loadToolsets reads a toolset.
func writeBrowserToolset(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	names, err := fs.ReadDir(browserToolsetFiles, "browsertoolset")
	if err != nil {
		return err
	}
	for _, n := range names {
		b, err := browserToolsetFiles.ReadFile("browsertoolset/" + n.Name())
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, n.Name()), b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// browserBusy is whether an agent holds the browser's lease or waits for it.
func (d *Daemon) browserBusy() bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	e := d.book.Entries[wire.ResourceName(browser.Resource)]
	return e != nil && (len(e.Leases) > 0 || len(e.Line) > 0)
}
