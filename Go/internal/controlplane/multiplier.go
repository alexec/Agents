package controlplane

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The Multiplier of a machine's person over all their machines (#3903): multiplier/count,
// asked by a host when its window opens and when a PR merges. It is the person's merges in
// the last 7 days, kept by the entity tags of their machines' lineage objects: while no
// machine sent new lineage, the figure comes from what is kept, with no read of the store
// but its listing (#2975). The tags are the store's, so every copy of the control plane
// agrees on when to count again.

// mostMultipliersKept bounds the people whose merges are kept.
const mostMultipliersKept = 1_000

type multiplierBook struct {
	multiplierMu   sync.Mutex
	multiplierHeld map[string]keptMultiplier
}

type keptMultiplier struct {
	// tags is the person's lineage objects and their entity tags, as listed.
	tags string
	// merges is the person's merges since the range then; at most a few hundred a week.
	merges map[wire.LineageNode]lineage.Merge
}

// multiplierCount is multiplier/count for host's person. agentsWorking is the host's own.
func (s *Service) multiplierCount(ctx context.Context, host string, now time.Time) (wire.Multiplier, error) {
	owner := s.ownerOf(host)
	keep := func(person string) bool { return person == owner }
	keys, read, err := s.scopeLineageKeys(ctx, keep)
	if err != nil {
		return wire.Multiplier{}, err
	}
	tags, tagged := tagsOf(read)
	s.multiplierMu.Lock()
	held, ok := s.multiplierHeld[owner]
	s.multiplierMu.Unlock()
	if !ok || !tagged || held.tags != tags {
		nodes, err := s.readLineage(ctx, keys, read)
		if err != nil {
			return wire.Multiplier{}, err
		}
		held = keptMultiplier{tags: tags, merges: lineage.Merges(nodes, lineage.MultiplierSince(now))}
		if !tagged {
			return lineage.MultiplierOf(held.merges, now), nil
		}
		s.multiplierMu.Lock()
		if s.multiplierHeld == nil || len(s.multiplierHeld) >= mostMultipliersKept {
			s.multiplierHeld = map[string]keptMultiplier{}
		}
		s.multiplierHeld[owner] = held
		s.multiplierMu.Unlock()
	}
	return lineage.MultiplierOf(held.merges, now), nil
}

// tagsOf is keys and their entity tags, in the listing's order, as one string, or not tagged
// when a key has no tag: then it is read again each time.
func tagsOf(keys []store.Key) (string, bool) {
	var b strings.Builder
	for _, k := range keys {
		if k.ETag == "" {
			return "", false
		}
		b.WriteString(k.Key)
		b.WriteByte(' ')
		b.WriteString(k.ETag)
		b.WriteByte('\n')
	}
	return b.String(), true
}
