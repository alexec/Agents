package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
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

type noTunnels struct{}

func (noTunnels) OpenTunnel(context.Context, string) (controllink.Conn, error) {
	return nil, errors.New("no tunnels here")
}

// A Mac's own agents use the Mac's own sign-in, even with a control plane to borrow
// through: a Mac host never asks the window for a key (DaemonCore+Credentials, #1138).
func TestAMacHostWantsNoKey(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.Tunneler = noTunnels{}
	t.Setenv("HOME", t.TempDir()) // no ~/.claude/.credentials.json, no ~/.codex/auth.json
	for _, id := range []string{"claude", "codex"} {
		if err := d.needsSignIn(id); err != nil {
			t.Fatalf("%s: %v", id, err)
		}
	}
}
