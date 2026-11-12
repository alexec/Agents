package store

import (
	"os"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

func revisionAgent(id wire.UUID) wire.Agent {
	return wire.Agent{ID: id, RuntimeID: "claude", Cwd: FolderURL("/w/a"), State: wire.AgentStateFinished,
		EndedReason: endTurn(), CreatedAt: 1, LastActivityAt: 2}
}

func endTurn() *wire.EndedReason { r := wire.EndedReasonEndTurn; return &r }

// Each Save gives the record the next revision; a Delete is noted with one; a restart goes
// on from where it was, in the same epoch (#4785).
func TestRevisionsOrderTheChanges(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	start := s.Revision()
	a, b := NewUUID(), NewUUID()
	must(t, s.Save(revisionAgent(a)))
	must(t, s.Save(revisionAgent(b)))
	if got := *s.Agent(b).Revision; got != start.Revision+2 || *s.Agent(a).Revision != start.Revision+1 {
		t.Fatalf("revisions %d %d from %d", *s.Agent(a).Revision, got, start.Revision)
	}
	mid := s.Revision()
	if mid.Revision != start.Revision+2 || mid.Epoch != start.Epoch || !s.Vouches(start) {
		t.Fatalf("at %+v from %+v", mid, start)
	}
	must(t, s.Save(revisionAgent(a)))
	if changed := s.AgentsChangedSince(mid.Revision); len(changed) != 1 || changed[0].ID != a {
		t.Fatalf("changed %v", changed)
	}
	if err := s.Delete(b); err != nil {
		t.Fatal(err)
	}
	if gone := s.RemovedSince(mid.Revision); len(gone) != 1 || gone[0] != b {
		t.Fatalf("removed %v", gone)
	}
	if gone := s.RemovedSince(s.Revision().Revision); len(gone) != 0 {
		t.Fatalf("removed since now %v", gone)
	}
	// A restart keeps the epoch, the removals and the records' revisions, and gives no
	// revision again.
	end := s.Revision()
	s2, _ := Open(s.Loc.Root)
	if at := s2.Revision(); at.Epoch != end.Epoch || at.Revision < end.Revision || !s2.Vouches(mid) {
		t.Fatalf("after a restart %+v, was %+v", at, end)
	}
	if gone := s2.RemovedSince(mid.Revision); len(gone) != 1 || gone[0] != b {
		t.Fatalf("removed after a restart %v", gone)
	}
	if changed := s2.AgentsChangedSince(end.Revision); len(changed) != 0 {
		t.Fatalf("changed after a restart %v", changed)
	}
	must(t, s2.Save(revisionAgent(a)))
	if got := *s2.Agent(a).Revision; got <= end.Revision {
		t.Fatalf("revision %d given again, was at %d", got, end.Revision)
	}
	// A point ahead of the store, or of another epoch, is not vouched for.
	if s2.Vouches(wire.ListRevision{Epoch: end.Epoch, Revision: s2.Revision().Revision + 1}) || s2.Vouches(wire.ListRevision{Epoch: "other", Revision: 0}) {
		t.Fatal("vouched for a point it cannot tell")
	}
}

// A record no revision of the epoch covers (from before #4785) gets one when read, and a
// lost or copied revisions file starts a new epoch.
func TestRevisionsNewEpoch(t *testing.T) {
	s, _ := Open(t.TempDir())
	a := NewUUID()
	must(t, s.Save(revisionAgent(a)))
	was := s.Revision()
	os.Remove(s.Loc.Revisions())
	s2, _ := Open(s.Loc.Root)
	if at := s2.Revision(); at.Epoch == was.Epoch || s2.Vouches(was) {
		t.Fatalf("a lost file kept the epoch %+v", at)
	}
	// The record is sent to a client of the new epoch: none has a point in it yet, and
	// its revision is the epoch's.
	if r := s2.Agent(a).Revision; r == nil || *r > s2.Revision().Revision {
		t.Fatalf("record revision %v", r)
	}
	// Another root's file is not this root's order.
	s3, _ := Open(s.Loc.Root)
	if s3.Revision().Epoch != s2.Revision().Epoch {
		t.Fatal("a reopen changed the epoch")
	}
	s3.RootID = "another"
	s3.openRevisions(0)
	if s3.Revision().Epoch == s2.Revision().Epoch {
		t.Fatal("another root kept the epoch")
	}
}

// The removals log is bounded; a point from before the ones let go is not vouched for.
func TestRemovalsAreBounded(t *testing.T) {
	s, _ := Open(t.TempDir())
	start := s.Revision()
	s.mu.Lock()
	now := time.Now()
	s.noteRemoved(NewUUID(), now.Add(-removalsFor-time.Hour))
	s.noteRemoved(NewUUID(), now)
	n := len(s.rev.removed)
	s.mu.Unlock()
	if n != 1 || s.Vouches(start) || !s.Vouches(wire.ListRevision{Epoch: start.Epoch, Revision: start.Revision + 1}) {
		t.Fatalf("kept %d, vouches for the start %v", n, s.Vouches(start))
	}
}

// A Save whose record is not put yet holds the current revision below its own, so a
// client never passes a change it has not been sent.
func TestPendingHoldsTheRevisionBack(t *testing.T) {
	s, _ := Open(t.TempDir())
	s.mu.Lock()
	held := s.nextRevision()
	s.rev.pending[held] = struct{}{}
	s.mu.Unlock()
	must(t, s.Save(revisionAgent(NewUUID())))
	if at := s.Revision().Revision; at != held-1 {
		t.Fatalf("at %d with %d pending", at, held)
	}
	s.mu.Lock()
	delete(s.rev.pending, held)
	s.mu.Unlock()
	if at := s.Revision().Revision; at != held+1 {
		t.Fatalf("at %d after", at)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
