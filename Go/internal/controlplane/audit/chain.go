package audit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// The audit's hash chain (#1001, T8 slice d1). Each copy of the control plane links the
// entries it writes: each says its copy (`chain`), its place (`seq`, from 1 when the copy
// starts) and the SHA-256 of the stored bytes of the entry before (`prev`). Two copies
// write to one store at once, so each has a chain of its own and needs no lock between
// them. A seal for each day holds the head of each chain that day, so an entry removed
// from a chain's end is seen too. `agents-control audit verify` checks it all.
//
// The chain says an entry was changed or removed. It does not stop it: anyone who can
// write the store can write a new chain. A sink (slice d2) keeps a copy out of reach.

// SealsPrefix is where the seals are: <SealsPrefix><day>/<chain>.json.
const SealsPrefix = "v1/audit-seals/"

// Chain is one copy's chain. Entries are linked one at a time, under its lock; a Writer
// puts them outside it (#2433).
type Chain struct {
	ID  string
	mu  sync.Mutex
	seq int64
	// head is the hash of the last entry linked, and day its day.
	head, day string
	// The last entry known to be in the store, and its day: what a seal holds, so a seal
	// never names an entry still on its way.
	landedSeq           int64
	landedHead, landedDay string
	// sealed is the head the last seal of day holds, so an unchanged one is not written.
	sealed map[string]int64
}

// Linked is an entry linked into its chain, to be put at Key.
type Linked struct {
	Key  string
	Data []byte
	Seq  int64
	Day  string
	At   time.Time
}

// NewChain is the chain of the copy named id.
func NewChain(id string) *Chain { return &Chain{ID: id, sealed: map[string]int64{}} }

// Hash is the hash an entry's stored bytes have in the chain.
func Hash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// Seal is a day's seal of one chain: its head that day.
type Seal struct {
	Chain string        `json:"chain"`
	Day   string        `json:"day"`
	Seq   int64         `json:"seq"`
	Hash  string        `json:"hash"`
	At    records.Stamp `json:"at"`
}

func sealKey(day, chain string) string { return SealsPrefix + day + "/" + chain + ".json" }

// write links e into the chain and keeps it at key, one Put at a time: Log.Write's way.
// An entry that is not kept takes no place in the chain.
func (c *Chain) write(ctx context.Context, s store.Store, e *stored, key string, at time.Time) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l, err := c.linkLocked(e, key, at)
	if err != nil {
		return nil, err
	}
	if _, err := s.Put(ctx, key, l.Data, store.Absent); err != nil {
		return nil, err
	}
	c.seq, c.head, c.day = l.Seq, Hash(l.Data), l.Day
	c.landLocked(ctx, s, l, at)
	return l.Data, nil
}

// link places e in the chain at once (#2433): its seq and prev are taken under the lock,
// and the entries after it link to it whether or not its Put has landed yet.
func (c *Chain) link(e *stored, key string, at time.Time) (Linked, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l, err := c.linkLocked(e, key, at)
	if err == nil {
		c.seq, c.head, c.day = l.Seq, Hash(l.Data), l.Day
	}
	return l, err
}

func (c *Chain) linkLocked(e *stored, key string, at time.Time) (Linked, error) {
	e.Chain, e.Seq, e.Prev = c.ID, c.seq+1, c.head
	data, err := records.Encode(*e)
	if err != nil {
		return Linked{}, err
	}
	return Linked{Key: key, Data: data, Seq: c.seq + 1, Day: at.UTC().Format(dayLayout), At: at}, nil
}

// landed says the entries linked up to l are in the store (or were given up on): seals
// name them from now. The first entry of a new day seals the day before.
func (c *Chain) landed(ctx context.Context, s store.Store, l Linked) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if l.Seq > c.landedSeq {
		c.landLocked(ctx, s, l, l.At)
	}
}

func (c *Chain) landLocked(ctx context.Context, s store.Store, l Linked, at time.Time) {
	if c.landedDay != "" && c.landedDay != l.Day {
		// What the seal of the day before says can wait for the next tick when the store
		// refuses it now; the entry is kept either way.
		_ = c.sealLocked(ctx, s, c.landedDay, at)
	}
	c.landedSeq, c.landedHead, c.landedDay = l.Seq, Hash(l.Data), l.Day
}

// Seal writes today's seal of this chain when it has moved since the last.
func (c *Chain) Seal(ctx context.Context, s store.Store, now time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.landedDay == "" {
		return nil
	}
	return c.sealLocked(ctx, s, c.landedDay, now)
}

func (c *Chain) sealLocked(ctx context.Context, s store.Store, day string, now time.Time) error {
	if c.landedSeq == 0 || c.sealed[day] == c.landedSeq {
		return nil
	}
	data, err := json.Marshal(Seal{Chain: c.ID, Day: day, Seq: c.landedSeq, Hash: c.landedHead, At: records.At(now)})
	if err != nil {
		return err
	}
	if _, err := s.Put(ctx, sealKey(day, c.ID), data, store.Always); err != nil {
		return err
	}
	// One day's head is all a chain needs to remember: the days before are sealed.
	c.sealed = map[string]int64{day: c.landedSeq}
	return nil
}

// SweepSeals deletes the seals of the days before cutoff, as the sweep deletes entries.
func SweepSeals(ctx context.Context, s store.Store, cutoff string) (int, error) {
	keys, err := s.List(ctx, SealsPrefix)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, k := range keys {
		day, _, _ := strings.Cut(strings.TrimPrefix(k.Key, SealsPrefix), "/")
		if day < cutoff {
			if err := s.Delete(ctx, k.Key); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}

// Report is what Verify found.
type Report struct {
	// Chains, Entries and Seals checked; Unchained, entries written before the chain.
	Chains, Entries, Seals, Unchained int
	// Problems, each a line: an entry changed, removed, or unreadable.
	Problems []string
}

// OK says whether nothing was changed or removed.
func (r Report) OK() bool { return len(r.Problems) == 0 }

type link struct {
	key, prev, hash string
	seq             int64
}

// Verify reads every entry and seal in the store and checks each chain: its places follow
// one another, each entry names the hash of the one before, and each seal's head is
// there with that hash. The days before the oldest one kept were swept, not removed.
func Verify(ctx context.Context, s store.Store) (Report, error) {
	var r Report
	keys, err := s.List(ctx, Prefix)
	if err != nil {
		return r, err
	}
	chains := map[string][]link{}
	oldest := ""
	for _, k := range keys {
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return r, err
		}
		if object == nil {
			continue
		}
		if day := KeyDay(k.Key); oldest == "" || day < oldest {
			oldest = day
		}
		var e stored
		if json.Unmarshal(object.Data, &e) != nil {
			r.Problems = append(r.Problems, fmt.Sprintf("%s can't be read: it was changed", k.Key))
			continue
		}
		if e.Kind != Kind {
			continue
		}
		r.Entries++
		if e.Chain == "" {
			r.Unchained++
			continue
		}
		chains[e.Chain] = append(chains[e.Chain], link{key: k.Key, prev: e.Prev, hash: Hash(object.Data), seq: e.Seq})
	}
	ids := make([]string, 0, len(chains))
	for id := range chains {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	r.Chains = len(ids)
	for _, id := range ids {
		links := chains[id]
		sort.Slice(links, func(i, j int) bool { return links[i].seq < links[j].seq })
		first := links[0]
		if first.seq > 1 && KeyDay(first.key) != oldest {
			r.Problems = append(r.Problems, fmt.Sprintf("chain %s: entries 1 to %d were removed", id, first.seq-1))
		}
		for i := 1; i < len(links); i++ {
			before, l := links[i-1], links[i]
			switch {
			case l.seq == before.seq:
				r.Problems = append(r.Problems, fmt.Sprintf("chain %s: two entries are number %d (%s, %s)", id, l.seq,
					path.Base(before.key), path.Base(l.key)))
			case l.seq != before.seq+1:
				r.Problems = append(r.Problems, fmt.Sprintf("chain %s: entries %d to %d were removed", id, before.seq+1, l.seq-1))
			case l.prev != before.hash:
				r.Problems = append(r.Problems, fmt.Sprintf("chain %s: entry %d (%s) was changed", id, before.seq, before.key))
			}
		}
	}
	seals, err := s.List(ctx, SealsPrefix)
	if err != nil {
		return r, err
	}
	for _, k := range seals {
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return r, err
		}
		var seal Seal
		if object == nil || json.Unmarshal(object.Data, &seal) != nil {
			r.Problems = append(r.Problems, fmt.Sprintf("the seal %s can't be read: it was changed", k.Key))
			continue
		}
		r.Seals++
		if seal.Day < oldest {
			continue
		}
		var found *link
		for i, l := range chains[seal.Chain] {
			if l.seq == seal.Seq {
				found = &chains[seal.Chain][i]
				break
			}
		}
		switch {
		case found == nil:
			r.Problems = append(r.Problems, fmt.Sprintf("chain %s: entry %d, its head on %s, was removed", seal.Chain, seal.Seq, seal.Day))
		case found.hash != seal.Hash:
			r.Problems = append(r.Problems, fmt.Sprintf("chain %s: entry %d (%s) was changed", seal.Chain, seal.Seq, found.key))
		}
	}
	return r, nil
}
