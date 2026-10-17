package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// On a Mac the app's own toolsets are in the root's cache, where the Swift host put them:
// the only copy of Codex, found there.
func TestAMacFindsTheAppsToolsets(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	bin := filepath.Join(d.Store.Loc.Cache, "tools", "codex", "current", "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "codex-acp"), []byte("#!/bin/sh\n"), 0o755)
	var before []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 1, "runtimes/list", nil), &before)
	for _, s := range before {
		if s.Runtime.ID == "codex" && (s.Availability.Missing == nil || len(s.Availability.Missing.LookedIn) != 1 || s.Availability.Missing.LookedIn[0] != bin) {
			t.Fatalf("a toolset with no current/ok is not whole: %+v", s.Availability)
		}
	}
	os.WriteFile(filepath.Join(d.Store.Loc.Cache, "tools", "codex", "current", "ok"), nil, 0o644)
	var after []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 2, "runtimes/list", nil), &after)
	for _, s := range after {
		if s.Runtime.ID == "codex" {
			if s.Availability.Available == nil || s.Availability.Available.Path != filepath.Join(bin, "codex-acp") {
				t.Fatalf("%+v", s.Availability)
			}
			return
		}
	}
	t.Fatal("no codex")
}
