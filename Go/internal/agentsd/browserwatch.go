package agentsd

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/chromedp/cdproto/target"

	"github.com/agentloops-dev/agents/Go/internal/browser"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Watching the machine's browser (#3528, spike #3527): a client that shows the page says
// browser/watch, and hears browser/frame (a JPEG of the page) and browser/pageChanged until it
// says browser/unwatch or its connection ends. A watch names its session (#3916): the
// watchers of one session share one screencast of that session's newest tab (browsertabs.go),
// and a session whose agent opened no tab shows none. A watch that names no session sees the
// machine's newest tab. The person's clicks, keys and the bar's buttons come back as
// browser/input and browser/navigate, to the watcher's own tab. Every watcher hears which
// session holds browser:agents. Watching starts nothing: an address typed in the bar
// (browser/navigate go) does, as an agent's first browser call will.

// browserAckWait is how long a frame waits for a watcher's browser/ack before the host
// acks it itself, so one watcher that stopped drawing does not freeze the others.
const browserAckWait = 3 * time.Second

// browserTilePace is how soon the host acks a frame that only live tiles got (#4139): no
// window watches the tab, so nobody else acks it, and a tile needs no more than this.
const browserTilePace = 250 * time.Millisecond

// browserWatch is who watches the machine's browser and the casts they share.
type browserWatch struct {
	mu       sync.Mutex
	watchers map[int64]*browserWatcher
	// screens is each watched session's cast, by session; "" is the machine's newest tab.
	screens map[wire.UUID]*browserScreen
	// gens counts the screens' generations: a callback of a cast that has ended says nothing.
	gens int
	// state is the machine's browser: stopped, starting (with its step) or failed.
	state wire.BrowserPageState
	// starting is true while browser/navigate installs or starts the browser.
	starting bool
	// holder is the session that holds browser:agents, or "".
	holder wire.UUID
}

// browserScreen is the cast that the watchers of one session share.
type browserScreen struct {
	cast *browser.Cast
	// casting is true while a cast starts, so a second one is not started beside it.
	casting bool
	gen     int
	// tab is the tab the cast shows; "" for the machine's newest.
	tab target.ID
	// url and title are the page's.
	url, title string
	// pending is the frame the watchers have and have not acked yet; 0 for none.
	pending int64
	// last is the newest frame, for a watcher that joins on a page that does not change:
	// Chromium sends a frame only when the page does.
	last *wire.BrowserFrame
	// driver is the agent that drives the tab (a browser_* call in the last
	// liveDriveWindow, #4139), as its own clients name it; "" for none. A driven screen is
	// cast for the live tile also when no window watches it.
	driver wire.UUID
}

type browserWatcher struct {
	c             *Client
	width, height int64
	agent         wire.UUID
}

func (d *Daemon) registerBrowserWatch() {
	On(d, wire.CallBrowserWatch, func(ctx context.Context, c *Client, r wire.BrowserWatchRequest) (wire.BrowserPageState, error) {
		var agent wire.UUID
		if r.Agent != nil {
			agent = sessionKey(*r.Agent)
		}
		return d.watchBrowser(c, agent, r.Width, r.Height), nil
	})
	On(d, wire.CallBrowserUnwatch, func(ctx context.Context, c *Client, _ wire.Empty) (wire.Empty, error) {
		d.unwatchBrowser(c)
		return wire.Empty{}, nil
	})
	On(d, wire.CallBrowserAck, func(ctx context.Context, c *Client, r wire.BrowserAckRequest) (wire.Empty, error) {
		d.ackBrowserFrame(d.watchedSession(c), r.Ack)
		return wire.Empty{}, nil
	})
	On(d, wire.CallBrowserInput, func(ctx context.Context, c *Client, r wire.BrowserInputRequest) (wire.BrowserInputResult, error) {
		cast, err := d.browserCast(c)
		if err != nil {
			return wire.BrowserInputResult{}, err
		}
		said, err := cast.Input(browserInput(r))
		return wire.BrowserInputResult{Editing: said.Editing, Copied: said.Copied}, err
	})
	On(d, wire.CallBrowserNavigate, func(ctx context.Context, c *Client, r wire.BrowserNavigateRequest) (wire.Empty, error) {
		return wire.Empty{}, d.navigateBrowser(c, r)
	})
}

// browserInput is the wire's input as the browser package takes it.
func browserInput(r wire.BrowserInputRequest) browser.Input {
	in := browser.Input{Kind: string(r.Kind)}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	num := func(p *float64) float64 {
		if p == nil {
			return 0
		}
		return *p
	}
	integer := func(p *int64) int64 {
		if p == nil {
			return 0
		}
		return *p
	}
	in.Type, in.Button, in.Key, in.Code, in.Text = str(r.Type), str(r.Button), str(r.Key), str(r.Code), str(r.Text)
	if r.Command != nil {
		in.Command = string(*r.Command)
	}
	in.X, in.Y, in.DeltaX, in.DeltaY = num(r.X), num(r.Y), num(r.DeltaX), num(r.DeltaY)
	in.ClickCount, in.KeyCode, in.Modifiers = integer(r.ClickCount), integer(r.KeyCode), integer(r.Modifiers)
	return in
}

// watchBrowser adds c as a watcher of agent's tab ("" for the machine's newest) in a view
// of width by height, or changes its size or session, and starts the cast when the browser
// runs. It answers the state c sees now.
func (d *Daemon) watchBrowser(c *Client, agent wire.UUID, width, height int64) wire.BrowserPageState {
	if d.browser == nil {
		return wire.BrowserPageState{Status: wire.BrowserStatusStopped}
	}
	d.browser.Touch()
	w := &d.bw
	w.mu.Lock()
	if w.watchers == nil {
		w.watchers = map[int64]*browserWatcher{}
	}
	before, again := w.watchers[c.ID]
	moved := again && before.agent != agent
	w.watchers[c.ID] = &browserWatcher{c: c, width: width, height: height, agent: agent}
	var dropped *browser.Cast
	if moved {
		dropped = w.dropScreenIfUnwatchedLocked(before.agent)
	}
	sc := w.screenLocked(agent)
	cast := sc.cast
	state := d.browserStateLocked(agent)
	last := sc.last
	w.mu.Unlock()
	if dropped != nil {
		go dropped.Close()
	}
	if !again {
		go d.tellBrowserHolder()
	}
	if last != nil && (!again || moved) {
		// Its ack is answered by the next frame's; this one asks Chromium for nothing.
		go Notify(c, wire.NotifyBrowserFrame, *last)
	}
	if cast != nil {
		go func() {
			if err := cast.Resize(width, height); err != nil {
				log.Printf("browser: couldn't resize the screencast: %v", err)
			}
		}()
	} else if state.Status == wire.BrowserStatusRunning {
		go d.startBrowserCast(agent)
	}
	return state
}

// screenLocked is agent's screen, made when it has none. Under bw.mu.
func (w *browserWatch) screenLocked(agent wire.UUID) *browserScreen {
	if w.screens == nil {
		w.screens = map[wire.UUID]*browserScreen{}
	}
	sc := w.screens[agent]
	if sc == nil {
		w.gens++
		sc = &browserScreen{gen: w.gens}
		w.screens[agent] = sc
	}
	return sc
}

// screenOfGenLocked is the screen of cast generation gen, and its session. Under bw.mu.
func (w *browserWatch) screenOfGenLocked(gen int) (*browserScreen, wire.UUID) {
	for agent, sc := range w.screens {
		if sc.gen == gen {
			return sc, agent
		}
	}
	return nil, ""
}

// resetLocked ends sc's cast and returns it to close: the screen starts again with no page.
func (w *browserWatch) resetLocked(sc *browserScreen) *browser.Cast {
	cast := sc.cast
	w.gens++
	*sc = browserScreen{gen: w.gens, driver: sc.driver}
	return cast
}

// dropScreenIfUnwatchedLocked drops agent's screen when nobody watches it and no agent
// drives it, and returns its cast to close. Under bw.mu.
func (w *browserWatch) dropScreenIfUnwatchedLocked(agent wire.UUID) *browser.Cast {
	for _, v := range w.watchers {
		if v.agent == agent {
			return nil
		}
	}
	sc := w.screens[agent]
	if sc == nil || sc.driver != "" {
		return nil
	}
	delete(w.screens, agent)
	return sc.cast
}

// browserStateLocked is the state a watcher of agent's tab sees now. Under bw.mu.
func (d *Daemon) browserStateLocked(agent wire.UUID) wire.BrowserPageState {
	w := &d.bw
	s := w.state
	if s.Status == "" {
		s.Status = wire.BrowserStatusStopped
	}
	if !w.starting {
		if d.browser.Running() {
			s = wire.BrowserPageState{Status: wire.BrowserStatusRunning}
		} else if s.Status == wire.BrowserStatusRunning || s.Status == wire.BrowserStatusStarting {
			s = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
		}
	}
	if s.Status == wire.BrowserStatusRunning {
		if sc := w.screens[agent]; sc != nil {
			s.URL, s.Title = optional(sc.url), optional(sc.title)
		}
		if agent != "" && d.sessionTab(agent) == "" {
			yes := true
			s.NoTab, s.URL, s.Title = &yes, nil, nil
		}
	}
	if h := w.holder; h != "" {
		s.Holder = &h
		if a := d.Store.Agent(h); a != nil {
			s.HolderTitle = optional(agentTitle(a))
		}
	}
	return s
}

// unwatchBrowser drops c, and ends its session's cast when nobody else watches it.
func (d *Daemon) unwatchBrowser(c *Client) {
	w := &d.bw
	w.mu.Lock()
	v, ok := w.watchers[c.ID]
	if !ok {
		w.mu.Unlock()
		return
	}
	delete(w.watchers, c.ID)
	cast := w.dropScreenIfUnwatchedLocked(v.agent)
	w.mu.Unlock()
	if cast != nil {
		go cast.Close()
	}
}

// watchedSession is the session c watches, or "".
func (d *Daemon) watchedSession(c *Client) wire.UUID {
	d.bw.mu.Lock()
	defer d.bw.mu.Unlock()
	if v := d.bw.watchers[c.ID]; v != nil {
		return v.agent
	}
	return ""
}

// browserCast is the cast c's input goes to: its session's.
func (d *Daemon) browserCast(c *Client) (*browser.Cast, error) {
	if d.browser != nil {
		d.browser.Touch()
	}
	agent := d.watchedSession(c)
	d.bw.mu.Lock()
	defer d.bw.mu.Unlock()
	if sc := d.bw.screens[agent]; sc != nil && sc.cast != nil {
		return sc.cast, nil
	}
	return nil, errors.New("The browser isn't running.")
}

// startBrowserCast starts the cast that the watchers of agent's tab share, at the size of
// the one that asked last, or for a driven tab that no window watches, at the size the page
// has (#4139), unless one runs or starts already, or the session has no tab.
func (d *Daemon) startBrowserCast(agent wire.UUID) {
	w := &d.bw
	w.mu.Lock()
	sc := w.screens[agent]
	if sc == nil || sc.cast != nil || sc.casting || d.browser == nil || !d.browser.Running() {
		w.mu.Unlock()
		return
	}
	var width, height int64
	var newest int64 = -1
	for id, v := range w.watchers {
		if v.agent == agent && id > newest {
			newest, width, height = id, v.width, v.height
		}
	}
	if newest < 0 && sc.driver == "" {
		w.mu.Unlock()
		return
	}
	var tab target.ID
	if agent != "" {
		if tab = d.sessionTab(agent); tab == "" {
			w.mu.Unlock()
			return
		}
	}
	sc.casting, sc.tab = true, tab
	gen := sc.gen
	w.mu.Unlock()

	endpoint, err := d.browser.Endpoint(nil)
	var cast *browser.Cast
	if err == nil {
		if agent != "" {
			d.followBrowserTabs(endpoint)
		}
		cast, err = browser.Watch(endpoint, tab, width, height, d.sessionDevice(agent),
			func(f browser.Frame) { d.browserFrame(gen, f) },
			func(p browser.Page) { d.browserPage(gen, p) },
			func() { d.browserCastEnded(gen) })
	}
	w.mu.Lock()
	if sc.gen == gen {
		sc.casting = false
	}
	if err != nil || sc.gen != gen || w.screens[agent] != sc {
		w.mu.Unlock()
		if err != nil {
			log.Printf("browser: couldn't watch the page: %v", err)
		}
		if cast != nil {
			cast.Close()
		}
		return
	}
	sc.cast = cast
	w.mu.Unlock()
}

// sessionTabChanged is agent's newest tab opened or closed: its watchers move to the tab
// it has now, or see that it has none.
func (d *Daemon) sessionTabChanged(agent wire.UUID) {
	agent = sessionKey(agent)
	w := &d.bw
	w.mu.Lock()
	sc := w.screens[agent]
	if sc == nil || sc.tab == d.sessionTab(agent) && (sc.cast != nil || sc.casting) {
		w.mu.Unlock()
		return
	}
	old := w.resetLocked(sc)
	d.tellBrowserStateLocked(agent)
	w.mu.Unlock()
	if old != nil {
		go old.Close()
	}
	d.startBrowserCast(agent)
}

// browserFrame sends a frame to every watcher of its screen, and acks it itself when no
// watcher does in browserAckWait.
func (d *Daemon) browserFrame(gen int, f browser.Frame) {
	w := &d.bw
	w.mu.Lock()
	sc, agent := w.screenOfGenLocked(gen)
	if sc == nil {
		w.mu.Unlock()
		return
	}
	n := wire.BrowserFrame{Image: wire.Data(f.JPEG), Ack: f.Ack, Width: f.Width, Height: f.Height}
	sc.pending, sc.last = f.Ack, &n
	cs := w.clientsLocked(agent)
	driver, title := sc.driver, sc.title
	w.mu.Unlock()
	for _, c := range cs {
		Notify(c, wire.NotifyBrowserFrame, n)
	}
	wait := browserAckWait
	if driver != "" {
		width, height := int64(f.Width), int64(f.Height)
		tiled := d.sendLive(wire.LiveFrame{Source: wire.LiveSourceBrowser, AgentID: driver, Image: liveImage(f.JPEG),
			Width: &width, Height: &height, Title: optional(title)})
		if tiled && len(cs) == 0 {
			// Only tiles have it, and they do not ack.
			wait = browserTilePace
		}
	}
	time.AfterFunc(wait, func() { d.ackBrowserFrame(agent, f.Ack) })
}

// browserDrove is a browser_* call of agent's (#4139): its session's tab is cast for the
// live tile from now until liveDriveWindow after its last call, also when no window
// watches it. The cast starts when the session has a tab and the browser runs.
func (d *Daemon) browserDrove(agent wire.UUID) {
	if d.browser == nil {
		return
	}
	key := sessionKey(agent)
	d.drove(agent, wire.LiveSourceBrowser, func() { d.browserDriveEnded(key) })
	w := &d.bw
	w.mu.Lock()
	w.screenLocked(key).driver = agent
	w.mu.Unlock()
	safe.Go("browser tile", func() { d.startBrowserCast(key) })
}

// browserDriveEnded is liveDriveWindow since agent's last browser call: its tab's cast ends
// unless a window watches it.
func (d *Daemon) browserDriveEnded(agent wire.UUID) {
	w := &d.bw
	w.mu.Lock()
	sc := w.screens[agent]
	if sc == nil || sc.driver == "" || d.isDriving(sc.driver, wire.LiveSourceBrowser) {
		w.mu.Unlock()
		return
	}
	sc.driver = ""
	cast := w.dropScreenIfUnwatchedLocked(agent)
	w.mu.Unlock()
	if cast != nil {
		go cast.Close()
	}
}

// ackBrowserFrame asks Chromium for the next frame of agent's screen once a watcher drew
// frame n. A late ack, of a frame acked already, does nothing.
func (d *Daemon) ackBrowserFrame(agent wire.UUID, n int64) {
	w := &d.bw
	w.mu.Lock()
	sc := w.screens[agent]
	if n == 0 || sc == nil || sc.pending != n || sc.cast == nil {
		w.mu.Unlock()
		return
	}
	sc.pending = 0
	cast := sc.cast
	w.mu.Unlock()
	cast.Ack(n)
}

// browserPage tells a screen's watchers the page's new address or title.
func (d *Daemon) browserPage(gen int, p browser.Page) {
	w := &d.bw
	w.mu.Lock()
	defer w.mu.Unlock()
	sc, agent := w.screenOfGenLocked(gen)
	if sc == nil {
		return
	}
	sc.url, sc.title = p.URL, p.Title
	d.tellBrowserStateLocked(agent)
}

// browserCastEnded is the browser gone from under a cast: it stopped or crashed.
func (d *Daemon) browserCastEnded(gen int) {
	w := &d.bw
	w.mu.Lock()
	defer w.mu.Unlock()
	sc, _ := w.screenOfGenLocked(gen)
	if sc == nil {
		return
	}
	w.resetLocked(sc)
	if !w.starting {
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
		d.tellEveryBrowserWatcherLocked()
	}
}

// browserChanged is Chromium started or stopped, by anyone: an agent, the bar, or the
// idle stop. endpoint is the address of the one that did.
func (d *Daemon) browserChanged(running bool, endpoint string) {
	w := &d.bw
	if running {
		if now, err := d.browser.Endpoint(nil); err == nil {
			d.followBrowserTabs(now)
		}
		w.mu.Lock()
		var agents []wire.UUID
		for agent := range w.screens {
			agents = append(agents, agent)
		}
		w.mu.Unlock()
		for _, agent := range agents {
			go d.startBrowserCast(agent)
		}
		return
	}
	d.stopFollowingBrowserTabsOf(endpoint)
	w.mu.Lock()
	var casts []*browser.Cast
	for _, sc := range w.screens {
		if cast := w.resetLocked(sc); cast != nil {
			casts = append(casts, cast)
		}
	}
	if !w.starting {
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
		d.tellEveryBrowserWatcherLocked()
	}
	w.mu.Unlock()
	for _, cast := range casts {
		go cast.Close()
	}
}

// tellBrowserHolder is browser:agents changed hands, maybe: every watcher hears who holds
// it now.
func (d *Daemon) tellBrowserHolder() {
	d.leaseMu.Lock()
	d.loadLeases()
	var holder wire.UUID
	if e := d.book.Entries[wire.ResourceName(browser.Resource)]; e != nil && len(e.Leases) > 0 {
		holder = e.Leases[0].Holder
	}
	d.leaseMu.Unlock()
	w := &d.bw
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.holder == holder {
		return
	}
	w.holder = holder
	d.tellEveryBrowserWatcherLocked()
}

// navigateBrowser is the bar: back, forward and reload on the page; an address also
// starts the browser when it does not run, and says each step of a first install.
func (d *Daemon) navigateBrowser(c *Client, r wire.BrowserNavigateRequest) error {
	if d.browser == nil {
		return errors.New("This machine has no browser.")
	}
	address := ""
	if r.URL != nil {
		address = *r.URL
	}
	if r.Action == wire.BrowserNavigateActionGo {
		u, err := browser.Address(address)
		if err != nil {
			return Invalid("browser/navigate: %v", err)
		}
		// A new tab opens at a URL, not at what was typed.
		address = u
	}
	d.browser.Touch()
	agent := d.watchedSession(c)
	w := &d.bw
	w.mu.Lock()
	var cast *browser.Cast
	if sc := w.screens[agent]; sc != nil {
		cast = sc.cast
	}
	if cast == nil && r.Action == wire.BrowserNavigateActionGo && agent != "" && d.browser.Running() && d.sessionTab(agent) == "" {
		// A session with no tab yet: the address opens one of its own.
		w.mu.Unlock()
		return d.openSessionTab(agent, address)
	}
	if cast == nil && r.Action == wire.BrowserNavigateActionGo && !w.starting {
		w.starting = true
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStarting}
		d.tellEveryBrowserWatcherLocked()
		w.mu.Unlock()
		go d.startBrowserFor(agent, address)
		return nil
	}
	w.mu.Unlock()
	if cast == nil {
		return errors.New("The browser isn't running.")
	}
	return cast.Navigate(string(r.Action), address)
}

// startBrowserFor starts the browser (installing it the first time), and opens address in
// a new tab of agent's, or, for a watch of no session, waits for the cast and opens address
// in its tab.
func (d *Daemon) startBrowserFor(agent wire.UUID, address string) {
	w := &d.bw
	say := func(s wire.BrowserPageState) {
		w.mu.Lock()
		w.state = s
		d.tellEveryBrowserWatcherLocked()
		w.mu.Unlock()
	}
	_, err := d.browser.Endpoint(func(step string) {
		say(wire.BrowserPageState{Status: wire.BrowserStatusStarting, Detail: optional(step)})
	})
	if err != nil {
		w.mu.Lock()
		w.starting = false
		w.mu.Unlock()
		say(wire.BrowserPageState{Status: wire.BrowserStatusFailed, Detail: optional(err.Error())})
		return
	}
	done := func() {
		w.mu.Lock()
		w.starting = false
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusRunning}
		d.tellEveryBrowserWatcherLocked()
		w.mu.Unlock()
	}
	if agent != "" {
		endpoint, err := d.browser.Endpoint(nil)
		if err == nil {
			d.followBrowserTabs(endpoint)
			done()
			if tab := d.sessionTab(agent); tab != "" {
				// The session got a tab while the browser started: the address goes there.
				d.startBrowserCast(agent)
			} else {
				err = d.openSessionTab(agent, address)
			}
		}
		if err != nil {
			log.Printf("browser: couldn't open %s: %v", address, err)
		}
		return
	}
	// Changed(true) starts the cast too; this one waits for it, or starts it.
	d.startBrowserCast(agent)
	var cast *browser.Cast
	for i := 0; i < 100 && cast == nil; i++ {
		w.mu.Lock()
		if sc := w.screens[agent]; sc != nil {
			cast = sc.cast
		}
		w.mu.Unlock()
		if cast == nil {
			time.Sleep(100 * time.Millisecond)
		}
	}
	done()
	if cast == nil {
		return
	}
	if err := cast.Navigate("go", address); err != nil {
		log.Printf("browser: couldn't open %s: %v", address, err)
	}
}

// tellBrowserStateLocked sends the state to every watcher of agent's tab. Under bw.mu.
func (d *Daemon) tellBrowserStateLocked(agent wire.UUID) {
	s := d.browserStateLocked(agent)
	for _, c := range d.bw.clientsLocked(agent) {
		Notify(c, wire.NotifyBrowserPageChanged, s)
	}
}

// tellEveryBrowserWatcherLocked sends each watcher the state it sees. Under bw.mu.
func (d *Daemon) tellEveryBrowserWatcherLocked() {
	seen := map[wire.UUID]bool{}
	for _, v := range d.bw.watchers {
		if !seen[v.agent] {
			seen[v.agent] = true
			d.tellBrowserStateLocked(v.agent)
		}
	}
}

// clientsLocked is the clients that watch agent's tab. Under bw.mu.
func (w *browserWatch) clientsLocked(agent wire.UUID) []*Client {
	var cs []*Client
	for _, v := range w.watchers {
		if v.agent == agent {
			cs = append(cs, v.c)
		}
	}
	return cs
}
