package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// Watching the machine's browser (#3528): watching starts nothing, frames go only to the
// clients that watch, and a client that leaves stops hearing them.

// nextBrowserFrame is the next browser/frame c hears, or nil after wait.
func nextBrowserFrame(c *conn, wait time.Duration) *wire.BrowserFrame {
	deadline := time.After(wait)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifyBrowserFrame.Name {
				continue
			}
			var f wire.BrowserFrame
			json.Unmarshal(m.Params, &f)
			return &f
		case <-deadline:
			return nil
		}
	}
}

func TestWatchingTheBrowserStartsNothing(t *testing.T) {
	d, c := start(t, t.TempDir())
	var s wire.BrowserPageState
	if err := json.Unmarshal(c.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600}), &s); err != nil {
		t.Fatal(err)
	}
	if s.Status != wire.BrowserStatusStopped || d.browser.Running() {
		t.Fatalf("%+v", s)
	}
	if e := c.callErr(t, 2, "browser/input", wire.BrowserInputRequest{Kind: wire.BrowserInputKindText}); !strings.Contains(e, "isn't running") {
		t.Fatal(e)
	}
	if e := c.callErr(t, 3, "browser/navigate", wire.BrowserNavigateRequest{Action: wire.BrowserNavigateActionBack}); !strings.Contains(e, "isn't running") {
		t.Fatal(e)
	}
	if e := c.callErr(t, 4, "browser/navigate", wire.BrowserNavigateRequest{Action: wire.BrowserNavigateActionGo}); !strings.Contains(e, "no address") {
		t.Fatal(e)
	}
	if d.browser.Running() {
		t.Fatal("a failed navigate started the browser")
	}
	c.call(t, 5, "browser/unwatch", wire.Empty{})
}

func TestFramesGoOnlyToTheClientsThatWatch(t *testing.T) {
	d, watcher := start(t, t.TempDir())
	other := newConn()
	go d.Accept(other)
	gone := newConn()
	go d.Accept(gone)
	watcher.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600})
	gone.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600})
	other.call(t, 1, "daemon/ping", nil)
	close(gone.in)
	deadline := time.Now().Add(5 * time.Second)
	for {
		d.bw.mu.Lock()
		n := len(d.bw.watchers)
		d.bw.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a closed connection still watches")
		}
		time.Sleep(10 * time.Millisecond)
	}

	d.bw.mu.Lock()
	gen := d.bw.gen
	d.bw.mu.Unlock()
	d.browserFrame(gen, browser.Frame{JPEG: []byte("jpeg"), Ack: 7, Width: 800, Height: 600})
	f := nextBrowserFrame(watcher, 2*time.Second)
	if f == nil || string(f.Image) != "jpeg" || f.Ack != 7 || f.Width != 800 {
		t.Fatalf("%+v", f)
	}
	if f := nextBrowserFrame(other, 200*time.Millisecond); f != nil {
		t.Fatal("a client that does not watch heard a frame")
	}
	// A frame of a cast that has ended says nothing.
	d.browserFrame(gen-1, browser.Frame{JPEG: []byte("old"), Ack: 8})
	if f := nextBrowserFrame(watcher, 200*time.Millisecond); f != nil {
		t.Fatalf("a stale frame: %+v", f)
	}
	watcher.call(t, 2, "browser/unwatch", wire.Empty{})
	d.browserFrame(gen, browser.Frame{JPEG: []byte("after"), Ack: 9})
	if f := nextBrowserFrame(watcher, 200*time.Millisecond); f != nil {
		t.Fatal("a frame after unwatch")
	}
	close(other.in)
}

func TestTheWiresInputIsTheBrowsers(t *testing.T) {
	x, y, kind := 12.5, 40.0, "mousePressed"
	button, clicks, mods := "left", int64(2), int64(8)
	in := browserInput(wire.BrowserInputRequest{Kind: wire.BrowserInputKindMouse, Type: &kind, X: &x, Y: &y,
		Button: &button, ClickCount: &clicks, Modifiers: &mods})
	if in != (browser.Input{Kind: "mouse", Type: "mousePressed", X: 12.5, Y: 40, Button: "left", ClickCount: 2, Modifiers: 8}) {
		t.Fatalf("%+v", in)
	}
}

// A page that does not change sends no frame: one who joins sees the last one at once.
func TestAWatcherWhoJoinsSeesTheLastFrame(t *testing.T) {
	d, first := start(t, t.TempDir())
	first.call(t, 1, "browser/watch", wire.BrowserWatchRequest{Width: 800, Height: 600})
	d.bw.mu.Lock()
	gen := d.bw.gen
	d.bw.mu.Unlock()
	d.browserFrame(gen, browser.Frame{JPEG: []byte("still"), Ack: 3, Width: 800, Height: 600})
	if f := nextBrowserFrame(first, 10*time.Second); f == nil {
		t.Fatal("the first watcher saw no frame in 10 s")
	}
	late := newConn()
	go d.Accept(late)
	// The last frame goes out beside the answer, often before it, so read both here:
	// call drops a notification that comes before its answer (#3637).
	p, _ := json.Marshal(wire.BrowserWatchRequest{Width: 400, Height: 300})
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "browser/watch", "params": json.RawMessage(p)})
	late.in <- string(b)
	var f *wire.BrowserFrame
	answered := false
	deadline := time.After(10 * time.Second)
	for f == nil || !answered {
		select {
		case line := <-late.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			switch {
			case string(m.ID) == "1":
				answered = true
			case m.Method == wire.NotifyBrowserFrame.Name:
				f = &wire.BrowserFrame{}
				json.Unmarshal(m.Params, f)
			}
		case <-deadline:
			t.Fatalf("after 10 s: answered %v, frame %+v", answered, f)
		}
	}
	if string(f.Image) != "still" || f.Ack != 3 {
		t.Fatalf("the late watcher saw %+v, not the last frame", f)
	}
	close(late.in)
}
