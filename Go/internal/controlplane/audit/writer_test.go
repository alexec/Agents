package audit

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// slowStore is a bucket whose every Put takes a while. When refuses is set, that
// many Puts of each event key fail, and then the key is kept. A seal is kept at
// once, so one entry cannot spend another's refusals (#2495).
type slowStore struct {
	store.Store
	pause   time.Duration
	refuses int
	puts    atomic.Int64
	seen    sync.Map
}

func (s *slowStore) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	s.puts.Add(1)
	select {
	case <-time.After(s.pause):
	case <-ctx.Done():
		return "", ctx.Err()
	}
	if s.refuses > 0 && strings.HasPrefix(key, Prefix) {
		v, _ := s.seen.LoadOrStore(key, &atomic.Int64{})
		if int(v.(*atomic.Int64).Add(1)) <= s.refuses {
			return "", errors.New("the bucket is down")
		}
	}
	return s.Store.Put(ctx, key, data, when)
}

func pending(i int) Pending {
	target := fmt.Sprintf("bea-%d", i)
	return Pending{Method: "scim/patchUser", Action: "Changed a person by SCIM", Who: func() (wire.AuditActor, *string) {
		return wire.AuditActor{User: "scim:okta"}, &target
	}}
}

// 1,000 entries in a second on a bucket whose Put takes 100 ms (#2433): kept in a few
// seconds by one writer, not one Put at a time (100 s), and with no goroutine each; the
// chain and its seal verify.
func TestAWriterKeepsABurstInOrder(t *testing.T) {
	s := &slowStore{Store: store.NewMemory(), pause: 100 * time.Millisecond}
	c := NewChain("copy1")
	w := NewWriter(&Log{Store: s, Chain: c}, func(line string) { t.Log(line) })
	before := runtime.NumGoroutine()
	peak := atomic.Int64{}
	sampling := make(chan struct{})
	go func() {
		for {
			select {
			case <-sampling:
				return
			case <-time.After(5 * time.Millisecond):
				if n := int64(runtime.NumGoroutine()); n > peak.Load() {
					peak.Store(n)
				}
			}
		}
	}()
	start := time.Now()
	for i := range 1000 {
		if !w.Add(pending(i)) {
			t.Fatalf("entry %d was refused", i)
		}
		if i%100 == 99 {
			time.Sleep(100 * time.Millisecond)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	w.Close(ctx)
	took := time.Since(start)
	close(sampling)
	if err := c.Seal(context.Background(), s, time.Now()); err != nil {
		t.Fatal(err)
	}
	r, err := Verify(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	if !r.OK() || r.Entries != 1000 || r.Chains != 1 || r.Seals != 1 {
		t.Fatalf("verify %+v", r)
	}
	extra := peak.Load() - int64(before)
	t.Logf("1000 entries, Put 100 ms: kept in %v, %d Puts, peak %d goroutines over the %d before", took.Round(time.Millisecond), s.puts.Load(), extra, before)
	if took > 15*time.Second {
		t.Fatalf("took %v", took)
	}
	if extra > writerPuts+8 {
		t.Fatalf("peak %d goroutines over the %d before", extra, before)
	}
}

// A Put the bucket refuses is tried again, past the old budget of three tries, and
// the chain stays whole (#2495). Each event key fails on its own.
func TestAWriterTriesAFailedPutAgain(t *testing.T) {
	s := &slowStore{Store: store.NewMemory(), refuses: 5}
	c := NewChain("copy1")
	w := NewWriter(&Log{Store: s, Chain: c}, func(line string) { t.Log(line) })
	for i := range 10 {
		w.Add(pending(i))
	}
	w.Close(context.Background())
	c.Seal(context.Background(), s, time.Now())
	if r, err := Verify(context.Background(), s); err != nil || !r.OK() || r.Entries != 10 {
		t.Fatalf("verify %+v %v", r, err)
	}
}

// An entry is given up only when Close's context ends. Until then a refusal is
// tried again, so the test store can refuse every Put and the entry stays out
// until that moment (#2495).
func TestAWriterGivesUpWhenCloseEnds(t *testing.T) {
	s := &slowStore{Store: store.NewMemory(), refuses: 1_000_000}
	said := make(chan string, 8)
	w := NewWriter(&Log{Store: s, Chain: NewChain("copy1")}, func(line string) {
		select {
		case said <- line:
		default:
		}
	})
	if !w.Add(pending(1)) {
		t.Fatal("the entry was refused")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	w.Close(ctx)
	deadline := time.After(3 * time.Second)
	var lines []string
	for {
		select {
		case line := <-said:
			lines = append(lines, line)
			if strings.Contains(line, "was not kept") {
				keys, err := s.List(context.Background(), Prefix)
				if err != nil || len(keys) != 0 {
					t.Fatalf("kept %v %v", keys, err)
				}
				return
			}
		case <-deadline:
			t.Fatalf("no gap line: %v", lines)
		}
	}
}

// A writer that has stopped refuses an entry and says so; a full queue does too.
func TestAStoppedWriterRefuses(t *testing.T) {
	said := atomic.Int64{}
	w := NewWriter(&Log{Store: store.NewMemory(), Chain: NewChain("copy1")}, func(string) { said.Add(1) })
	w.Close(context.Background())
	if w.Add(pending(1)) || said.Load() != 1 {
		t.Fatalf("a stopped writer took an entry, said %d", said.Load())
	}
}

// A seal names only an entry in the store: one linked but not landed is not its head.
func TestASealNamesOnlyALandedEntry(t *testing.T) {
	s := store.NewMemory()
	c := NewChain("copy1")
	at := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	first, second := stored{Kind: Kind}, stored{Kind: Kind}
	one, _ := c.link(&first, Key(at, "alex"), at)
	if _, err := s.Put(context.Background(), one.Key, one.Data, store.Absent); err != nil {
		t.Fatal(err)
	}
	c.landed(context.Background(), s, one)
	c.link(&second, Key(at, "alex"), at)
	c.Seal(context.Background(), s, at)
	object, _ := s.Get(context.Background(), sealKey("2026-10-22", "copy1"))
	if object == nil || !strings.Contains(string(object.Data), `"seq":1,`) {
		t.Fatalf("seal %v", object)
	}
}
