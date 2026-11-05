package agentsd

import (
	"context"
	"sync"

	"github.com/alexec/agents/Go/internal/safe"
)

// loopBook is the loops that run on a timer for as long as the host does: the merged pull
// requests, the release tags, the view counts, For Review, the feature counts and the
// disk. Shutdown stops them and waits for a run still going, as stopWorkflowClock does for
// the workflow clock: on a context nobody cancels (a test's) a stopped host's loop ran an
// hour later and called a finished test's fake (#3522).
type loopBook struct {
	loopMu      sync.Mutex
	loopCtx     context.Context
	loopStop    context.CancelFunc
	loopRunning sync.WaitGroup
}

// goLoop runs loop on its own goroutine until stopLoops; loop ends when its ctx is done.
// It does not start once the loops are stopped.
func (d *Daemon) goLoop(name string, loop func(ctx context.Context)) {
	d.loopMu.Lock()
	defer d.loopMu.Unlock()
	if d.loopCtx == nil {
		d.loopCtx, d.loopStop = context.WithCancel(d.ctx)
	}
	if d.loopCtx.Err() != nil {
		return
	}
	d.loopRunning.Add(1)
	ctx := d.loopCtx
	safe.Go(name, func() { defer d.loopRunning.Done(); loop(ctx) })
}

// stopLoops ends every loop goLoop started and waits for each to return.
func (d *Daemon) stopLoops() {
	d.loopMu.Lock()
	if d.loopCtx == nil {
		d.loopCtx, d.loopStop = context.WithCancel(d.ctx)
	}
	d.loopStop()
	d.loopMu.Unlock()
	d.loopRunning.Wait()
}
