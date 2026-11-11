package agentsd

import (
	"context"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A folder's summary, its approvals, its idle check and the helper limits read only its
// live records once its archived ones are summed (#4510); the archived still count in the
// summary and are still listed when asked for.
func TestTheHotPathReadsOnlyLiveRecords(t *testing.T) {
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Shutdown)
	t.Cleanup(d.stopFolderWatches)
	folder := t.TempDir()
	url := store.FolderURL(folder)
	byUser := wire.AgentArchivedReasonByUser
	live := store.NewUUID()
	d.Store.Save(wire.Agent{ID: live, RuntimeID: "claude", Cwd: url, State: wire.AgentStateFinished, EndedReason: reason(wire.EndedReasonEndTurn),
		CreatedAt: 500, LastActivityAt: 600, CostToDate: map[string]float64{"USD": 1}})
	const archived = 50
	for i := range archived {
		at := wire.Date(100 + i)
		d.Store.Save(wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: url, State: wire.AgentStateArchived,
			ArchivedAt: &at, ArchivedReason: &byUser, CreatedAt: at, LastActivityAt: at, CostToDate: map[string]float64{"USD": 2}})
	}
	first, ok := d.folderSummary(folder)
	if !ok {
		t.Fatal("no summary")
	}
	if c := first.Counts.Archived; c == nil || *c != archived {
		t.Fatalf("archived count %v", c)
	}
	if first.CostToDate["USD"] != 1+2*archived || first.Folder.AddedAt != 100 || first.LastActivityAt != 600 {
		t.Fatalf("summary %+v", first)
	}
	// A pass over every record reads all 51; the live one alone is 1. The count is the
	// store's, so a pass the daemon makes in the background at the same time adds to it:
	// one try of the five under archived is the proof.
	visits := func(what string, run func()) {
		t.Helper()
		var n int64
		for range 5 {
			before := d.Store.Visited()
			run()
			if n = d.Store.Visited() - before; n < archived {
				return
			}
		}
		t.Fatalf("%s visited %d records, want only the live one", what, n)
	}
	visits("the summary", func() {
		if again, _ := d.folderSummary(folder); again.CostToDate["USD"] != first.CostToDate["USD"] {
			t.Fatalf("again %+v", again)
		}
	})
	visits("the needs", func() { d.needs() })
	visits("the waiting count", func() { d.waitingCount() })
	visits("the idle check", func() { d.workingIn(folder) })
	visits("the helpers counted", func() { d.helpersIn(folder) })
	visits("the helpers queued", func() { d.helperQueue(folder) })
	visits("the host's status", func() { d.hostStatus() })
	visits("agents/list", func() {
		if got := d.listAgents(wire.ListRequest{}); len(got) != 1 {
			t.Fatalf("listed %d", len(got))
		}
	})
	if got := d.listAgents(wire.ListRequest{IncludeArchived: true}); len(got) != 1+archived {
		t.Fatalf("listed with the archived %d", len(got))
	}
	if got := d.listAgents(wire.ListRequest{ArchivedOnly: true}); len(got) != archived {
		t.Fatalf("listed archived only %d", len(got))
	}
}
