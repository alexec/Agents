package controlplane

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// One Live Now tab on 100 machines for 5 minutes (#2432): a poll each 15 s asks the
// stalest 50, so every machine is asked, none more than every other poll.
func TestLiveNowAsksEveryMachineInTurn(t *testing.T) {
	t.Parallel()
	const machines, polls = 100, 20
	heard := map[string]time.Time{}
	asked := map[string]int{}
	start := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	total := 0
	for poll := range polls {
		now := start.Add(time.Duration(poll) * 15 * time.Second)
		candidates := make([]liveCandidate, 0, machines)
		for i := range machines {
			host := fmt.Sprintf("H%03d", i)
			candidates = append(candidates, liveCandidate{host: host, heard: heard[host]})
		}
		asks := liveAsks(candidates, now)
		if len(asks) > mostLiveAsks {
			t.Fatalf("poll %d asked %d", poll, len(asks))
		}
		for _, host := range asks {
			heard[host] = now
			asked[host]++
		}
		total += len(asks)
	}
	for i := range machines {
		host := fmt.Sprintf("H%03d", i)
		// 5 minutes at most every 30 s is 10 asks; the first 50 used to be asked 20 times
		// and the rest never.
		if asked[host] < 9 || asked[host] > 10 {
			t.Fatalf("%s asked %d times", host, asked[host])
		}
	}
	t.Logf("%d machines, %d polls: %d asks, each machine %d–%d times", machines, polls, total, asked["H000"], asked["H099"])
}

// A list a machine says again unchanged is not written again (#2432): one Put, not one
// an answer, until copyRestamp.
func TestAnUnchangedListIsNotWrittenAgain(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	counted := &putCountingStore{Store: store.NewMemory()}
	copies := newHostCopies(counted)
	agents := make([]string, 50)
	for i := range agents {
		agents[i] = fmt.Sprintf(`{"id":"A%02d","runtimeID":"claude","state":"running","costToDate":{"USD":0.5}}`, i)
	}
	reply := `{"result":[` + strings.Join(agents, ",") + `]}`
	for range 20 {
		copies.take("H1", "agents/list", reply)
	}
	if n := counted.puts.Load(); n != 1 {
		t.Fatalf("20 same answers wrote %d times", n)
	}
	copies.take("H1", "agents/list", strings.Replace(reply, `"USD":0.5`, `"USD":0.7`, 1))
	if n := counted.puts.Load(); n != 2 {
		t.Fatalf("a changed answer wrote %d times in all", n)
	}
	// What is held moves on all the same: the board's heard-at is the newest answer's.
	if copy := copies.current(context.Background(), "H1"); copy == nil || time.Since(copy.HeardAt.Time) > time.Second {
		t.Fatalf("held %+v", copy)
	}
	// Long after, an unchanged list is written once more, so a restart's heard-at is not old.
	copies.mu.Lock()
	copies.written["H1"] = time.Now().Add(-copyRestamp - time.Second)
	copies.mu.Unlock()
	copies.take("H1", "agents/list", strings.Replace(reply, `"USD":0.5`, `"USD":0.7`, 1))
	if n := counted.puts.Load(); n != 3 {
		t.Fatalf("after copyRestamp wrote %d times in all", n)
	}
}

type putCountingStore struct {
	store.Store
	puts atomic.Int64
}

func (c *putCountingStore) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	c.puts.Add(1)
	return c.Store.Put(ctx, key, data, when)
}
