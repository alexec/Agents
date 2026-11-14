package agentsd

import (
	"encoding/json"
	"strings"
	"syscall"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A chat line the disk refuses is still shown, the clients are told once that the disk is
// full, and the line is on disk after the next disk check (#3245).
func TestALineTheDiskRefusesIsShownToldAndWrittenLater(t *testing.T) {
	d, c := start(t, t.TempDir())
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		title := "Fix the build"
		a.Title = &title
	})
	c.call(t, 1, "presence/report", map[string]any{"active": false, "watching": a.ID})
	restore := store.RefuseWrites(syscall.ENOSPC)
	defer restore()
	d.record(a.ID, runtimeNote("one"))
	d.record(a.ID, runtimeNote("two"))
	got := heard(t, c, 2)
	if len(got["agent/entry"]) != 2 {
		t.Fatalf("held lines not shown: %d", len(got["agent/entry"]))
	}
	failed := got[wire.NotifyStorageWriteFailed.Name]
	if len(failed) != 1 {
		t.Fatalf("told %d times", len(failed))
	}
	var f wire.WriteFailure
	json.Unmarshal(failed[0], &f)
	if f.Cause != wire.WriteFailureCauseDiskFull || !strings.Contains(f.Message, "Fix the build’s chat") {
		t.Fatalf("%+v", f)
	}
	restore()
	d.checkDisk()
	if entries, _, _ := d.Store.Transcript(a.ID, 0); len(entries) != 2 || d.Store.Holding() {
		t.Fatalf("on disk %d after the disk check", len(entries))
	}
	// Space came back, so the next refusal is told again.
	if d.toldRefused.Load() {
		t.Fatal("still marked told")
	}
}
