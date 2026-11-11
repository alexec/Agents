package agentsd

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// #4275: the host sends every link and every change of state the store keeps first, with
// reset; then only what changed: a state the store recorded, and the links that started or
// ended. A control plane with no copy is sent all again. What is unsent outlives the host.
func TestLineageSyncSendsWhatChanged(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	a := seeded(t, d, folder, nil)
	// A new record: lineage records its state (#4274).
	d.noteLineage(nil, a)
	issue := wire.LineageNode{Kind: lineage.KindIssue, Ref: "github:alexec/agents#7"}
	d.link(sessionNode(a.ID), issue, lineage.RelWorksOn, lineage.SourcePerson)
	d.lineageSettle(2 * time.Second)

	var mu sync.Mutex
	var sent []wire.LineageSync
	full := false
	d.SetControlCapabilities(func() []string { return []string{wire.CapLineageGraph1} })
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != wire.CallLineageSync.Name {
			return json.RawMessage(`{}`), nil
		}
		mu.Lock()
		defer mu.Unlock()
		sent = append(sent, params.(wire.LineageSync))
		if full {
			full = false
			return json.RawMessage(`{"full":true}`), nil
		}
		return json.RawMessage(`{}`), nil
	}))
	took := func() []wire.LineageSync {
		t.Helper()
		d.sendLineage()
		mu.Lock()
		defer mu.Unlock()
		out := sent
		sent = nil
		return out
	}

	first := took()
	if len(first) != 1 || first[0].Reset == nil || len(first[0].Links) != 1 || first[0].Links[0].To != issue ||
		len(first[0].States) != 1 || first[0].States[0].State != wire.LineageSessionStateNameStopped ||
		first[0].States[0].Node != sessionNode(a.ID) {
		t.Fatalf("first %+v", first)
	}
	if again := took(); len(again) != 0 {
		t.Fatalf("sent again: %+v", again)
	}

	// Archived: its state, and its links ended.
	byUser := wire.AgentArchivedReasonByUser
	d.changeAgent(a.ID, true, func(a *wire.Agent) { a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser })
	d.lineageSettle(2 * time.Second)
	// The send's own timer may have taken part of it already: what went, all told.
	var moved wire.LineageSync
	for _, s := range took() {
		if s.Reset != nil {
			t.Fatalf("reset again: %+v", s)
		}
		moved.Links = append(moved.Links, s.Links...)
		moved.States = append(moved.States, s.States...)
	}
	if len(moved.States) != 1 || moved.States[0].State != wire.LineageSessionStateNameArchived ||
		len(moved.Links) != 1 || moved.Links[0].EndedAt == nil {
		t.Fatalf("moved %+v", moved)
	}
	// A change that does not move its state sends nothing.
	d.changeAgent(a.ID, true, func(a *wire.Agent) { title := "renamed"; a.Title = &title })
	if same := took(); len(same) != 0 {
		t.Fatalf("sent for no move: %+v", same)
	}

	// A control plane with no copy: every link again, the first with reset.
	pr := wire.LineageNode{Kind: lineage.KindPR, Ref: "github:alexec/agents#9"}
	d.link(sessionNode(a.ID), pr, lineage.RelOpens, lineage.SourceAgent)
	mu.Lock()
	full = true
	mu.Unlock()
	whole := took()
	if len(whole) != 2 || whole[0].Reset != nil || len(whole[0].Links) != 1 || whole[1].Reset == nil || len(whole[1].Links) != 2 ||
		len(whole[1].States) != 2 || whole[1].States[1].State != wire.LineageSessionStateNameArchived {
		t.Fatalf("whole %+v", whole)
	}

	// Unsent, then the host stops: the state is still to send when it starts again.
	d.SetControlAsk(nil)
	d.recordSessionState(a.ID, wire.LineageSessionStateNameDeleted)
	d.lineageSettle(2 * time.Second)
	d.closeLineageSync()
	d.syncFile = nil
	d.syncMu.Lock()
	f := d.syncLocked()
	d.syncMu.Unlock()
	if f.Full || len(f.States) != 1 || f.States[0].State != wire.LineageSessionStateNameDeleted {
		t.Fatalf("read again %+v", f)
	}
}
