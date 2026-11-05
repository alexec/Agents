package agentsd

import (
	"context"
	"sync/atomic"
	"testing"
)

// Shutdown ends the timer loops and waits for a run still going (#3522): on a context
// nobody cancels, a stopped host's merged pull request loop ran an hour after its test and
// called that finished test's fake, whose t.Fatal panicked.
func TestShutdownWaitsForTheTimerLoops(t *testing.T) {
	d, _ := start(t, t.TempDir())
	running := make(chan struct{})
	var ended atomic.Bool
	d.goLoop("test loop", func(ctx context.Context) {
		close(running)
		<-ctx.Done()
		ended.Store(true)
	})
	<-running
	d.Shutdown()
	if !ended.Load() {
		t.Fatal("Shutdown returned before the loop ended")
	}
	if d.loopCtx.Err() == nil {
		t.Fatal("the loops were not told to stop")
	}
	d.goLoop("late loop", func(context.Context) { t.Error("a loop started after Shutdown") })
	d.loopRunning.Wait()
}
