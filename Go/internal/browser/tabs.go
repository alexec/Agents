package browser

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/target"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

// The machine's browser's tabs, as they open and close (#3916). agentsd follows them for
// as long as the browser runs, so it knows which session's agent opened each tab, and the
// Agent Browser pane of a session shows that session's tab, not the machine's newest.

// TabInfo is one page tab.
type TabInfo struct {
	ID         target.ID
	URL, Title string
}

// Tabs follows the page tabs of one running browser. Make it with FollowTabs; Close ends it.
type Tabs struct {
	root   context.Context
	cancel context.CancelFunc

	mu    sync.Mutex
	known map[target.ID]bool
	// emulated is each tab with a device profile (device.go, #4086), and hints the
	// browser's own user agent, as a page read it.
	emulated map[target.ID]*emulated
	hints    uaHints
}

// FollowTabs connects to the browser at endpoint. created hears each new page tab, with
// the tab that opened it ("" for none); destroyed each tab that closed; ended once, when
// the browser goes away (not after Close). The tabs open now are not new.
func FollowTabs(endpoint string, created func(tab, opener target.ID), destroyed func(target.ID), ended func()) (*Tabs, error) {
	alloc, cancelAlloc := remote.NewAllocator(context.Background(), endpoint, remote.NoModifyURL)
	root, cancelRoot := chromedp.NewContext(alloc)
	t := &Tabs{root: root, cancel: func() { cancelRoot(); cancelAlloc() }, known: map[target.ID]bool{}}
	// As for a cast, the first call is root's own, with no time limit.
	if _, err := chromedp.CallBrowser(root, target.SetDiscoverTargets, target.SetDiscoverTargetsParams{Discover: true}); err != nil {
		t.cancel()
		return nil, err
	}
	setup, cancel := context.WithTimeout(root, 15*time.Second)
	defer cancel()
	res, err := chromedp.CallBrowser(setup, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		t.cancel()
		return nil, err
	}
	for _, i := range res.TargetInfos {
		if i != nil {
			t.known[i.TargetID] = true
		}
	}
	var once sync.Once
	end := func() {
		once.Do(func() {
			if root.Err() == nil && ended != nil {
				ended()
			}
			t.cancel()
		})
	}
	go func() {
		defer end()
		for ev, err := range chromedp.BrowserEvents(root, target.TargetCreated) {
			if err != nil {
				return
			}
			i := ev.TargetInfo
			if i == nil || !t.fresh(i.TargetID) || !isPage(i) {
				continue
			}
			created(i.TargetID, i.OpenerID)
		}
	}()
	go func() {
		defer end()
		for ev, err := range chromedp.BrowserEvents(root, target.TargetDestroyed) {
			if err != nil {
				return
			}
			t.forget(ev.TargetID, nil)
			destroyed(ev.TargetID)
		}
	}()
	return t, nil
}

// fresh is whether tab is new: discovery says targetCreated again for the tabs open already.
func (t *Tabs) fresh(tab target.ID) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.known[tab] {
		return false
	}
	t.known[tab] = true
	return true
}

func isPage(i *target.Info) bool {
	return i.Type == "page" && !strings.HasPrefix(i.URL, "devtools://")
}

// Pages is every page tab open now, the newest first, as Chromium lists them.
func (t *Tabs) Pages() ([]TabInfo, error) {
	ctx, cancel := context.WithTimeout(t.root, 10*time.Second)
	defer cancel()
	res, err := chromedp.CallBrowser(ctx, target.GetTargets, target.GetTargetsParams{})
	if err != nil {
		return nil, err
	}
	var out []TabInfo
	for _, i := range res.TargetInfos {
		if i != nil && isPage(i) {
			out = append(out, TabInfo{ID: i.TargetID, URL: i.URL, Title: i.Title})
		}
	}
	return out, nil
}

// Open makes a new tab at address, which is not told to created: its caller knows it.
func (t *Tabs) Open(address string) (target.ID, error) {
	ctx, cancel := context.WithTimeout(t.root, 15*time.Second)
	defer cancel()
	made, err := chromedp.CallBrowser(ctx, target.CreateTarget, target.CreateTargetParams{URL: address})
	if err != nil {
		return "", err
	}
	t.fresh(made.TargetID)
	return made.TargetID, nil
}

// Close stops following the tabs, and leaves them open, with no device profile.
func (t *Tabs) Close() { t.cancel() }

// tabLine is one line of @playwright/mcp's browser_tabs list: "- 0: (current) [title](url)".
var tabLine = regexp.MustCompile(`^- (\d+):(?: \(current\))? \[.*\]\((.*)\)(?: \[crashed\])?$`)

// PlaywrightTab is the index, in @playwright/mcp's browser_tabs list text, of the tab at
// url: the last one when several are, as a newer tab is further down. -1 for none.
func PlaywrightTab(list, url string) int {
	found := -1
	for _, line := range strings.Split(list, "\n") {
		m := tabLine.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil || m[2] != url {
			continue
		}
		if n, err := strconv.Atoi(m[1]); err == nil {
			found = n
		}
	}
	return found
}
