package controlplane

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// #3869: Stop waits for a socket still in accept, so nothing it does, its log line
// included, comes after Stop returns. Its owner's log can be a test's t.Log, which must
// not be called after the test ends.
func TestStopWaitsForASocketInAccept(t *testing.T) {
	t.Parallel()
	logging, release := make(chan struct{}), make(chan struct{})
	var logged atomic.Bool
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(cfg *Config) {
		cfg.Log = func(line string) {
			if strings.HasPrefix(line, "refused a connection from ") {
				close(logging)
				<-release
				logged.Store(true)
			}
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, strings.Replace(p.url, "http", "ws", 1)+"/v1/connect", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	if _, _, err := ws.Read(ctx); err != nil {
		t.Fatal(err)
	}
	// No auth: accept refuses it, and its log line holds it in accept until released.
	if err := ws.Write(ctx, websocket.MessageText, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-logging:
	case <-ctx.Done():
		t.Fatal("the refusal was not logged")
	}
	stopped := make(chan bool, 1)
	go func() {
		p.s.Stop()
		stopped <- logged.Load()
	}()
	select {
	case <-stopped:
		t.Fatal("Stop returned while a socket's accept was still logging")
	case <-time.After(200 * time.Millisecond):
	}
	close(release)
	if !<-stopped {
		t.Fatal("Stop returned before the socket's accept ended")
	}
}
