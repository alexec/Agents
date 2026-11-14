package agentsd

import (
	"context"
	"errors"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// agents/list and client/catchUp with changedSince answer only what changed since, archived
// ones too, with the removals in the catch-up; a point the host cannot vouch for gets
// revisionGone from the list and the whole list from the catch-up (#4785).
func TestChangedSince(t *testing.T) {
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Shutdown)
	t.Cleanup(d.stopFolderWatches)
	url := store.FolderURL(t.TempDir())
	agent := func(id wire.UUID, state wire.AgentState) wire.Agent {
		a := wire.Agent{ID: id, RuntimeID: "claude", Cwd: url, State: state, EndedReason: reason(wire.EndedReasonEndTurn), CreatedAt: 1, LastActivityAt: 2}
		if state == wire.AgentStateArchived {
			at, by := wire.Date(3), wire.AgentArchivedReasonByUser
			a.ArchivedAt, a.ArchivedReason = &at, &by
		}
		return a
	}
	kept, archived, gone := store.NewUUID(), store.NewUUID(), store.NewUUID()
	for _, id := range []wire.UUID{kept, archived, gone} {
		if err := d.Store.Save(agent(id, wire.AgentStateFinished)); err != nil {
			t.Fatal(err)
		}
	}
	first := d.catchUp(wire.CatchUpRequest{})
	c := first.AgentChanges
	if c == nil || !c.All || c.Epoch == "" || len(first.Agents) != 3 {
		t.Fatalf("first catch-up %+v, %d agents", c, len(first.Agents))
	}
	point := wire.ListRevision{Epoch: c.Epoch, Revision: c.Revision}

	// Nothing changed: nothing comes.
	again := d.catchUp(wire.CatchUpRequest{Agents: &wire.ListRequest{Lean: true, ChangedSince: &point}})
	if again.AgentChanges.All || len(again.Agents) != 0 || len(again.AgentChanges.Removed) != 0 || again.AgentChanges.Revision != point.Revision {
		t.Fatalf("unchanged %+v, %d agents", again.AgentChanges, len(again.Agents))
	}

	// One archived, one deleted: the live list sends the archived record, the catch-up the
	// deleted id.
	if err := d.Store.Save(agent(archived, wire.AgentStateArchived)); err != nil {
		t.Fatal(err)
	}
	if err := d.Store.Delete(gone); err != nil {
		t.Fatal(err)
	}
	listed, err := d.agentsList(wire.ListRequest{Lean: true, Limit: ptr(int64(1)), ChangedSince: &point})
	if err != nil || len(listed) != 1 || listed[0].ID != archived || listed[0].Revision == nil {
		t.Fatalf("listed %v %v", listed, err)
	}
	next := d.catchUp(wire.CatchUpRequest{Agents: &wire.ListRequest{Lean: true, ChangedSince: &point}})
	if n := next.AgentChanges; n.All || len(next.Agents) != 1 || len(n.Removed) != 1 || n.Removed[0] != gone || n.Revision <= point.Revision {
		t.Fatalf("after changes %+v, %v", n, next.Agents)
	}

	// Another epoch: the list refuses, the catch-up sends all.
	other := wire.ListRevision{Epoch: "another", Revision: point.Revision}
	if _, err := d.agentsList(wire.ListRequest{Lean: true, ChangedSince: &other}); !isCode(err, wire.FailureRevisionGone) {
		t.Fatalf("another epoch's list: %v", err)
	}
	all := d.catchUp(wire.CatchUpRequest{Agents: &wire.ListRequest{Lean: true, ChangedSince: &other}})
	if !all.AgentChanges.All || len(all.Agents) != 1 || len(all.AgentChanges.Removed) != 0 {
		t.Fatalf("another epoch's catch-up %+v, %d agents", all.AgentChanges, len(all.Agents))
	}

	// A list with no changedSince is as before.
	if got := d.listAgents(wire.ListRequest{Lean: true}); len(got) != 1 || got[0].ID != kept {
		t.Fatalf("plain list %v", got)
	}
}

func isCode(err error, code int) bool {
	var e *Error
	return errors.As(err, &e) && e.Code == code
}
