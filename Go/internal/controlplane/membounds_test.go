package controlplane

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/coder/websocket"
)

// #3650: a presence report made at another copy goes when no copy links its client.
func TestPeerPresenceGoesWithItsLastLink(t *testing.T) {
	t.Parallel()
	r := NewRouter(nil, nil)
	const client = "A0000000-0000-4000-8000-000000000001"
	report := []byte(`{"active":true}`)
	r.NotePeerLink("peer-1", client, true)
	r.NotePeerLink("peer-2", client, true)
	r.NotePeerPresence(client, true, report)
	if len(r.FoldedPresences()) != 1 {
		t.Fatal("not folded")
	}
	r.NotePeerLink("peer-1", client, false)
	if len(r.FoldedPresences()) != 1 {
		t.Fatal("went while another copy links it")
	}
	r.DropPeer("peer-2")
	if n := len(r.FoldedPresences()); n != 0 {
		t.Fatalf("%d left after its last link", n)
	}
	r.NotePeerLink("peer-1", client, true)
	r.NotePeerPresence(client, true, report)
	r.NotePeerLink("peer-1", client, false)
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.presence) != 0 {
		t.Fatalf("%d held", len(r.presence))
	}
}

// #3650: a slow socket is closed by the bytes waiting, not only their count; a single line
// larger than the bound still goes when nothing waits before it.
func TestASocketQueueIsBoundedByBytes(t *testing.T) {
	t.Parallel()
	conns := make(chan *websocket.Conn, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		ws, err := websocket.Accept(w, req, nil)
		if err != nil {
			return
		}
		conns <- ws
		<-req.Context().Done()
	}))
	t.Cleanup(srv.Close)
	ws, _, err := websocket.Dial(context.Background(), strings.Replace(srv.URL, "http", "ws", 1), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })
	// No writer: every line sent waits.
	c := &Conn{ws: <-conns, out: make(chan string, queued), done: make(chan struct{})}
	big := strings.Repeat("x", queuedBytes+1)
	if !c.Send(big) {
		t.Fatal("a lone large line was refused")
	}
	if c.Send("y") {
		t.Fatal("a line past the bytes bound was queued")
	}
	select {
	case <-c.Done():
	default:
		t.Fatal("not closed")
	}
}
