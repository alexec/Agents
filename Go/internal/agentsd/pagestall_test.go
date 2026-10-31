package agentsd

import (
	"context"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/wire"
)

// A page on this host that stops reading (a hung renderer, a frozen tab) does not hold an
// agent change, nor agentMu while it is held (P20261021-1): its lines are queued as a
// daemon.sock client's are (#1399), and once its queue stays full it is let go.
func TestAStalledPageDoesNotHoldAnAgentChange(t *testing.T) {
	d, c := start(t, t.TempDir())
	go func() {
		for range c.out {
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	page, browser := pipedPage(t, ctx)
	defer browser.CloseNow()
	out := newPageOut(ctx, page)
	defer out.Close()
	local := &pageChannel{host: "h", toPage: out.Write}
	defer local.Close()
	clients := func() int {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.clients)
	}
	before := clients()
	local.take([]byte(`{"jsonrpc":"2.0","method":"page/opened"}`), d.Accept)
	for deadline := time.Now().Add(5 * time.Second); clients() == before; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the page's channel was not taken")
		}
	}
	a := seeded(t, d, t.TempDir(), nil)

	// The browser reads nothing: a burst of agent changes.
	const n = 50
	var burst, longest time.Duration
	for i := 0; i < n; i++ {
		start := time.Now()
		unread := i%2 == 0
		d.change(a.ID, func(a *wire.Agent) { a.IsUnread = &unread })
		took := time.Since(start)
		burst += took
		longest = max(longest, took)
	}
	t.Logf("page stall: %d changes in %s, longest %s", n, burst, longest)
	if longest > time.Second {
		t.Fatalf("an agent change waited %s on a page that reads nothing", longest)
	}

	// Still reading nothing, the page is let go: its socket is closed.
	gone := make(chan struct{})
	go func() {
		for {
			select {
			case <-gone:
				return
			default:
				Broadcast(d, wire.NotifyFolderChanged, wire.FolderSummary{Name: "x"})
			}
		}
	}()
	defer close(gone)
	rctx, rcancel := context.WithTimeout(ctx, 20*time.Second)
	defer rcancel()
	for {
		if _, _, err := browser.Read(rctx); err != nil {
			if rctx.Err() != nil {
				t.Fatal("the stalled page was not let go")
			}
			break
		}
		// One line read: the browser stalls again, so its queue fills again.
		time.Sleep(3 * sockQueueWait)
	}
}

// pipedPage is a page socket and the browser's end of it, over a pipe with no buffer, so a
// browser that reads nothing holds the page's next write at once.
func pipedPage(t *testing.T, ctx context.Context) (*websocket.Conn, *websocket.Conn) {
	t.Helper()
	server, client := net.Pipe()
	pages := make(chan *websocket.Conn, 1)
	l := &oneConn{c: server, done: make(chan struct{})}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		pages <- ws
		<-ctx.Done()
	})}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	browser, _, err := websocket.Dial(ctx, "ws://page/", &websocket.DialOptions{HTTPClient: &http.Client{Transport: &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) { return client, nil },
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return <-pages, browser
}

// oneConn is a listener that hands out one connection, then waits until it is closed.
type oneConn struct {
	c    net.Conn
	once sync.Once
	took bool
	mu   sync.Mutex
	done chan struct{}
}

func (l *oneConn) Accept() (net.Conn, error) {
	l.mu.Lock()
	if !l.took {
		l.took = true
		l.mu.Unlock()
		return l.c, nil
	}
	l.mu.Unlock()
	<-l.done
	return nil, net.ErrClosed
}

func (l *oneConn) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *oneConn) Addr() net.Addr { return l.c.LocalAddr() }
