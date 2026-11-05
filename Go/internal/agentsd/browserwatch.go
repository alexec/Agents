package agentsd

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// Watching the machine's browser (#3528, spike #3527): a client that shows the page says
// browser/watch, and hears browser/frame (a JPEG of the page) and browser/pageChanged until it
// says browser/unwatch or its connection ends. Every watcher shares one screencast of the
// browser's newest tab; the person's clicks, keys and the bar's buttons come back as
// browser/input and browser/navigate. Watching starts nothing: an address typed in the bar
// (browser/navigate go) does, as an agent's first browser call will.

// browserAckWait is how long a frame waits for a watcher's browser/ack before the host
// acks it itself, so one watcher that stopped drawing does not freeze the others.
const browserAckWait = 3 * time.Second

// browserWatch is who watches the machine's browser and the cast they share.
type browserWatch struct {
	mu       sync.Mutex
	watchers map[int64]*browserWatcher
	cast     *browser.Cast
	// casting is true while a cast starts, so a second one is not started beside it.
	casting bool
	// gen is the cast's generation: a callback of a cast that has ended says nothing.
	gen   int
	state wire.BrowserPageState
	// pending is the frame the watchers have and have not acked yet; 0 for none.
	pending int64
	// starting is true while browser/navigate installs or starts the browser.
	starting bool
	// last is the newest frame, for a watcher that joins on a page that does not change:
	// Chromium sends a frame only when the page does.
	last *wire.BrowserFrame
}

type browserWatcher struct {
	c             *Client
	width, height int64
}

func (d *Daemon) registerBrowserWatch() {
	On(d, wire.CallBrowserWatch, func(ctx context.Context, c *Client, r wire.BrowserWatchRequest) (wire.BrowserPageState, error) {
		return d.watchBrowser(c, r.Width, r.Height), nil
	})
	On(d, wire.CallBrowserUnwatch, func(ctx context.Context, c *Client, _ wire.Empty) (wire.Empty, error) {
		d.unwatchBrowser(c)
		return wire.Empty{}, nil
	})
	On(d, wire.CallBrowserAck, func(ctx context.Context, c *Client, r wire.BrowserAckRequest) (wire.Empty, error) {
		d.ackBrowserFrame(r.Ack)
		return wire.Empty{}, nil
	})
	On(d, wire.CallBrowserInput, func(ctx context.Context, c *Client, r wire.BrowserInputRequest) (wire.Empty, error) {
		cast, err := d.browserCast()
		if err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, cast.Input(browserInput(r))
	})
	On(d, wire.CallBrowserNavigate, func(ctx context.Context, c *Client, r wire.BrowserNavigateRequest) (wire.Empty, error) {
		return wire.Empty{}, d.navigateBrowser(r)
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
	in.X, in.Y, in.DeltaX, in.DeltaY = num(r.X), num(r.Y), num(r.DeltaX), num(r.DeltaY)
	in.ClickCount, in.KeyCode, in.Modifiers = integer(r.ClickCount), integer(r.KeyCode), integer(r.Modifiers)
	return in
}

// watchBrowser adds c as a watcher of a view of width by height, or changes its size, and
// starts the cast when the browser runs. It answers the browser's state now.
func (d *Daemon) watchBrowser(c *Client, width, height int64) wire.BrowserPageState {
	if d.browser == nil {
		return wire.BrowserPageState{Status: wire.BrowserStatusStopped}
	}
	d.browser.Touch()
	w := &d.bw
	w.mu.Lock()
	if w.watchers == nil {
		w.watchers = map[int64]*browserWatcher{}
	}
	_, again := w.watchers[c.ID]
	w.watchers[c.ID] = &browserWatcher{c: c, width: width, height: height}
	cast := w.cast
	state := d.browserStateLocked()
	last := w.last
	w.mu.Unlock()
	if last != nil && !again {
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
		go d.startBrowserCast()
	}
	return state
}

// browserStateLocked is the state a watcher sees now. Under bw.mu.
func (d *Daemon) browserStateLocked() wire.BrowserPageState {
	s := d.bw.state
	if s.Status == "" {
		s.Status = wire.BrowserStatusStopped
	}
	if d.bw.starting {
		return s
	}
	if d.browser.Running() {
		s.Status = wire.BrowserStatusRunning
	} else if s.Status == wire.BrowserStatusRunning || s.Status == wire.BrowserStatusStarting {
		s = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
	}
	return s
}

// unwatchBrowser drops c, and ends the cast when nobody watches.
func (d *Daemon) unwatchBrowser(c *Client) {
	w := &d.bw
	w.mu.Lock()
	if _, ok := w.watchers[c.ID]; !ok {
		w.mu.Unlock()
		return
	}
	delete(w.watchers, c.ID)
	var cast *browser.Cast
	if len(w.watchers) == 0 {
		cast = w.cast
		w.cast, w.pending, w.last = nil, 0, nil
		w.gen++
	}
	w.mu.Unlock()
	if cast != nil {
		go cast.Close()
	}
}

// browserCast is the cast the person's input goes to.
func (d *Daemon) browserCast() (*browser.Cast, error) {
	if d.browser != nil {
		d.browser.Touch()
	}
	d.bw.mu.Lock()
	defer d.bw.mu.Unlock()
	if d.bw.cast == nil {
		return nil, errors.New("The browser isn't running.")
	}
	return d.bw.cast, nil
}

// startBrowserCast starts the one cast that the watchers share, at the size of the
// watcher that asked last, unless one runs or starts already.
func (d *Daemon) startBrowserCast() {
	w := &d.bw
	w.mu.Lock()
	if w.cast != nil || w.casting || len(w.watchers) == 0 || d.browser == nil || !d.browser.Running() {
		w.mu.Unlock()
		return
	}
	w.casting = true
	w.gen++
	gen := w.gen
	var width, height int64
	var newest int64 = -1
	for id, v := range w.watchers {
		if id > newest {
			newest, width, height = id, v.width, v.height
		}
	}
	w.mu.Unlock()

	endpoint, err := d.browser.Endpoint(nil)
	var cast *browser.Cast
	if err == nil {
		cast, err = browser.Watch(endpoint, width, height,
			func(f browser.Frame) { d.browserFrame(gen, f) },
			func(p browser.Page) { d.browserPage(gen, p) },
			func() { d.browserCastEnded(gen) })
	}
	w.mu.Lock()
	w.casting = false
	if err != nil || w.gen != gen || len(w.watchers) == 0 {
		w.mu.Unlock()
		if err != nil {
			log.Printf("browser: couldn't watch the page: %v", err)
		}
		if cast != nil {
			cast.Close()
		}
		return
	}
	w.cast = cast
	w.mu.Unlock()
}

// browserFrame sends a frame to every watcher, and acks it itself when no watcher does
// in browserAckWait.
func (d *Daemon) browserFrame(gen int, f browser.Frame) {
	w := &d.bw
	w.mu.Lock()
	if w.gen != gen {
		w.mu.Unlock()
		return
	}
	w.pending = f.Ack
	cs := w.clientsLocked()
	w.mu.Unlock()
	n := wire.BrowserFrame{Image: wire.Data(f.JPEG), Ack: f.Ack, Width: f.Width, Height: f.Height}
	w.mu.Lock()
	if w.gen == gen {
		w.last = &n
	}
	w.mu.Unlock()
	for _, c := range cs {
		Notify(c, wire.NotifyBrowserFrame, n)
	}
	time.AfterFunc(browserAckWait, func() { d.ackBrowserFrame(f.Ack) })
}

// ackBrowserFrame asks Chromium for the next frame once a watcher drew frame n. A late
// ack, of a frame acked already, does nothing.
func (d *Daemon) ackBrowserFrame(n int64) {
	w := &d.bw
	w.mu.Lock()
	if n == 0 || w.pending != n || w.cast == nil {
		w.mu.Unlock()
		return
	}
	w.pending = 0
	cast := w.cast
	w.mu.Unlock()
	cast.Ack(n)
}

// browserPage tells the watchers the page's new address or title.
func (d *Daemon) browserPage(gen int, p browser.Page) {
	w := &d.bw
	w.mu.Lock()
	if w.gen != gen {
		w.mu.Unlock()
		return
	}
	w.state = wire.BrowserPageState{Status: wire.BrowserStatusRunning, URL: optional(p.URL), Title: optional(p.Title)}
	d.tellBrowserStateLocked()
	w.mu.Unlock()
}

// browserCastEnded is the browser gone from under the cast: it stopped or crashed.
func (d *Daemon) browserCastEnded(gen int) {
	w := &d.bw
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.gen != gen {
		return
	}
	w.cast, w.pending, w.last = nil, 0, nil
	w.gen++
	if !w.starting {
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
		d.tellBrowserStateLocked()
	}
}

// browserChanged is Chromium started or stopped, by anyone: an agent, the bar, or the
// idle stop.
func (d *Daemon) browserChanged(running bool) {
	if running {
		go d.startBrowserCast()
		return
	}
	w := &d.bw
	w.mu.Lock()
	cast := w.cast
	w.cast, w.pending, w.last = nil, 0, nil
	w.gen++
	if !w.starting {
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStopped}
		d.tellBrowserStateLocked()
	}
	w.mu.Unlock()
	if cast != nil {
		go cast.Close()
	}
}

// navigateBrowser is the bar: back, forward and reload on the page; an address also
// starts the browser when it does not run, and says each step of a first install.
func (d *Daemon) navigateBrowser(r wire.BrowserNavigateRequest) error {
	if d.browser == nil {
		return errors.New("This machine has no browser.")
	}
	address := ""
	if r.URL != nil {
		address = *r.URL
	}
	if r.Action == wire.BrowserNavigateActionGo {
		if _, err := browser.Address(address); err != nil {
			return Invalid("browser/navigate: %v", err)
		}
	}
	d.browser.Touch()
	w := &d.bw
	w.mu.Lock()
	cast := w.cast
	if cast == nil && r.Action == wire.BrowserNavigateActionGo && !w.starting {
		w.starting = true
		w.state = wire.BrowserPageState{Status: wire.BrowserStatusStarting}
		d.tellBrowserStateLocked()
		w.mu.Unlock()
		go d.startBrowserFor(address)
		return nil
	}
	w.mu.Unlock()
	if cast == nil {
		return errors.New("The browser isn't running.")
	}
	return cast.Navigate(string(r.Action), address)
}

// startBrowserFor starts the browser (installing it the first time), waits for the cast,
// and opens address in it.
func (d *Daemon) startBrowserFor(address string) {
	w := &d.bw
	say := func(s wire.BrowserPageState) {
		w.mu.Lock()
		w.state = s
		d.tellBrowserStateLocked()
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
	// Changed(true) starts the cast too; this one waits for it, or starts it.
	d.startBrowserCast()
	var cast *browser.Cast
	for i := 0; i < 100 && cast == nil; i++ {
		w.mu.Lock()
		cast = w.cast
		w.mu.Unlock()
		if cast == nil {
			time.Sleep(100 * time.Millisecond)
		}
	}
	w.mu.Lock()
	w.starting = false
	// The page the cast found is kept: only the steps of the start are done.
	w.state.Status, w.state.Detail = wire.BrowserStatusRunning, nil
	d.tellBrowserStateLocked()
	w.mu.Unlock()
	if cast == nil {
		return
	}
	if err := cast.Navigate("go", address); err != nil {
		log.Printf("browser: couldn't open %s: %v", address, err)
	}
}

// tellBrowserStateLocked sends the state to every watcher. Under bw.mu.
func (d *Daemon) tellBrowserStateLocked() {
	s := d.bw.state
	for _, c := range d.bw.clientsLocked() {
		Notify(c, wire.NotifyBrowserPageChanged, s)
	}
}

func (w *browserWatch) clientsLocked() []*Client {
	cs := make([]*Client, 0, len(w.watchers))
	for _, v := range w.watchers {
		cs = append(cs, v.c)
	}
	return cs
}
