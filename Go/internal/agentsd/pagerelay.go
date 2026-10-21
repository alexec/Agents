package agentsd

import (
	"context"
	"fmt"
	"log"
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
	up, err := d.dialForPage(ctx, private, port)
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
	done := make(chan struct{}, 2)
	// The page's lines to the control plane.
	safe.Go("page up", func() {
		defer func() { done <- struct{}{} }()
		for {
			kind, b, err := page.Read(ctx)
			if err != nil || kind != websocket.MessageText {
				return
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
			wctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			err = page.Write(wctx, websocket.MessageText, []byte(line))
			cancel()
			if err != nil {
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
func (d *Daemon) dialForPage(ctx context.Context, private []byte, port int) (*controllink.Lines, error) {
	member, err := controllink.LoadMembership(d.Store.Loc.Root)
	if err != nil || member == nil || member.Host == "" {
		return nil, fmt.Errorf("this host has not joined a control plane")
	}
	key, err := controllink.HostKey(private, member.ControlKey, member.Host)
	if err != nil {
		return nil, err
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
			return l, nil
		}
	}
	return nil, err
}

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
