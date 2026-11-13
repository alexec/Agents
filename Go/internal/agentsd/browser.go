package agentsd

import (
	"context"
	"embed"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/browser"
	"github.com/agentloops-dev/agents/Go/wire"
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
	d.browser.Changed = d.browserChanged
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
	tidyNode()
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

// Settings ▸ Browser (#3535): the sites the kept profile has cookies for, Clear, and the size
// of the download. Only the person's own clients reach them (Role.Allows): the sites say
// where the person signed in, and Clear signs agents out.

// browserReadTimeout bounds a read or a clear, which may first start Chromium.
const browserReadTimeout = 30 * time.Second

func (d *Daemon) browserState(ctx context.Context) wire.BrowserState {
	st := wire.BrowserState{Sites: []wire.BrowserSite{}}
	if d.browser == nil {
		return st
	}
	st.Installed = d.browser.Installed()
	if st.Installed {
		ctx, cancel := context.WithTimeout(ctx, browserReadTimeout)
		defer cancel()
		sites, err := d.browser.Sites(ctx)
		if err != nil {
			problem := "The sites could not be read: " + err.Error()
			st.Problem = &problem
		}
		for _, s := range sites {
			st.Sites = append(st.Sites, wire.BrowserSite{Site: s.Site, Cookies: int64(s.Cookies)})
		}
	}
	// After the sites, which may have finished a download.
	st.DownloadBytes = d.browser.DownloadBytes()
	st.Running = d.browser.Running()
	return st
}

func (d *Daemon) registerBrowserSettings() {
	On(d, wire.CallBrowserState, func(ctx context.Context, _ *Client, _ wire.Empty) (wire.BrowserState, error) {
		return d.browserState(ctx), nil
	})
	On(d, wire.CallBrowserClear, func(ctx context.Context, _ *Client, in wire.BrowserClearRequest) (wire.BrowserState, error) {
		if d.browser != nil {
			site := ""
			if in.Site != nil {
				site = strings.TrimSpace(*in.Site)
			}
			cleared, cancel := context.WithTimeout(ctx, browserReadTimeout)
			err := d.browser.Clear(cleared, site)
			cancel()
			if err != nil {
				return wire.BrowserState{}, &Error{Code: CodeInternal, Message: "The browser's sites were not cleared: " + err.Error()}
			}
		}
		return d.browserState(ctx), nil
	})
}
