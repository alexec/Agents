package audit

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// chained writes n entries through one copy's chain, a minute apart from at, and seals.
func chained(t *testing.T, s store.Store, c *Chain, at time.Time, n int) []string {
	t.Helper()
	clock := at
	l := &Log{Store: s, Now: func() time.Time { return clock }, Chain: c}
	for i := range n {
		clock = at.Add(time.Duration(i) * time.Minute)
		target := string(rune('A' + i))
		if err := l.Write(context.Background(), wire.AuditActor{User: "alex"}, "agents/stop", "Stopped an agent", "box", &target); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.Seal(context.Background(), s, clock); err != nil {
		t.Fatal(err)
	}
	keys, _ := s.List(context.Background(), Prefix)
	var out []string
	for _, k := range keys {
		out = append(out, k.Key)
	}
	return out
}

func verified(t *testing.T, s store.Store) Report {
	t.Helper()
	r, err := Verify(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// keyOf is the key of the chain's entry seq.
func keyOf(t *testing.T, s store.Store, chain string, seq int64) string {
	t.Helper()
	keys, _ := s.List(context.Background(), Prefix)
	for _, k := range keys {
		o, _ := s.Get(context.Background(), k.Key)
		var e stored
		if json.Unmarshal(o.Data, &e) == nil && e.Chain == chain && e.Seq == seq {
			return k.Key
		}
	}
	t.Fatalf("no entry %d in %s", seq, chain)
	return ""
}

// US4: each entry carries its place and the hash of the one before; two copies keep a
// chain each; verify finds nothing wrong.
func TestTheChainLinksEachCopysEntries(t *testing.T) {
	s := store.NewMemory()
	at := time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)
	a, b := NewChain("aaaa1111"), NewChain("bbbb2222")
	chained(t, s, a, at, 3)
	chained(t, s, b, at.Add(30*time.Second), 2)

	o, _ := s.Get(context.Background(), keyOf(t, s, "aaaa1111", 2))
	var second stored
	json.Unmarshal(o.Data, &second)
	first, _ := s.Get(context.Background(), keyOf(t, s, "aaaa1111", 1))
	if second.Seq != 2 || second.Prev != Hash(first.Data) {
		t.Fatalf("entry 2 %+v, want prev %s", second, Hash(first.Data))
	}
	if r := verified(t, s); !r.OK() || r.Chains != 2 || r.Entries != 5 || r.Seals != 2 {
		t.Fatalf("%+v", r)
	}
	// Entries still list as they did.
	all, _, _ := (&Log{Store: s}).List(context.Background(), NewQuery(wire.AuditQuery{}, 90, at.Add(time.Hour), false), owner)
	if len(all) != 5 {
		t.Fatalf("listed %d", len(all))
	}
}

// One entry changed: verify names it.
func TestVerifyFindsAChangedEntry(t *testing.T) {
	s := store.NewMemory()
	at := time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)
	chained(t, s, NewChain("aaaa1111"), at, 4)
	key := keyOf(t, s, "aaaa1111", 2)
	o, _ := s.Get(context.Background(), key)
	s.Put(context.Background(), key, []byte(strings.Replace(string(o.Data), "Stopped", "Started", 1)), store.Always)
	r := verified(t, s)
	if r.OK() || len(r.Problems) != 1 || !strings.Contains(r.Problems[0], "entry 2") || !strings.Contains(r.Problems[0], "changed") {
		t.Fatalf("%+v", r)
	}

	// The last entry changed: the seal holds its hash.
	s2 := store.NewMemory()
	chained(t, s2, NewChain("cccc3333"), at, 3)
	last := keyOf(t, s2, "cccc3333", 3)
	o, _ = s2.Get(context.Background(), last)
	s2.Put(context.Background(), last, []byte(strings.Replace(string(o.Data), "\"C\"", "\"Z\"", 1)), store.Always)
	if r := verified(t, s2); r.OK() || !strings.Contains(r.Problems[0], "entry 3") {
		t.Fatalf("%+v", r)
	}
}

// One entry removed, from the middle or the end: verify says so.
func TestVerifyFindsARemovedEntry(t *testing.T) {
	ctx := context.Background()
	at := time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)
	s := store.NewMemory()
	chained(t, s, NewChain("aaaa1111"), at, 4)
	s.Delete(ctx, keyOf(t, s, "aaaa1111", 2))
	if r := verified(t, s); r.OK() || !strings.Contains(r.Problems[0], "entries 2 to 2 were removed") {
		t.Fatalf("%+v", r)
	}

	s2 := store.NewMemory()
	chained(t, s2, NewChain("bbbb2222"), at, 3)
	s2.Delete(ctx, keyOf(t, s2, "bbbb2222", 3))
	if r := verified(t, s2); r.OK() || !strings.Contains(r.Problems[0], "entry 3, its head on 2026-10-22, was removed") {
		t.Fatalf("%+v", r)
	}
}

// A day swept is not a removal; entries from before the chain are counted, not checked;
// a new day seals the one before; seals go with their day.
func TestSweptDaysAndOldEntriesAreNotProblems(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	day1 := time.Date(2026, 10, 20, 23, 58, 0, 0, time.UTC)
	c := NewChain("aaaa1111")
	// Two entries on the 20th, two on the 21st: the 21st's first seals the 20th.
	chained(t, s, c, day1, 4)
	if o, _ := s.Get(ctx, sealKey("2026-10-20", "aaaa1111")); o == nil {
		t.Fatal("the 20th was not sealed")
	}
	(&Log{Store: s, Now: func() time.Time { return day1 }}).Write(ctx, wire.AuditActor{User: "alex"}, "agents/stop", "Stopped an agent", "", nil)

	// The sweep takes the 20th: its entries and its seal.
	keys, _ := s.List(ctx, DayFolder("2026-10-20"))
	for _, k := range keys {
		s.Delete(ctx, k.Key)
	}
	if n, err := SweepSeals(ctx, s, "2026-10-21"); err != nil || n != 1 {
		t.Fatalf("swept %d seals: %v", n, err)
	}
	if r := verified(t, s); !r.OK() || r.Entries != 2 || r.Unchained != 0 {
		t.Fatalf("%+v", r)
	}

	s2 := store.NewMemory()
	(&Log{Store: s2, Now: func() time.Time { return day1 }}).Write(ctx, wire.AuditActor{User: "alex"}, "agents/stop", "Stopped an agent", "", nil)
	chained(t, s2, NewChain("bbbb2222"), day1.Add(time.Hour), 1)
	if r := verified(t, s2); !r.OK() || r.Unchained != 1 || r.Entries != 2 {
		t.Fatalf("%+v", r)
	}
}

// Writes from many goroutines at once still make one unbroken chain.
func TestConcurrentWritesMakeOneChain(t *testing.T) {
	s := store.NewMemory()
	c := NewChain("aaaa1111")
	l := &Log{Store: s, Chain: c}
	var wg sync.WaitGroup
	for range 40 {
		wg.Go(func() {
			l.Write(context.Background(), wire.AuditActor{User: "alex"}, "agents/stop", "Stopped an agent", "", nil)
		})
	}
	wg.Wait()
	c.Seal(context.Background(), s, time.Now())
	if r := verified(t, s); !r.OK() || r.Entries != 40 {
		t.Fatalf("%+v", r)
	}
}
