package agentsd

import (
	"context"
	"fmt"
	"encoding/json"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/internal/safe"
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
// Once the control plane has said ok to the page, the page's calls to this host are
// answered here (#1970, FR-007): a frame {"h": <this host>, "m": …} goes to a channel of
// this host's own, and its answers and notifications go back to the page in the same
// frame, as the control plane would put them. Everything else still goes through the
// control plane, which then never opens a channel to this host for that page.

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
		Accept: func(ws *websocket.Conn, remote, origin string) { d.carryPage(ctx, ws, private, int(served.Load()), remote) }})
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
	toPage := func(line string) error {
		wctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		return page.Write(wctx, websocket.MessageText, []byte(line))
	}
	// Set once the control plane's ok has gone to the page: only then is the page one the
	// control plane has checked, and only then are its calls to this host answered here.
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
				if m, ok := forHost(b, host); ok {
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
	// The control plane's lines to the page.
	safe.Go("page down", func() {
		defer func() { done <- struct{}{} }()
		for {
			line, err := up.Read(ctx)
			if err != nil {
				return
			}
			if !proved.Load() {
				if m, ok := controllink.ParseMessage(line); ok && m.OK != nil {
					proved.Store(true)
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
	mu     sync.Mutex
	in     chan string
	closed bool
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
