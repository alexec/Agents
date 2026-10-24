package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

func TestLocalConfigClockAdvancesBeforeControlPlaneEcho(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, root)
	defer d.Shutdown()
	path := filepath.Join(home, ".agents", "AGENTS.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(2 * time.Hour)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}
	var requests []wire.AgentConfigFileRequest
	ask := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != "user/setAgentConfigFile" {
			t.Fatalf("unexpected call %s", method)
		}
		requests = append(requests, params.(wire.AgentConfigFileRequest))
		return json.RawMessage(`{}`), nil
	})
	d.askControl.Store(&ask)
	d.syncUserConfigFile("AGENTS.md")
	if err := os.WriteFile(path, []byte("second"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}
	d.syncUserConfigFile("AGENTS.md")
	if len(requests) != 2 || requests[0].Time != requests[1].Time || requests[0].Counter != 0 || requests[1].Counter != 1 {
		t.Fatalf("local HLC did not advance: %+v", requests)
	}
}

func TestConfigSyncDoesNotFollowSymlinks(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, root)
	defer d.Shutdown()
	outside := filepath.Join(t.TempDir(), "private.md")
	if err := os.WriteFile(outside, []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".agents", "personas", "reviewer.md")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	calls := 0
	ask := askControl(func(context.Context, string, any) (json.RawMessage, error) {
		calls++
		return json.RawMessage(`{}`), nil
	})
	d.askControl.Store(&ask)
	d.syncUserConfigFile("personas/reviewer.md")
	if calls != 0 {
		t.Fatal("synced the target of a configuration symlink")
	}
}
