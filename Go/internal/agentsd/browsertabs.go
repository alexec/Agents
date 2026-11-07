package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"slices"
	"strings"
	"sync"

	"github.com/chromedp/cdproto/target"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// Each session's tabs in the machine's browser (#3916). There is one Chromium and one
// profile, so the sign-ins are shared, and one agent at a time drives it (browser:agents).
// agentsd follows the browser's tabs while it runs: a tab that opens while an agent drives
// is that agent's, as is a tab that one of its tabs opened, and a tab the person opens from
// a session's pane is that session's. A session's pane shows the newest tab of its own; an
// agent's @playwright/mcp starts on that tab, or on a new one, never on another session's.
// It is kept in memory only: a new agentsd, like a new Chromium, starts with no owners.

// browserTabState is the Daemon's record of the tabs. Under tabsMu, which is taken after
// bw.mu and never before it.
type browserTabState struct {
	tabsMu       sync.Mutex
	tabs         *browser.Tabs
	tabsEndpoint string
	// tabOwner is each tab's session; ownTabs each session's tabs, the newest last.
	tabOwner map[target.ID]wire.UUID
	ownTabs  map[wire.UUID][]target.ID
	// driver is the agent whose turn drives the browser now: a tab that opens is its.
	driver wire.UUID
	// usedTurn is each agent that has used the browser in its turn now.
	usedTurn map[wire.UUID]bool
}

// sessionKey is a session's id as these records and the watches keep it: a client may
// send it in either case.
func sessionKey(id wire.UUID) wire.UUID { return wire.UUID(strings.ToUpper(string(id))) }

// followBrowserTabs follows the tabs of the browser at endpoint, unless it does already.
func (d *Daemon) followBrowserTabs(endpoint string) {
	d.tabsMu.Lock()
	if d.tabs != nil && d.tabsEndpoint == endpoint {
		d.tabsMu.Unlock()
		return
	}
	old := d.tabs
	d.tabs, d.tabsEndpoint = nil, ""
	d.tabOwner, d.ownTabs = nil, nil
	d.tabsMu.Unlock()
	if old != nil {
		old.Close()
	}
	var t *browser.Tabs
	t, err := browser.FollowTabs(endpoint, d.browserTabCreated, d.browserTabClosed, func() { d.browserTabsEnded(t) })
	if err != nil {
		log.Printf("browser: couldn't follow the tabs: %v", err)
		return
	}
	d.tabsMu.Lock()
	if d.tabs != nil {
		// Another call got there first.
		d.tabsMu.Unlock()
		t.Close()
		return
	}
	d.tabs, d.tabsEndpoint = t, endpoint
	d.tabsMu.Unlock()
}

// stopFollowingBrowserTabs is the browser stopped: its tabs are gone, and their owners.
func (d *Daemon) stopFollowingBrowserTabs() {
	d.tabsMu.Lock()
	t := d.tabs
	d.tabs, d.tabsEndpoint = nil, ""
	d.tabOwner, d.ownTabs = nil, nil
	d.tabsMu.Unlock()
	if t != nil {
		t.Close()
	}
}

func (d *Daemon) browserTabsEnded(t *browser.Tabs) {
	d.tabsMu.Lock()
	if d.tabs != t || t == nil {
		d.tabsMu.Unlock()
		return
	}
	d.tabs, d.tabsEndpoint = nil, ""
	d.tabOwner, d.ownTabs = nil, nil
	d.tabsMu.Unlock()
}

// browserTabCreated gives a new tab to the session of the tab that opened it, or to the
// agent that drives the browser now. A tab nobody drives into is nobody's.
func (d *Daemon) browserTabCreated(tab, opener target.ID) {
	d.tabsMu.Lock()
	owner := d.tabOwner[opener]
	if owner == "" {
		owner = d.driver
	}
	if owner == "" || d.tabOwner[tab] != "" {
		d.tabsMu.Unlock()
		return
	}
	d.ownTabLocked(owner, tab)
	d.tabsMu.Unlock()
	d.sessionTabChanged(owner)
}

func (d *Daemon) browserTabClosed(tab target.ID) {
	d.tabsMu.Lock()
	owner := d.tabOwner[tab]
	if owner == "" {
		d.tabsMu.Unlock()
		return
	}
	delete(d.tabOwner, tab)
	d.ownTabs[owner] = slices.DeleteFunc(d.ownTabs[owner], func(t target.ID) bool { return t == tab })
	if len(d.ownTabs[owner]) == 0 {
		delete(d.ownTabs, owner)
	}
	d.tabsMu.Unlock()
	d.sessionTabChanged(owner)
}

// ownTabLocked makes tab the newest of agent's, away from any other session. Under tabsMu.
func (d *Daemon) ownTabLocked(agent wire.UUID, tab target.ID) {
	agent = sessionKey(agent)
	if d.tabOwner == nil {
		d.tabOwner, d.ownTabs = map[target.ID]wire.UUID{}, map[wire.UUID][]target.ID{}
	}
	if was := d.tabOwner[tab]; was != "" {
		d.ownTabs[was] = slices.DeleteFunc(d.ownTabs[was], func(t target.ID) bool { return t == tab })
		if len(d.ownTabs[was]) == 0 {
			delete(d.ownTabs, was)
		}
	}
	d.tabOwner[tab] = agent
	d.ownTabs[agent] = append(d.ownTabs[agent], tab)
}

// sessionTab is the newest tab of agent's, or "" when it has none.
func (d *Daemon) sessionTab(agent wire.UUID) target.ID {
	d.tabsMu.Lock()
	defer d.tabsMu.Unlock()
	if own := d.ownTabs[sessionKey(agent)]; len(own) > 0 {
		return own[len(own)-1]
	}
	return ""
}

// openSessionTab opens address in a new tab of agent's: the person typed it in the pane
// of a session that has no tab yet.
func (d *Daemon) openSessionTab(agent wire.UUID, address string) error {
	d.tabsMu.Lock()
	t := d.tabs
	d.tabsMu.Unlock()
	if t == nil {
		return errors.New("The browser isn't running.")
	}
	tab, err := t.Open(address)
	if err != nil {
		return err
	}
	d.tabsMu.Lock()
	d.ownTabLocked(agent, tab)
	d.tabsMu.Unlock()
	d.sessionTabChanged(sessionKey(agent))
	return nil
}

// driveBrowserAs makes agent the one that drives the browser, and says whether this is
// its first use of the browser in its turn now.
func (d *Daemon) driveBrowserAs(agent wire.UUID) (first bool) {
	agent = sessionKey(agent)
	d.tabsMu.Lock()
	defer d.tabsMu.Unlock()
	d.driver = agent
	if d.usedTurn == nil {
		d.usedTurn = map[wire.UUID]bool{}
	}
	first = !d.usedTurn[agent]
	d.usedTurn[agent] = true
	return first
}

// stopDrivingBrowser is agent's turn ended: the tabs that open now are not its.
func (d *Daemon) stopDrivingBrowser(agent wire.UUID) {
	agent = sessionKey(agent)
	d.tabsMu.Lock()
	defer d.tabsMu.Unlock()
	if d.driver == agent {
		d.driver = ""
	}
	delete(d.usedTurn, agent)
}

// markBrowserUsed is the first browser call of agent's turn (#3916): the clients open the
// session's Agent Browser pane when its browserUsedAt moves.
func (d *Daemon) markBrowserUsed(agent wire.UUID) {
	d.changeAgent(agent, false, func(a *wire.Agent) {
		at := now()
		a.BrowserUsedAt = &at
	})
}

// startOnSessionTab puts a new @playwright/mcp on agent's own tab, or on a new tab when
// it has none: it would start on the first tab Chromium has, which may be another
// session's. It does what it can and says nothing: the agent's call goes on either way.
func (d *Daemon) startOnSessionTab(ctx context.Context, agent wire.UUID, s browserSession) {
	d.tabsMu.Lock()
	following := d.tabs != nil
	d.tabsMu.Unlock()
	if !following {
		// With no record of the tabs, there are no sessions' tabs to keep apart.
		return
	}
	startOnTab(ctx, s, d.sessionTabURL(agent))
}

// startOnTab selects the tab at url in s, or opens a new one when url is "" or no tab is
// at it.
func startOnTab(ctx context.Context, s browserSession, url string) {
	tabs := func(args map[string]any) (string, bool) {
		raw := map[string]json.RawMessage{}
		for k, v := range args {
			raw[k], _ = json.Marshal(v)
		}
		res, err := s.callTool(ctx, "browser_tabs", raw)
		if err != nil || res == nil || res.IsError {
			return "", false
		}
		var text []string
		for _, c := range res.Content {
			if t, ok := c.(*mcp.TextContent); ok {
				text = append(text, t.Text)
			}
		}
		return strings.Join(text, "\n"), true
	}
	if url != "" {
		if list, ok := tabs(map[string]any{"action": "list"}); ok {
			if i := browser.PlaywrightTab(list, url); i >= 0 {
				if _, ok := tabs(map[string]any{"action": "select", "index": i}); ok {
					return
				}
			}
		}
	}
	tabs(map[string]any{"action": "new"})
}

// sessionTabURL is the address of agent's newest tab, or "" when it has none.
func (d *Daemon) sessionTabURL(agent wire.UUID) string {
	tab := d.sessionTab(agent)
	d.tabsMu.Lock()
	t := d.tabs
	d.tabsMu.Unlock()
	if tab == "" || t == nil {
		return ""
	}
	pages, err := t.Pages()
	if err != nil {
		return ""
	}
	for _, p := range pages {
		if p.ID == tab {
			return p.URL
		}
	}
	return ""
}
