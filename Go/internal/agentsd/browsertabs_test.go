package agentsd

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// Each session's own tab in the machine's browser (#3916): a tab that opens while an agent
// drives is its; its pane shows that tab, or says it has none; the first browser call of a
// turn moves browserUsedAt; and every pane hears who holds the browser.

func TestATabIsTheSessionsThatOpenedIt(t *testing.T) {
	d, _ := start(t, t.TempDir())
	a, b := wire.UUID("A"), wire.UUID("B")

	d.browserTabCreated("nobody", "")
	if d.sessionTab(a) != "" || d.tabOwner["nobody"] != "" {
		t.Fatal("a tab that opened with nobody driving has an owner")
	}
	if !d.driveBrowserAs(a) || d.driveBrowserAs(a) {
		t.Fatal("only the first call of a turn is its first")
	}
	d.browserTabCreated("a1", "")
	d.browserTabCreated("a2", "")
	if d.sessionTab(a) != "a2" {
		t.Fatal(d.sessionTab(a))
	}
	// The next agent drives: its tabs are its own, and a tab that one of a's opens is a's.
	d.stopDrivingBrowser(a)
	if !d.driveBrowserAs(b) {
		t.Fatal("b's first call is not its first")
	}
	d.browserTabCreated("b1", "")
	d.browserTabCreated("a3", "a1")
	if d.sessionTab(b) != "b1" || d.sessionTab(a) != "a3" {
		t.Fatal(d.sessionTab(b), d.sessionTab(a))
	}
	// A closed tab goes; the session's newest before it is its tab again.
	d.browserTabClosed("a3")
	if d.sessionTab(a) != "a2" {
		t.Fatal(d.sessionTab(a))
	}
	// A tab the person opens from a's pane moves to a, away from b.
	d.tabsMu.Lock()
	d.ownTabLocked(a, "b1")
	d.tabsMu.Unlock()
	if d.sessionTab(b) != "" || d.sessionTab(a) != "b1" {
		t.Fatal(d.sessionTab(b), d.sessionTab(a))
	}
	// The browser stopped: its tabs and their owners are gone.
	d.stopFollowingBrowserTabs()
	if d.sessionTab(a) != "" {
		t.Fatal("a tab outlived the browser")
	}
	// A new turn of a's is a first call again.
	d.stopDrivingBrowser(a)
	if !d.driveBrowserAs(a) {
		t.Fatal("a's next turn is not a first call")
	}
}

func TestFramesGoOnlyToTheSessionsWatchers(t *testing.T) {
	d, watchA := start(t, t.TempDir())
	watchB := newConn()
	go d.Accept(watchB)
	defer close(watchB.in)
	a, b := wire.UUID("A"), wire.UUID("B")
	watchA.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600, Agent: &a})
	watchB.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600, Agent: &b})
	d.browserFrame(screenGen(d, a), browserFrameOf("a's page", 1))
	if f := nextBrowserFrame(watchA, 2*time.Second); f == nil || string(f.Image) != "a's page" {
		t.Fatalf("%+v", f)
	}
	if f := nextBrowserFrame(watchB, 200*time.Millisecond); f != nil {
		t.Fatal("b's pane heard a's page")
	}
	// A new tab of a's starts its screen again: a frame of the old cast says nothing.
	old := screenGen(d, a)
	d.driveBrowserAs(a)
	d.browserTabCreated("a1", "")
	if screenGen(d, a) == old {
		t.Fatal("a's screen did not move to its new tab")
	}
	d.browserFrame(old, browserFrameOf("stale", 2))
	if f := nextBrowserFrame(watchA, 200*time.Millisecond); f != nil {
		t.Fatalf("a stale frame: %+v", f)
	}
	// A watcher that moves to another session leaves its old screen when nobody else watches.
	watchB.call(t, 2, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600, Agent: &a})
	d.bw.mu.Lock()
	_, kept := d.bw.screens[b]
	d.bw.mu.Unlock()
	if kept {
		t.Fatal("b's screen outlived its last watcher")
	}
}

func TestAPaneSaysWhichSessionHoldsTheBrowser(t *testing.T) {
	fakeBrowser(t)
	d, watcher := start(t, t.TempDir())
	defer d.Shutdown()
	title := "Sign up"
	holder := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Title = &title })
	other := wire.UUID("other")
	watcher.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600, Agent: &other})
	m := appClient(t, d, holder.ID)
	m.post("initialize", map[string]any{}, 1)
	before := time.Now()
	m.browserTool(2, "browser_navigate", map[string]any{"url": "https://example.com"})
	// The pane hears the holder by browser/pageChanged.
	deadline := time.After(5 * time.Second)
	for heard := false; !heard; {
		select {
		case line := <-watcher.out:
			var msg message
			json.Unmarshal([]byte(line), &msg)
			if msg.Method != wire.NotifyBrowserPageChanged.Name {
				continue
			}
			var s wire.BrowserPageState
			json.Unmarshal(msg.Params, &s)
			heard = s.Holder != nil && *s.Holder == holder.ID && s.HolderTitle != nil && *s.HolderTitle == title
		case <-deadline:
			t.Fatal("the pane did not hear who holds the browser")
		}
	}
	// The first call of the turn moved browserUsedAt; the next does not.
	used := d.Store.Agent(holder.ID).BrowserUsedAt
	if used == nil || used.Time().Before(before.Add(-time.Second)) {
		t.Fatalf("%v", used)
	}
	m.browserTool(3, "browser_snapshot", nil)
	if again := d.Store.Agent(holder.ID).BrowserUsedAt; again == nil || *again != *used {
		t.Fatalf("a second call moved it: %v %v", used, again)
	}
}

func TestPlaywrightStartsOnTheSessionsTab(t *testing.T) {
	list := "### Result\n- 0: [Other](https://other.example/)\n- 1: (current) [Mine](https://mine.example/)\n- 2: [Mine (again)](https://mine.example/)"
	p := &tabsPlaywright{list: list}
	startOnTab(context.Background(), p, "https://mine.example/")
	if got := p.asked(); len(got) != 2 || got[0] != "list" || got[1] != "select 2" {
		t.Fatal(got)
	}
	// None at its address, or no tab of its own: a new one.
	p = &tabsPlaywright{list: list}
	startOnTab(context.Background(), p, "https://gone.example/")
	if got := p.asked(); len(got) != 2 || got[1] != "new" {
		t.Fatal(got)
	}
	p = &tabsPlaywright{list: list}
	startOnTab(context.Background(), p, "")
	if got := p.asked(); len(got) != 1 || got[0] != "new" {
		t.Fatal(got)
	}
}

// tabsPlaywright answers browser_tabs with list, and says each action it was asked.
type tabsPlaywright struct {
	list  string
	mu    sync.Mutex
	calls []string
}

func (p *tabsPlaywright) callTool(_ context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var action string
	json.Unmarshal(args["action"], &action)
	if i, ok := args["index"]; ok {
		action += " " + string(i)
	}
	p.calls = append(p.calls, action)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: p.list}}}, nil
}

func (p *tabsPlaywright) close() {}

func (p *tabsPlaywright) asked() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.calls...)
}

func browserFrameOf(jpeg string, ack int64) browser.Frame {
	return browser.Frame{JPEG: []byte(jpeg), Ack: ack, Width: 800, Height: 600}
}
