package agentsd

import (
	"context"
	goruntime "runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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

// A host that is shut down leaves no goroutine of its own (#3617): each test's host left
// its lease ticker, project queue check, event pruner and lineage linker, so a whole run
// held hundreds of stopped hosts, and a late test's call went unanswered under load.
func TestShutdownLeavesNoGoroutine(t *testing.T) {
	before := daemonGoroutines()
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d.lineageDo(func() {})
	d.Shutdown()
	var left []string
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		left = left[:0]
		for id, stack := range daemonGoroutines() {
			if _, ok := before[id]; !ok {
				left = append(left, stack)
			}
		}
		if len(left) == 0 {
			return
		}
	}
	t.Fatalf("%d goroutines outlived Shutdown:\n\n%s", len(left), strings.Join(left, "\n\n"))
}

// daemonGoroutines is every goroutine but this one that runs this package's code, by ID.
func daemonGoroutines() map[string]string {
	buf := make([]byte, 1<<20)
	for {
		n := goruntime.Stack(buf, true)
		if n < len(buf) {
			buf = buf[:n]
			break
		}
		buf = make([]byte, 2*len(buf))
	}
	out := map[string]string{}
	for i, g := range strings.Split(string(buf), "\n\n") {
		if i == 0 || !strings.Contains(g, "internal/agentsd.") {
			continue // the first is this one
		}
		id, _, _ := strings.Cut(strings.TrimPrefix(g, "goroutine "), " ")
		out[id] = g
	}
	return out
}
