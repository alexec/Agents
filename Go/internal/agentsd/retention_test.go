package agentsd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

func TestRetentionDeletesOldArchivedAgents(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	dir := folder(t, c, 1)
	byUser := wire.AgentArchivedReasonByUser
	archived := func(ago time.Duration) wire.Agent {
		return seeded(t, d, dir, func(a *wire.Agent) {
			at := wire.DateOf(clock.now().Add(-ago))
			a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &at, &byUser
		})
	}
	old := archived(31 * 24 * time.Hour)
	recent := archived(29 * 24 * time.Hour)
	noTime := seeded(t, d, dir, func(a *wire.Agent) {
		a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
	})
	live := seeded(t, d, dir, func(a *wire.Agent) {
		at := wire.DateOf(clock.now().Add(-100 * 24 * time.Hour))
		a.ArchivedAt = &at // not archived: a stale time is not enough
	})
	// A pin made while it was finished, then archived outside the app: kept.
	pinned := seeded(t, d, dir, nil)
	c.call(t, 2, "pins/pinSession", map[string]any{"folder": store.FolderURL(dir), "agentID": pinned.ID})
	at := wire.DateOf(clock.now().Add(-60 * 24 * time.Hour))
	pinned.State, pinned.ArchivedAt, pinned.ArchivedReason = wire.AgentStateArchived, &at, &byUser
	if err := d.Store.Save(pinned); err != nil {
		t.Fatal(err)
	}

	// The default is 30 days.
	if n := d.sweepArchived(); n != 1 || d.Store.Agent(old.ID) != nil {
		t.Fatalf("deleted %d, old still there: %v", n, d.Store.Agent(old.ID) != nil)
	}
	if _, err := os.Stat(filepath.Join(root, "agents", string(old.ID))); !os.IsNotExist(err) {
		t.Fatalf("folder left: %v", err)
	}
	for _, id := range []wire.UUID{recent.ID, noTime.ID, live.ID, pinned.ID} {
		if d.Store.Agent(id) == nil {
			t.Fatalf("%s was deleted", id)
		}
	}

	if a := d.Store.Agent(noTime.ID); a.ArchivedAt == nil || *a.ArchivedAt != wire.DateOf(clock.now()) {
		t.Fatalf("no archive time stamped: %+v", a.ArchivedAt)
	}

	// Forever deletes nothing, however old.
	os.MkdirAll(d.SettingsDir, 0o700)
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"forever"}`), 0o600)
	clock.add(365 * 24 * time.Hour)
	if n := d.sweepArchived(); n != 0 || d.Store.Agent(recent.ID) == nil {
		t.Fatalf("forever deleted %d", n)
	}

	// Seven days: the recent one goes too; a value this build cannot read is 30 days.
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"days7"}`), 0o600)
	clock.set(time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	if n := d.sweepArchived(); n != 1 || d.Store.Agent(recent.ID) != nil || d.Store.Agent(pinned.ID) == nil || d.Store.Agent(noTime.ID) == nil {
		t.Fatalf("days7 deleted %d", n)
	}
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"days1000"}`), 0o600)
	if d.keepFor() != wire.RetentionKeepForDays30 {
		t.Fatal(d.keepFor())
	}
}
