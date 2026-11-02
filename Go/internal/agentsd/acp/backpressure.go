package acp

import (
	"bytes"
	"log"
	"sync"
	"time"
)

// The SDK queues each notification it reads for one goroutine to hand on, and closes the
// connection when its queue, 1,024 long and not settable in v0.13.5, is full (#3250). A
// runtime that streams a command's output fast fills it. updateGate stops reading the
// runtime's output while queuedUpdatesLimit session/updates wait, so the pipe holds the
// rest and the runtime waits, rather than the turn failing.
const (
	queuedUpdatesLimit = 256
	// queuedUpdatesStall is how long a read waits with no update handed on before it goes
	// on anyway: a line counted that the SDK did not hand on (params it refused) never
	// comes down, and a handler that waits on the runtime must not hold its own output.
	// Only four stalls in a row, with nothing handed on, fill the SDK's 1,024.
	queuedUpdatesStall = 5 * time.Second
)

var sessionUpdateMarker = []byte(`"session/update"`)

// updateGate counts the session/updates read from the runtime and not yet handed on.
type updateGate struct {
	limit   int
	stall   time.Duration
	mu      sync.Mutex
	queued  int
	handled chan struct{}
}

func newUpdateGate() *updateGate {
	return &updateGate{limit: queuedUpdatesLimit, stall: queuedUpdatesStall, handled: make(chan struct{}, 1)}
}

// wait holds the next read while the queue is at the limit.
func (g *updateGate) wait() {
	if g == nil {
		return
	}
	for {
		g.mu.Lock()
		queued := g.queued
		g.mu.Unlock()
		if queued < g.limit {
			return
		}
		select {
		case <-g.handled:
		case <-time.After(g.stall):
			log.Printf("acp: %d session/updates not handed on in %s: reading on", queued, g.stall)
			g.mu.Lock()
			g.queued = 0
			g.mu.Unlock()
			return
		}
	}
}

// read counts a line the SDK will queue as a session/update. The check is a byte one, as
// rawElicitations' are (#2733); a line it counts wrongly costs one stall at most.
func (g *updateGate) read(line []byte) {
	if g == nil || !bytes.Contains(line, sessionUpdateMarker) {
		return
	}
	g.mu.Lock()
	g.queued++
	g.mu.Unlock()
}

// done is one session/update handed on.
func (g *updateGate) done() {
	if g == nil {
		return
	}
	g.mu.Lock()
	if g.queued > 0 {
		g.queued--
	}
	g.mu.Unlock()
	select {
	case g.handled <- struct{}{}:
	default:
	}
}
