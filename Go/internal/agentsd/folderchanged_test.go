package agentsd

import (
	"encoding/json"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// windowClock is a test's clock for folder.changed's windows: a timer fires only when the
// test moves the clock past it.
type windowClock struct {
	mu     sync.Mutex
	now    time.Duration
	timers []windowTimer
}

type windowTimer struct {
	due time.Duration
	f   func()
}

func (c *windowClock) after(d time.Duration, f func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.timers = append(c.timers, windowTimer{due: c.now + d, f: f})
}

// advance moves the clock on by d and fires the timers it passes, in order; it is how many.
func (c *windowClock) advance(d time.Duration) int {
	c.mu.Lock()
	c.now += d
	var due []windowTimer
	kept := c.timers[:0]
	for _, t := range c.timers {
		if t.due <= c.now {
			due = append(due, t)
		} else {
			kept = append(kept, t)
		}
	}
	c.timers = kept
	c.mu.Unlock()
	for _, t := range due {
		t.f()
	}
	return len(due)
}

// folderChangedFor waits for the next folder/changed of one folder, and is its summary.
func folderChangedFor(t *testing.T, c *conn, folder string) wire.FolderSummary {
	t.Helper()
	var got wire.FolderSummary
	c.until(t, "folder/changed of "+folder, func(method string, params json.RawMessage) bool {
		if method != wire.NotifyFolderChanged.Name {
			return false
		}
		var s wire.FolderSummary
		json.Unmarshal(params, &s)
		if store.FolderPath(s.Folder.Folder) != folder {
			return false
		}
		got = s
		return true
	})
	return got
}

// #4508: a turn that streams 50 changes a second sends its folder's summary at most 4
// times a second, and the last one says the last change.
func TestFolderChangedAtMostFourASecond(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	clock := &windowClock{}
	d.folderAfter = clock.after
	folder := t.TempDir()
	a := seeded(t, d, folder, nil)
	sent := 0
	for i := range 50 {
		d.change(a.ID, func(a *wire.Agent) { a.LastActivityAt = wire.Date(1_000 + i) })
		if n := clock.advance(20 * time.Millisecond); n > 0 {
			sent += n
			folderChangedFor(t, c, folder)
		}
	}
	if sent > 4 {
		t.Fatalf("%d folder/changed in a second, want at most 4", sent)
	}
	// The window the last changes opened ends, and says the newest summary.
	if n := clock.advance(folderChangedWindow); n != 1 {
		t.Fatalf("%d sends at the last window's end, want 1", n)
	}
	got := folderChangedFor(t, c, folder)
	want, _ := d.folderSummary(folder)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("last folder/changed:\n%+v\nnewest summary:\n%+v", got, want)
	}
	if n := clock.advance(time.Second); n != 0 {
		t.Fatalf("%d sends with no change", n)
	}
}

// #4508: one change goes out at the window's end, not before, and each folder has its own.
func TestFolderChangedOneChangeAtWindowEnd(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	clock := &windowClock{}
	d.folderAfter = clock.after
	one, two := t.TempDir(), t.TempDir()
	a, b := seeded(t, d, one, nil), seeded(t, d, two, nil)
	d.change(a.ID, func(a *wire.Agent) { a.Title = nil })
	d.change(b.ID, func(a *wire.Agent) { a.Title = nil })
	if n := clock.advance(folderChangedWindow - time.Millisecond); n != 0 {
		t.Fatalf("%d sends before the window's end", n)
	}
	if n := clock.advance(time.Millisecond); n != 2 {
		t.Fatalf("%d sends at the window's end, want one a folder", n)
	}
	// Sent at once, so in either order.
	seen := map[string]bool{}
	c.until(t, "folder/changed of both", func(method string, params json.RawMessage) bool {
		if method == wire.NotifyFolderChanged.Name {
			var s wire.FolderSummary
			json.Unmarshal(params, &s)
			seen[store.FolderPath(s.Folder.Folder)] = true
		}
		return seen[one] && seen[two]
	})
}

// #4666: a window that ends after Shutdown reads no summary. Reading one reads your
// policy, whose first read makes the first-start move into the root, which a test's
// TempDir cleanup was removing (BenchmarkChangeAgent).
func TestFolderChangedNotAfterShutdown(t *testing.T) {
	d, _ := start(t, t.TempDir())
	clock := &windowClock{}
	d.folderAfter = clock.after
	folder := t.TempDir()
	a := seeded(t, d, folder, nil)
	d.change(a.ID, func(a *wire.Agent) { a.Title = nil })
	d.Shutdown()
	if n := clock.advance(folderChangedWindow); n != 1 {
		t.Fatalf("%d windows ended, want 1", n)
	}
	// A send that ran would have closed the folder's window.
	time.Sleep(100 * time.Millisecond)
	d.folderChangedMu.Lock()
	open := d.folderDirty[folder]
	d.folderChangedMu.Unlock()
	if !open {
		t.Fatal("the folder's summary was read after Shutdown")
	}
}
