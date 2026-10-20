package agentsd

import (
	"log"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
)

// afterTurnLimit is how long Shutdown waits for the writes that follow a turn: long enough
// for a stopped turn to record its ending, short enough that a stuck write cannot hang a quit.
const afterTurnLimit = 5 * time.Second

// afterTurnState tracks the goroutines that run turns and write what follows them
// (events.jsonl, workflows.json, time-history.json, achievements.json, guarded-files.json),
// so that Shutdown can wait for them (#1272).
type afterTurnState struct {
	afterTurnMu     sync.Mutex
	afterTurnClosed bool
	afterTurns      sync.WaitGroup
}

// goAfterTurn is safe.Go for a turn and what follows it. Once the host is going it starts
// nothing and is false.
func (d *Daemon) goAfterTurn(what string, fn func()) bool {
	d.afterTurnMu.Lock()
	defer d.afterTurnMu.Unlock()
	if d.afterTurnClosed {
		return false
	}
	d.afterTurns.Add(1)
	safe.Go(what, func() {
		defer d.afterTurns.Done()
		fn()
	})
	return true
}

// closeAfterTurns starts no more turns or writes after them.
func (d *Daemon) closeAfterTurns() {
	d.afterTurnMu.Lock()
	d.afterTurnClosed = true
	d.afterTurnMu.Unlock()
}

// going is whether Shutdown has begun, or the daemon's context is done. A SIGTERM ends
// that context, and with it every turn, before main reaches Shutdown (#1822): those turns
// are cut off by the daemon's going too.
func (d *Daemon) going() bool {
	if d.ctx.Err() != nil {
		return true
	}
	d.afterTurnMu.Lock()
	defer d.afterTurnMu.Unlock()
	return d.afterTurnClosed
}

// waitAfterTurns waits for those under way, at most limit, and is false if they were not done.
func (d *Daemon) waitAfterTurns(limit time.Duration) bool {
	done := make(chan struct{})
	go func() {
		d.afterTurns.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(limit):
		log.Printf("the host goes before the writes after a turn are done (waited %v)", limit)
		return false
	}
}
