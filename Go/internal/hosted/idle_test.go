package hosted

import (
	"bytes"
	"context"
	"encoding/base64"
	"flag"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// countingStore counts List calls, the ones each running copy makes every 15 s.
type countingStore struct {
	store.Store
	lists atomic.Int64
	// Reads of an account record, the one toAccount makes before a copy runs.
	gets atomic.Int64
}

func (c *countingStore) Get(ctx context.Context, key string) (*store.Object, error) {
	if strings.HasPrefix(key, hostedPrefix+"v1/accounts/") {
		c.gets.Add(1)
	}
	return c.Store.Get(ctx, key)
}

func (c *countingStore) List(ctx context.Context, prefix string) ([]store.Key, error) {
	c.lists.Add(1)
	return c.Store.List(ctx, prefix)
}

// clock is a Config.Now a test moves on.
type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// idleService is a hosted service on a counting store and a clock of the test's, with n
// accounts, each opened once.
func idleService(t *testing.T, n int) (*Service, *countingStore, *clock, []string) {
	t.Helper()
	st := &countingStore{Store: store.NewMemory()}
	now := &clock{now: time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)}
	keeper := "base64key://" + base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	s, err := New(context.Background(), Config{Store: st, Keeper: keeper, Domain: domain, Now: now.Now, MaxCopies: 1000})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	var ids []string
	for i := range n {
		acc, _, err := s.accounts.make(context.Background(), GitHubID{ID: int64(1000 + i), Login: "user"})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, acc.ID)
		open(t, s, acc.ID)
	}
	return s, st, now, ids
}

// open asks an account's control plane for /readyz once, as a browser would.
func open(t *testing.T, s *Service, id string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "https://"+id+"."+domain+"/readyz", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("%s: %d %s", id, w.Code, w.Body.String())
	}
}

func (s *Service) running() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.copies)
}

// P20261020-23: a copy nobody has asked for in idleLimit stops, so 100 accounts opened
// once cost nothing once they are idle, and the next request starts the copy again.
func TestIdleCopiesStop(t *testing.T) {
	s, st, now, ids := idleService(t, 100)
	if n := s.running(); n != 100 {
		t.Fatalf("%d running, want 100", n)
	}
	// Not idle long enough yet: they keep running.
	now.add(idleLimit - time.Minute)
	s.sweepIdle()
	if n := s.running(); n != 100 {
		t.Fatalf("%d running before the idle limit, want 100", n)
	}
	now.add(2 * time.Minute)
	s.sweepIdle()
	if n := s.running(); n != 0 {
		t.Fatalf("%d running after the idle limit, want 0", n)
	}
	// A stopped copy reads nothing: no List calls over a refresh and a bit.
	before := st.lists.Load()
	time.Sleep(16 * time.Second)
	if lists := st.lists.Load() - before; lists != 0 {
		t.Fatalf("%d List calls with every copy stopped", lists)
	}
	// The next request starts it again.
	open(t, s, ids[0])
	if n := s.running(); n != 1 {
		t.Fatalf("%d running after a request, want 1", n)
	}
}

// A copy with a request still open (a host's uplink, a client's WebSocket) is in use,
// however long ago it began.
func TestACopyInUseKeepsRunning(t *testing.T) {
	s, _, now, ids := idleService(t, 1)
	c, err := s.copyFor(context.Background(), ids[0])
	if err != nil {
		t.Fatal(err)
	}
	now.add(2 * idleLimit)
	s.sweepIdle()
	if n := s.running(); n != 1 {
		t.Fatalf("%d running with a request open, want 1", n)
	}
	// Done with it: idle from then on.
	s.done(c)
	now.add(idleLimit - time.Minute)
	s.sweepIdle()
	if n := s.running(); n != 1 {
		t.Fatalf("%d running a minute before the idle limit, want 1", n)
	}
	now.add(2 * time.Minute)
	s.sweepIdle()
	if n := s.running(); n != 0 {
		t.Fatalf("%d running after the idle limit, want 0", n)
	}
}

// P20261020-24: a request to a running copy reads no account record, so 100 of
// them cost no store reads for it; one to a stopped copy reads the account and starts it.
func TestARunningCopyReadsNoAccount(t *testing.T) {
	s, st, now, ids := idleService(t, 1)
	before := st.gets.Load()
	for range 100 {
		open(t, s, ids[0])
	}
	if gets := st.gets.Load() - before; gets != 0 {
		t.Fatalf("%d account reads for 100 requests to a running copy, want 0", gets)
	}
	now.add(idleLimit + time.Minute)
	s.sweepIdle()
	before = st.gets.Load()
	open(t, s, ids[0])
	if gets := st.gets.Load() - before; gets == 0 {
		t.Fatal("no account read for a request to a stopped copy")
	}
}

// The cost of 100 idle accounts: store List calls over 30 s, after the clock has passed
// the idle limit and the sweep has run. Only with -args -measure: it takes 30 s.
var measure = flag.Bool("measure", false, "measure the cost of idle accounts")

func TestMeasureIdleAccounts(t *testing.T) {
	if !*measure {
		t.Skip("-args -measure measures")
	}
	s, st, now, _ := idleService(t, 100)
	now.add(idleLimit + time.Minute)
	s.sweepIdle()
	before := st.lists.Load()
	time.Sleep(30 * time.Second)
	t.Logf("MEASURE running=%d lists=%d", s.running(), st.lists.Load()-before)
}
