package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A count at the end of a server's list view row (#2033): "GitHub · Issues 23". The host
// calls each shown view's feeding tool on its own poll, once for every client, and keeps
// the last number its answer gave: `count` in the result's structuredContent (or its
// _meta), and `attention`, how many of them want the person. Our extension of MCP Apps
// (SEP-1865), as the list views are (#2032). A failed poll keeps the last count, marked
// stale. A hidden view is not polled.

// viewCountEvery is the poll: no faster than a server's events (10 s to 5 min, 30 s by
// default), and slow enough that 20 folders with two GitHub views each take a quarter of
// GitHub's 5000 calls an hour.
var viewCountEvery = 2 * time.Minute

// viewCountFirst is how long after the start, or after a view first shows, its first poll is.
var viewCountFirst = 10 * time.Second

// viewCountsKept bounds the counts held: a folder's views, across every folder.
const viewCountsKept = 500

type viewCount struct {
	count, attention *int64
	at               time.Time
	stale            bool
}

type viewCountBook struct {
	viewCountMu sync.Mutex
	viewCounts  map[string]viewCount
	// viewCountKick runs a poll soon, when a view shows that has no count yet.
	viewCountKick chan struct{}
}

func viewCountKey(folder, server, uri string) string { return folder + "|" + server + "|" + uri }

// withCount is v with the count held for it, if any.
func (d *Daemon) withCount(folder string, v wire.PinView) wire.PinView {
	d.viewCountMu.Lock()
	c, ok := d.viewCounts[viewCountKey(folder, v.View.Server, v.Path)]
	d.viewCountMu.Unlock()
	if !ok {
		if v.Hidden == nil {
			d.kickViewCounts()
		}
		return v
	}
	v.Count, v.Attention = c.count, c.attention
	if c.count != nil {
		at := wire.DateOf(c.at)
		v.CountAt = &at
		if c.stale {
			yes := true
			v.CountStale = &yes
		}
	}
	return v
}

func (d *Daemon) kickViewCounts() {
	d.viewCountMu.Lock()
	kick := d.viewCountKick
	d.viewCountMu.Unlock()
	if kick != nil {
		select {
		case kick <- struct{}{}:
		default:
		}
	}
}

// countViewsEvery polls every shown view's count until the daemon ends.
func (d *Daemon) countViewsEvery() {
	kick := make(chan struct{}, 1)
	d.viewCountMu.Lock()
	d.viewCountKick = kick
	d.viewCountMu.Unlock()
	t := time.NewTimer(viewCountFirst)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-kick:
			// A view with no count yet: soon, but never sooner than the first poll.
			t.Reset(viewCountFirst)
			continue
		case <-t.C:
		}
		d.countViewsOnce(d.ctx)
		t.Reset(viewCountEvery)
	}
}

// countViewsOnce calls each shown list view's feeding tool once, one after another, and
// says a folder's pins again when one of its counts changed.
func (d *Daemon) countViewsOnce(ctx context.Context) {
	seen := map[string]bool{}
	for _, s := range d.folders(false) {
		folder := store.FolderPath(s.Folder.Folder)
		changed := false
		for _, v := range d.serverViews(folder, d.readPins(folder)) {
			if v.Hidden != nil || ctx.Err() != nil {
				continue
			}
			key := viewCountKey(folder, v.View.Server, v.Path)
			seen[key] = true
			if d.countView(ctx, folder, key, *v.View) {
				changed = true
			}
		}
		if changed {
			d.pinsChanged(folder)
		}
	}
	// Bounded: what no folder shows now goes.
	d.viewCountMu.Lock()
	for key := range d.viewCounts {
		if !seen[key] || len(d.viewCounts) > viewCountsKept {
			delete(d.viewCounts, key)
		}
	}
	d.viewCountMu.Unlock()
}

// countView polls one view, and says whether what is shown for it changed.
func (d *Daemon) countView(ctx context.Context, folder, key string, v wire.ViewPin) bool {
	count, attention, err := d.readViewCount(ctx, folder, v)
	d.viewCountMu.Lock()
	defer d.viewCountMu.Unlock()
	if d.viewCounts == nil {
		d.viewCounts = map[string]viewCount{}
	}
	was, had := d.viewCounts[key]
	now := viewCount{count: count, attention: attention, at: nowFunc()}
	if err != nil {
		if !had || was.count == nil {
			// Nothing to keep: no count, and no stale mark on nothing.
			d.viewCounts[key] = viewCount{}
			return false
		}
		now = was
		now.stale = true
	}
	d.viewCounts[key] = now
	return !had || !sameInt(was.count, now.count) || !sameInt(was.attention, now.attention) || was.stale != now.stale
}

func sameInt(a, b *int64) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }

// readViewCount calls the view's feeding tool as a list view's page does, with the pin's
// arguments, and reads `count` and `attention` from its answer.
func (d *Daemon) readViewCount(ctx context.Context, folder string, v wire.ViewPin) (count, attention *int64, err error) {
	s, problem := d.viewServerFor(v.Server, folder)
	if problem != 0 {
		return nil, nil, viewRefused(problem.words(v.Server))
	}
	var result json.RawMessage
	err = withViewSession(ctx, s, func(m *viewSession) error {
		var err error
		arguments := json.RawMessage("{}")
		if len(v.Arguments) > 0 && string(v.Arguments) != "null" {
			// A project's repository (#2669).
			arguments = v.Arguments
		}
		result, err = m.call("tools/call", map[string]any{"name": v.Tool, "arguments": arguments})
		return err
	})
	if err != nil {
		log.Printf("view counts: %s's %s did not answer (%s)", v.Server, v.Tool, mcpFailureOf(err).kind)
		return nil, nil, err
	}
	count, attention, failed := viewCountOf(result)
	if failed {
		log.Printf("view counts: %s's %s answered with an error", v.Server, v.Tool)
		return nil, nil, viewRefused(v.Tool + " failed")
	}
	return count, attention, nil
}

// viewCountOf reads a tools/call result: structuredContent's count and attention, else
// _meta's; failed when the call says it failed.
func viewCountOf(result json.RawMessage) (count, attention *int64, failed bool) {
	var r struct {
		IsError    bool `json:"isError"`
		Structured struct {
			Count     *int64 `json:"count"`
			Attention *int64 `json:"attention"`
		} `json:"structuredContent"`
		Meta struct {
			Count     *int64 `json:"count"`
			Attention *int64 `json:"attention"`
		} `json:"_meta"`
	}
	if json.Unmarshal(result, &r) != nil || r.IsError {
		return nil, nil, true
	}
	count, attention = r.Structured.Count, r.Structured.Attention
	if count == nil {
		count, attention = r.Meta.Count, r.Meta.Attention
	}
	if count != nil && *count < 0 {
		count = nil
	}
	if attention != nil && (*attention < 0 || count == nil) {
		attention = nil
	}
	return count, attention, false
}

// startViewCounts starts the poll.
func (d *Daemon) startViewCounts() { safe.Go("view counts", d.countViewsEvery) }
