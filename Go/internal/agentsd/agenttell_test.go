package agentsd

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// tellDaemon is a daemon with n finished agents in one folder, and their ids.
func tellDaemon(t *testing.T, n int) (*Daemon, []wire.UUID) {
	t.Helper()
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Shutdown)
	folder := store.FolderURL(t.TempDir())
	ids := make([]wire.UUID, n)
	for i := range ids {
		a := wire.Agent{ID: store.NewUUID(), RuntimeID: "claude", Cwd: folder, State: wire.AgentStateFinished,
			EndedReason: reason(wire.EndedReasonEndTurn), AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
			StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}}, CreatedAt: now(), LastActivityAt: now()}
		if err := d.Store.Save(a); err != nil {
			t.Fatal(err)
		}
		ids[i] = a.ID
	}
	return d, ids
}

// A slow tell for one session does not hold another session's change (#4509): agentMu
// covers only the save.
func TestASlowTellDoesNotHoldAnotherSessionsChange(t *testing.T) {
	d, ids := tellDaemon(t, 2)
	slow, other := ids[0], ids[1]
	held, release := make(chan struct{}), make(chan struct{})
	d.changeTold = func(a wire.Agent) {
		if a.ID == slow {
			close(held)
			<-release
		}
	}
	slowDone := make(chan struct{})
	go func() {
		defer close(slowDone)
		d.change(slow, func(a *wire.Agent) {})
	}()
	<-held
	done := make(chan *wire.Agent)
	go func() { done <- d.change(other, func(a *wire.Agent) { title := "moved"; a.Title = &title }) }()
	select {
	case a := <-done:
		if a == nil || a.Title == nil || *a.Title != "moved" {
			t.Fatalf("the other change: %+v", a)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the other session's change waited on the slow tell")
	}
	// Nor does the slow one hold agentMu for the other users of the store.
	d.stampArchived(other)
	close(release)
	<-slowDone
}

// One agent's changes are told in the order they were saved, also when the tells race
// (#4509).
func TestOneAgentsChangesAreToldInOrder(t *testing.T) {
	d, ids := tellDaemon(t, 1)
	id := ids[0]
	var mu sync.Mutex
	var told []int
	d.changeTold = func(a wire.Agent) {
		n, _ := strconv.Atoi(*a.Title)
		// The first tells are slow, so a later save would overtake them without the lock.
		if n%4 == 0 {
			time.Sleep(time.Millisecond)
		}
		mu.Lock()
		told = append(told, n)
		mu.Unlock()
	}
	saved := 0 // under agentMu, in the edit
	var wg sync.WaitGroup
	for range 64 {
		wg.Go(func() {
			d.change(id, func(a *wire.Agent) {
				saved++
				title := fmt.Sprint(saved)
				a.Title = &title
			})
		})
	}
	wg.Wait()
	if len(told) != 64 {
		t.Fatalf("told %d changes, want 64", len(told))
	}
	for i, n := range told {
		if n != i+1 {
			t.Fatalf("told out of order: %v", told)
		}
	}
	d.agentTellMu.Lock()
	defer d.agentTellMu.Unlock()
	if len(d.agentTells) != 0 {
		t.Fatalf("%d tell locks kept after the changes", len(d.agentTells))
	}
}
