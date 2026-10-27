package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The web page on this machine, served by this host when the control plane runs elsewhere
// (#1480, #1951, specs/1480-local-page-on-agentsd). The listener is the control plane's own
// loopback listener (the web package): 127.0.0.1 and ::1 only, the Host and Origin checks,
// the manifest and the CSP. Each page socket it lets through is carried to the control
// plane on a socket of its own: this host proves itself there as w:<host>, with its key
// and the listener's port, and from then on every line goes through as it is, both ways.
// The page's own exchange is with the control plane, which binds it to this listener's
// origin; this host never checks a browser's proof, and holds no key to.
//
// When the control plane says so, the page's calls to this host are answered here (#1970,
// FR-007): a frame {"h": <this host>, "m": …} goes to a channel of this host's own, and its
// answers and notifications go back to the page in the same frame, as the control plane
// would put them. The control plane says so only on the line right after the page's ok,
// and only for a browser of this host's own person (controllink.Carried), with who it is
// and the calls that still go through it (those the audit keeps or the policy gates). An
// ok alone says nothing: a code's is no person's, and another person's is not this host's
// owner's. Every other line goes through the control plane.

// pageTimeout is how long the control plane has to say hello and ok to a carried page.
const pageTimeout = 15 * time.Second

// StartPage serves the page in folder on port (0: the system picks one). The membership is
// read from the root for each page, as the uplink saves it, so a move or a rotated key is
// followed. Nothing is served when the folder can't be read or the port is taken; that is
// logged, and the host goes on.
func (d *Daemon) StartPage(ctx context.Context, private []byte, folder string, port int) *web.Listener {
	// The port the pages came in on, once the listener has one: what their origin names.
	var served atomic.Int64
	listener, err := web.Start(web.Config{Folder: folder, Port: port, Log: func(s string) { log.Printf("page: %s", s) },
		Accept: func(ws *websocket.Conn, remote, origin string) {
			d.carryPage(ctx, ws, private, int(served.Load()), remote)
		}})
	if err != nil {
		log.Printf("page: not served: %v", err)
		return nil
	}
	served.Store(int64(listener.Port()))
	log.Printf("page: served at %s", listener.Origin())
	safe.Go("page listener", func() {
		<-ctx.Done()
		listener.Stop()
	})
	return listener
}

// carryPage takes one page socket to the control plane and carries it until either end
// closes. When the control plane can't be reached, the page is told so with the refusal it
// already knows (unavailable), and it tries again as it does today.
func (d *Daemon) carryPage(ctx context.Context, page *websocket.Conn, private []byte, port int, remote string) {
	defer page.CloseNow()
	up, host, err := d.dialForPage(ctx, private, port)
	if err != nil {
		log.Printf("page: a page from %s was not carried: %v", remote, err)
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		page.Write(wctx, websocket.MessageText, []byte(controllink.Message{Refused: controllink.Unavailable}.Line()))
		cancel()
		page.Close(websocket.StatusNormalClosure, "")
		return
	}
	defer up.Close()
	page.SetReadLimit(64 << 20)
	out := newPageOut(ctx, page)
	defer out.Close()
	toPage := out.Write
	// Set once the control plane has said this page's calls to this host are answered here
	// (controllink.Carried), and only then. local's actor and up are set before it.
	var proved atomic.Bool
	local := &pageChannel{host: host, toPage: toPage}
	done := make(chan struct{}, 2)
	// The page's lines: to this host's channel, or to the control plane. The only one that
	// hands the channel anything, so the one that closes it.
	safe.Go("page up", func() {
		defer func() { done <- struct{}{} }()
		defer local.Close()
		for {
			kind, b, err := page.Read(ctx)
			if err != nil || kind != websocket.MessageText {
				return
			}
			if proved.Load() {
				if m, ok := forHost(b, host); ok && !local.goesUp(m) {
					if local.take(m, d.Accept) {
						continue
					}
					return
				}
			}
			if up.Write(ctx, string(b)) != nil {
				return
			}
		}
	})
	// The control plane's lines to the page; the one that says it is answered here is not.
	safe.Go("page down", func() {
		defer func() { done <- struct{}{} }()
		// Where the exchange is: the page's ok not yet seen, the line after it next, or past.
		const beforeOK, afterOK, past = 0, 1, 2
		at := beforeOK
		for {
			line, err := up.Read(ctx)
			if err != nil {
				return
			}
			switch at {
			case beforeOK:
				if m, ok := controllink.ParseMessage(line); ok && m.OK != nil {
					at = afterOK
				}
			case afterOK:
				at = past
				if c, ok := controllink.ParseCarried(line); ok {
					local.carried(c)
					proved.Store(true)
					continue
				}
			}
			if toPage(line) != nil {
				return
			}
		}
	})
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// pageOut writes the lines to one page, the control plane's and this host's channel's, in
// the order they come. It writes from a goroutine of its own, through a bounded queue, as
// a daemon.sock client is written (#1399, P20261021-1), so a page that stops reading (a
// hung renderer, a frozen tab) never holds Broadcast, its caller or agentMu: its queue
// stays full for sockQueueWait, or a write to it takes longer than pageWriteTimeout, and
// it is let go. It connects again and catches up.
type pageOut struct {
	page *websocket.Conn
	out  chan string
	done chan struct{}
	once sync.Once
}

const pageWriteTimeout = 30 * time.Second

func newPageOut(ctx context.Context, page *websocket.Conn) *pageOut {
	o := &pageOut{page: page, out: make(chan string, sockQueue), done: make(chan struct{})}
	safe.Go("page write", func() { o.writeAll(ctx) })
	return o
}

// Write queues a line; it never waits for the page.
func (o *pageOut) Write(line string) error {
	select {
	case <-o.done:
		return errSocketGone
	default:
	}
	select {
	case o.out <- line:
		return nil
	case <-o.done:
		return errSocketGone
	default:
	}
	// Full: a page behind in a burst gets a moment; one that reads nothing is let go.
	wait := time.NewTimer(sockQueueWait)
	defer wait.Stop()
	select {
	case o.out <- line:
		return nil
	case <-o.done:
		return errSocketGone
	case <-wait.C:
		log.Printf("page: a page read none of the last %d lines in %s; let go", sockQueue, sockQueueWait)
		o.Close()
		return errSocketGone
	}
}

// writeAll writes what is queued, a line at a time, until the page goes.
func (o *pageOut) writeAll(ctx context.Context) {
	for {
		select {
		case <-o.done:
			return
		case <-ctx.Done():
			o.Close()
			return
		case line := <-o.out:
			wctx, cancel := context.WithTimeout(ctx, pageWriteTimeout)
			err := o.page.Write(wctx, websocket.MessageText, []byte(line))
			cancel()
			if err != nil {
				if wctx.Err() == context.DeadlineExceeded {
					log.Printf("page: a page took over %s to take a write; let go", pageWriteTimeout)
				}
				o.Close()
				return
			}
		}
	}
}

// Close lets the page go: its socket is closed, so its reader ends too.
func (o *pageOut) Close() { o.once.Do(func() { close(o.done); o.page.CloseNow() }) }

// dialForPage opens a socket to the control plane and proves this host on it as w:<host>,
// with the page's port, at each address the membership has in turn.
func (d *Daemon) dialForPage(ctx context.Context, private []byte, port int) (*controllink.Lines, string, error) {
	member, err := controllink.LoadMembership(d.Store.Loc.Root)
	if err != nil || member == nil || member.Host == "" {
		return nil, "", fmt.Errorf("this machine has not joined a control plane")
	}
	key, err := controllink.HostKey(private, member.ControlKey, member.Host)
	if err != nil {
		return nil, "", err
	}
	page := int64(port)
	err = fmt.Errorf("no address for the control plane")
	for _, e := range member.EndpointsToDial() {
		pin := ""
		if e.Pin != nil {
			pin = *e.Pin
		}
		var l *controllink.Lines
		if l, err = carryAs(ctx, e.URL, pin, member.Host, key, member.ControlKey, page); err == nil {
			return l, member.Host, nil
		}
	}
	return nil, "", err
}

// forHost is the message of a page's frame to this host, {"h": host, "m": …}.
func forHost(line []byte, host string) (json.RawMessage, bool) {
	var frame struct {
		H *string         `json:"h"`
		M json.RawMessage `json:"m"`
	}
	if json.Unmarshal(line, &frame) != nil || frame.H == nil || *frame.H != host || len(frame.M) == 0 {
		return nil, false
	}
	return frame.M, true
}

// pageChannel is this host's channel for one carried page (controllink.Conn): opened at
// the page's first call to this host, served by Accept as a channel the control plane
// opened is, and its lines framed for the page.
type pageChannel struct {
	host   string
	toPage func(string) error
	// Who the page is, and the methods that go through the control plane all the same, as
	// the control plane said (controllink.Carried); set once, before the first take.
	actor  *wire.AuditActor
	up     map[string]bool
	mu     sync.Mutex
	in     chan string
	closed bool
}

// carried takes what the control plane said of the page.
func (c *pageChannel) carried(said controllink.Carried) {
	actor := said.Actor
	c.actor = &actor
	c.up = make(map[string]bool, len(said.Up))
	for _, method := range said.Up {
		c.up[method] = true
	}
}

// goesUp says a message goes through the control plane: a call it keeps in the audit or
// holds its checks on. An answer, with no method, is this channel's.
func (c *pageChannel) goesUp(m json.RawMessage) bool {
	var call struct {
		Method string `json:"method"`
	}
	if json.Unmarshal(m, &call) != nil {
		return true
	}
	return c.up[call.Method]
}

// take hands one message to the channel, opening it with accept the first time. False
// once the channel has closed. Called by one goroutine only, the one that calls Close.
func (c *pageChannel) take(m json.RawMessage, accept func(controllink.Conn)) bool {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return false
	}
	if c.in == nil {
		c.in = make(chan string, 256)
		safe.Go("page channel", func() { accept(c) })
	}
	in := c.in
	c.mu.Unlock()
	in <- string(m)
	return true
}

func (c *pageChannel) Write(line string) error {
	host, _ := json.Marshal(c.host)
	return c.toPage(`{"h":` + string(host) + `,"m":` + line + `}`)
}

func (c *pageChannel) In() <-chan string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.in
}

func (c *pageChannel) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed {
		c.closed = true
		if c.in != nil {
			close(c.in)
		}
	}
}

// Device is the device a channel carries: a browser is none.
func (c *pageChannel) Device() string { return "" }

// Actor is who the page is, as the control plane said (#996).
func (c *pageChannel) Actor() *wire.AuditActor { return c.actor }

// carryAs is controllink.Join for a carried page: the same exchange, as w:<host>, with the
// page's port in the auth.
func carryAs(ctx context.Context, base, pin, host string, key, controlKey []byte, page int64) (*controllink.Lines, error) {
	origin, err := controllink.Origin(base)
	if err != nil {
		return nil, err
	}
	l, err := controllink.Dial(ctx, base, pin)
	if err != nil {
		return nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, pageTimeout)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		l.Close()
		return nil, fmt.Errorf("no hello: %w", err)
	}
	m, ok := controllink.ParseMessage(line)
	if !ok || m.Hello == nil {
		l.Close()
		return nil, fmt.Errorf("expected hello, got %s", line)
	}
	auth, expect, err := controllink.Answer(m.Hello, controllink.Identity{Kind: 'w', ID: host}, key, origin, "page", controlKey, "", nil)
	if err != nil {
		l.Close()
		return nil, err
	}
	auth.Page = &page
	if err := l.Write(rctx, controllink.Message{Auth: auth}.Line()); err != nil {
		l.Close()
		return nil, err
	}
	line, err = l.Read(rctx)
	if err != nil {
		l.Close()
		return nil, fmt.Errorf("no ok: %w", err)
	}
	m, _ = controllink.ParseMessage(line)
	if m.OK == nil {
		l.Close()
		if m.Refused != "" {
			return nil, controllink.Refuse(m.Refused)
		}
		return nil, fmt.Errorf("expected ok, got %s", line)
	}
	if err := controllink.Check(m.OK, expect); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}
