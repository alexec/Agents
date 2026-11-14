package agentsd

import (
	"fmt"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #3650: undo notes are capped as they are written, and still say "and others".
func TestUndoNotesAreCappedOnWrite(t *testing.T) {
	var u undoNotes
	id := wire.UUID("A0000000-0000-4000-8000-000000000001")
	var paths []string
	for i := range 500 {
		paths = append(paths, fmt.Sprintf("/work/f%03d.go", i))
	}
	u.remember(id, "/work", paths)
	u.remember(id, "/work", paths)
	if n := len(u.byAgent[id]); n != pageEditLimit+1 {
		t.Fatalf("%d held", n)
	}
	if told := u.take(id); !strings.Contains(told, "f019.go, and others") {
		t.Fatal(told)
	}
}

// #3650: an archived agent's running cost, views' calls and undo notes are let go.
func TestArchivingLetsGoOfAnAgentInMemory(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	a := seeded(t, d, t.TempDir(), nil)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	d.viewMu.Lock()
	d.viewCalls = map[wire.UUID]map[string]*thirdPartyCall{a.ID: {"call": {}}}
	d.viewMu.Unlock()
	d.undoNotes.remember(a.ID, "/work", []string{"/work/a.go"})
	if err := d.archive(a.ID); err != nil {
		t.Fatal(err)
	}
	d.costMu.Lock()
	_, cost := d.sessionCost[a.ID]
	d.costMu.Unlock()
	d.viewMu.Lock()
	_, calls := d.viewCalls[a.ID]
	d.viewMu.Unlock()
	if cost || calls || d.undoNotes.take(a.ID) != "" {
		t.Fatalf("held: cost %v, calls %v", cost, calls)
	}
}
