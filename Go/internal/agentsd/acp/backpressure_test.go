package acp

import (
	"bufio"
	"fmt"
	"io"
	"sync/atomic"
	"testing"
	"time"

	sdk "github.com/coder/acp-go-sdk"
)

// slowSink takes each update a little slower than a pipe gives them.
type slowSink struct {
	asker
	updates atomic.Int64
}

func (s *slowSink) Update(sdk.SessionNotification) {
	time.Sleep(100 * time.Microsecond)
	s.updates.Add(1)
}

// burst sends count tool_call_updates as fast as the pipe takes them, and says whether
// the connection is still open once the client has every one, or has closed.
func burst(t *testing.T, gate *updateGate, count int) (open bool, handled int64) {
	sink := &slowSink{}
	c := &client{sink: sink, updates: gate}
	r, w := io.Pipe()
	conn := sdk.NewClientSideConnection(c, io.Discard, &rawElicitations{r: bufio.NewReader(r), c: c})
	go func() {
		output := fmt.Sprintf("%0200d", 0)
		for i := range count {
			line := fmt.Sprintf(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t","rawOutput":%q}}}`+"\n", fmt.Sprint(i, output))
			if _, err := w.Write([]byte(line)); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() { _ = w.Close() })
	deadline := time.After(30 * time.Second)
	for sink.updates.Load() < int64(count) {
		select {
		case <-conn.Done():
			return false, sink.updates.Load()
		case <-deadline:
			t.Fatalf("%d of %d updates handed on in 30 s", sink.updates.Load(), count)
		case <-time.After(10 * time.Millisecond):
		}
	}
	select {
	case <-conn.Done():
		return false, sink.updates.Load()
	default:
		return true, sink.updates.Load()
	}
}

// A burst of updates over the SDK's queue of 1,024 waits in the pipe, and the turn goes
// on (#3250). Without the gate, the same burst closes the connection.
func TestABurstOfUpdatesHoldsTheRuntimeRatherThanClosing(t *testing.T) {
	const count = 3000
	if open, handled := burst(t, newUpdateGate(), count); !open || handled != count {
		t.Fatalf("with the gate: open %v, %d of %d handed on", open, handled, count)
	}
	if open, handled := burst(t, nil, count); open {
		t.Fatalf("without the gate the SDK took all %d (%d handed on): the test no longer shows the overflow", count, handled)
	}
}

// A line counted that never comes down does not hold the runtime for ever.
func TestAStalledCountReadsOn(t *testing.T) {
	g := newUpdateGate()
	g.limit, g.stall = 1, 20*time.Millisecond
	g.read([]byte(`{"method":"session/update"}`))
	start := time.Now()
	g.wait()
	if waited := time.Since(start); waited < g.stall {
		t.Fatalf("read on after %s, before the stall", waited)
	}
	g.read([]byte(`{"method":"session/update"}`))
	g.done()
	start = time.Now()
	g.wait()
	if waited := time.Since(start); waited >= g.stall {
		t.Fatalf("waited %s with nothing queued", waited)
	}
}
