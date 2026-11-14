package store

import (
	"encoding/json"
	"log"
	"os"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The host's order of changes to its records (#4785): each Save gives the record the next
// revision, each Delete notes the id with one, and a client that held the list at one
// revision asks for what changed since (ListRequest.changedSince) instead of all of it.
//
// The counter is kept on disk in blocks (revisionBlock), so a restart never gives a number
// again without a write per Save. The epoch names the order: a root with no revisions file,
// or one copied from another root, starts a new one, and a client's point in an old epoch
// gets the whole list.

// revisionsVersion is the revisions file's format.
const revisionsVersion = 1

// revisionBlock is how many revisions are put by on disk at a time.
const revisionBlock = 1000

// removalsKept bounds the log of removed records: at most this many, none older than
// removalsFor. A point from before the oldest one kept gets the whole list.
const (
	removalsKept = 2000
	removalsFor  = 7 * 24 * time.Hour
)

type revisionsFile struct {
	Version int    `json:"version"`
	Epoch   string `json:"epoch"`
	// RootID is the root the epoch was made for: a copied root starts its own.
	RootID string `json:"rootID"`
	// Reserved is the highest revision put by: none at or below it is given again.
	Reserved int64 `json:"reserved"`
	// Floor is the highest revision whose removals were let go: a point below it
	// cannot be vouched for.
	Floor   int64     `json:"floor"`
	Removed []removal `json:"removed"`
}

type removal struct {
	ID       wire.UUID `json:"id"`
	Revision int64     `json:"revision"`
	At       time.Time `json:"at"`
}

// revisions is the store's order of changes. With Store.mu held.
type revisions struct {
	epoch    string
	given    int64
	reserved int64
	floor    int64
	removed  []removal
	// pending is the revisions given to a Save whose record is not put yet: the current
	// revision stays below the lowest, so no client passes a change it has not seen.
	pending map[int64]struct{}
}

// openRevisions reads the revisions file, or starts a new epoch. given is the highest
// revision on the records read.
func (s *Store) openRevisions(given int64) {
	r := &s.rev
	r.pending = map[int64]struct{}{}
	var f revisionsFile
	b, err := os.ReadFile(s.Loc.Revisions())
	switch {
	case err == nil && json.Unmarshal(b, &f) == nil && f.Version == revisionsVersion && f.Epoch != "" && f.RootID == s.RootID:
		r.epoch, r.floor, r.removed = f.Epoch, f.Floor, f.Removed
		r.given = max(given, f.Reserved)
	default:
		if !os.IsNotExist(err) {
			log.Printf("the revisions file could not be vouched for: a new epoch, and every client fetches its whole list")
		}
		r.epoch = newUUID()
		r.given = given
		r.floor = given
	}
	r.reserved = r.given + revisionBlock
	s.writeRevisions()
}

// nextRevision gives the next revision, putting a new block by first when the last is
// used up. With mu held.
func (s *Store) nextRevision() int64 {
	r := &s.rev
	r.given++
	if r.given > r.reserved {
		r.reserved = r.given + revisionBlock
		s.writeRevisions()
	}
	return r.given
}

// writeRevisions writes the revisions file. With mu held: it is written once a block, and
// on each Delete.
func (s *Store) writeRevisions() {
	r := &s.rev
	f := revisionsFile{Version: revisionsVersion, Epoch: r.epoch, RootID: s.RootID, Reserved: r.reserved, Floor: r.floor, Removed: r.removed}
	if f.Removed == nil {
		f.Removed = []removal{}
	}
	b, err := json.MarshalIndent(f, "", "  ")
	if err == nil {
		err = WriteAtomically(s.Loc.Revisions(), b, 0o644)
	}
	if err != nil {
		log.Printf("could not write the revisions file: %v", err)
	}
}

// noteRemoved logs a record's removal and lets the oldest removals go. With mu held.
func (s *Store) noteRemoved(id wire.UUID, now time.Time) {
	r := &s.rev
	r.removed = append(r.removed, removal{ID: id, Revision: s.nextRevision(), At: now})
	cut := 0
	for cut < len(r.removed) && (len(r.removed)-cut > removalsKept || now.Sub(r.removed[cut].At) > removalsFor) {
		r.floor = max(r.floor, r.removed[cut].Revision)
		cut++
	}
	r.removed = r.removed[cut:]
	s.writeRevisions()
}

// current is the revision every change up to which is visible. With mu held.
func (s *Store) current() int64 {
	r := &s.rev
	at := r.given
	for p := range r.pending {
		at = min(at, p-1)
	}
	return at
}

// Revision is where the store is in its order of changes now.
func (s *Store) Revision() wire.ListRevision {
	s.mu.Lock()
	defer s.mu.Unlock()
	return wire.ListRevision{Epoch: s.rev.epoch, Revision: s.current()}
}

// Vouches says whether the store can tell every change since p: p is of this epoch, not
// from before the removals it let go, and not ahead of it.
func (s *Store) Vouches(p wire.ListRevision) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return p.Epoch == s.rev.epoch && p.Revision >= s.rev.floor && p.Revision <= s.current()
}

// RemovedSince is the ids of the records removed after revision since, oldest first.
func (s *Store) RemovedSince(since int64) []wire.UUID {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []wire.UUID{}
	for _, r := range s.rev.removed {
		if r.Revision > since {
			out = append(out, r.ID)
		}
	}
	return out
}

// ChangedSince says whether a record changed after revision since.
func ChangedSince(a *wire.Agent, since int64) bool {
	return a.Revision == nil || *a.Revision > since
}

// revisionsAtOpen starts the order of changes from the records read: a record no revision
// of this epoch covers (one from before #4785, or written by another build) gets one, so a
// client that resumes is sent it.
func (s *Store) revisionsAtOpen() {
	high := int64(0)
	for _, a := range s.agents {
		if a.Revision != nil {
			high = max(high, *a.Revision)
		}
	}
	s.openRevisions(high)
	for _, a := range s.agents {
		if a.Revision == nil {
			n := s.nextRevision()
			a.Revision = &n
		}
	}
}

// AgentsChangedSince is the records changed after revision since, archived ones too (an
// archive is a change), newest activity first: only those are copied out.
func (s *Store) AgentsChangedSince(since int64) []wire.Agent {
	s.mu.Lock()
	out := []wire.Agent{}
	for _, a := range s.agents {
		if ChangedSince(a, since) {
			out = append(out, *a)
		}
	}
	s.mu.Unlock()
	s.visited.Add(int64(len(out)))
	return newestFirst(out)
}
