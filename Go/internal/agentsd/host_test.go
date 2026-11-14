package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Ports what CatchUpTests, DiskSpaceTests, DropboxTests and ArtifactTests hold of a server.

func TestCatchUpIsOneAnswer(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	seeded(t, d, dir, nil)
	os.WriteFile(filepath.Join(dir, "a.md"), nil, 0o644)
	c.call(t, 2, "pins/pin", map[string]any{"folder": store.FolderURL(dir), "path": "a.md"})
	var s map[string]json.RawMessage
	json.Unmarshal(c.call(t, 3, "client/catchUp", map[string]any{"parts": []string{"pins", "someday"}}), &s)
	for _, k := range []string{"folders", "agents", "permissions", "elicitations", "attention", "resuming", "disk", "storeNotes", "achievements", "pins"} {
		if _, ok := s[k]; !ok {
			t.Fatalf("no %s in %v", k, s)
		}
	}
	var agents []wire.Agent
	json.Unmarshal(s["agents"], &agents)
	var pins []wire.FolderPins
	json.Unmarshal(s["pins"], &pins)
	if len(agents) != 1 || len(pins) != 1 {
		t.Fatalf("%d agents, %d pins", len(agents), len(pins))
	}
	// Asked for nothing: the lists of a first page, and no pins.
	s = nil
	json.Unmarshal(c.call(t, 4, "client/catchUp", nil), &s)
	if _, ok := s["pins"]; ok {
		t.Fatal("pins not asked for")
	}
	var status wire.DaemonStatus
	json.Unmarshal(c.call(t, 5, "daemon/status", nil), &status)
	if status != (wire.DaemonStatus{}) {
		t.Fatalf("%+v", status)
	}
}

func TestDiskLevelsTakeAMarginToGetBetter(t *testing.T) {
	const g = gigabyte
	low, critical := int64(20*g), int64(2*g)
	steps := []struct {
		free int64
		want wire.DiskLevel
	}{{30 * g, "ok"}, {19 * g, "low"}, {1 * g, "critical"}, {5 * g / 2, "critical"}, {3 * g, "low"}, {21 * g, "low"}, {22 * g, "ok"}}
	var level wire.DiskLevel
	for i, s := range steps {
		if level = nextDiskLevel(level, s.free, low, critical); level != s.want {
			t.Fatalf("%d: %s at %d GB, want %s", i, level, s.free/g, s.want)
		}
	}
	if defaultDiskThresholds.lowLine(1000*g) != 100*g || defaultDiskThresholds.criticalLine(1000*g) != 10*g {
		t.Fatal("the lines are a percent of the disk: 10% low, 1% critical")
	}
}

func TestSettingsTheWindowReads(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	os.MkdirAll(d.SettingsDir, 0o700)
	os.WriteFile(filepath.Join(d.SettingsDir, "sandbox.json"), []byte(`{"defaults":{"claude":"off","codex":"runtime","x":"maybe"}}`), 0o600)
	os.WriteFile(filepath.Join(d.SettingsDir, "client-permissions.json"), []byte(`{"cursor":"autoReview","grok":"what"}`), 0o600)
	os.WriteFile(filepath.Join(d.SettingsDir, "retention.json"), []byte(`{"keepFor":"days7"}`), 0o600)
	var sb wire.SandboxSettings
	json.Unmarshal(c.call(t, 1, "sandbox/state", nil), &sb)
	if len(sb.Defaults) != 1 || sb.Defaults["claude"] != "off" {
		t.Fatalf("%+v", sb)
	}
	var cp wire.ClientPermissionSettings
	json.Unmarshal(c.call(t, 2, "clientPermissions/state", nil), &cp)
	if cp.Cursor != "alwaysApprove" || cp.Grok != "default" || cp.Opencode != "default" {
		t.Fatalf("%+v", cp)
	}
	archived := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		at := now()
		by := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedAt, a.ArchivedReason = wire.AgentStateArchived, &at, &by
	})
	var r wire.RetentionState
	json.Unmarshal(c.call(t, 3, "retention/state", nil), &r)
	if r.Settings.KeepFor != "days7" || r.ArchivedCount != 1 || r.ArchivedBytes == 0 {
		t.Fatalf("%+v (%s)", r, archived.ID)
	}
}

func TestADropBoxAndAnArtifact(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	var put wire.DropboxPutResponse
	json.Unmarshal(c.call(t, 2, "dropbox/put", map[string]any{"folder": store.FolderURL(dir), "subfolder": "in/box",
		"name": "../note.txt", "data": "aGk="}), &put)
	real, _ := store.Resolve(dir)
	if put.Path != filepath.Join(real, ".agents", "dropbox", "in", "box", "note.txt") {
		t.Fatal(put.Path)
	}
	if b, _ := os.ReadFile(put.Path); string(b) != "hi" {
		t.Fatal(string(b))
	}
	for i, tc := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"folder": store.FolderURL(t.TempDir()), "name": "x", "data": ""}, "That is not a folder here."},
		{map[string]any{"folder": store.FolderURL(dir), "name": ".x", "data": ""}, "A drop box file needs a name that does not start with a dot."},
		{map[string]any{"folder": store.FolderURL(dir), "subfolder": "a/.b", "name": "x", "data": ""}, "A folder in the drop box cannot start with a dot."},
	} {
		if e := c.callError(t, 10+i, "dropbox/put", tc.params); e.Message != tc.want {
			t.Fatalf("%d: %s", i, e.Message)
		}
	}
	// #3648: a put that takes the drop box past its total is refused; the file the put
	// would replace does not count. A sparse file holds the bytes without the disk.
	big := filepath.Join(real, ".agents", "dropbox", "big.bin")
	if f, err := os.Create(big); err != nil || f.Truncate(dropboxTotal-1) != nil || f.Close() != nil {
		t.Fatal(err)
	}
	if e := c.callError(t, 30, "dropbox/put", map[string]any{"folder": store.FolderURL(dir), "name": "more.txt", "data": "aGk="}); !strings.HasPrefix(e.Message, "The drop box is full") {
		t.Fatal(e.Message)
	}
	c.call(t, 31, "dropbox/put", map[string]any{"folder": store.FolderURL(dir), "name": "big.bin", "data": "aGk="})
	// What a cut-off put left goes after a day; a person's own dot file stays.
	stale := filepath.Join(real, ".agents", "dropbox", ".x.1234abcd.part")
	kept := filepath.Join(real, ".agents", "dropbox", ".mine")
	writeFile(t, stale, "x")
	writeFile(t, kept, "x")
	old := time.Now().Add(-48 * time.Hour)
	os.Chtimes(stale, old, old)
	os.Chtimes(kept, old, old)
	d.sweepDropboxParts()
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("a day-old .part stayed")
	}
	if _, err := os.Stat(kept); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, dir, nil)
	path := filepath.Join(dir, "new", "page.md")
	c.call(t, 20, "artifact/write", map[string]any{"agentID": a.ID, "path": path, "text": "# hi"})
	if b, _ := os.ReadFile(path); string(b) != "# hi" {
		t.Fatal(string(b))
	}
	if e := c.callError(t, 21, "artifact/write", map[string]any{"agentID": a.ID, "path": "/etc/x", "text": ""}); !strings.HasPrefix(e.Message, "Outside this agent's folders (") {
		t.Fatal(e.Message)
	}
	if e := c.callError(t, 22, "artifact/write", map[string]any{"agentID": a.ID, "path": "rel.md", "text": ""}); e.Message != "The path has to be absolute, starting at `/`." {
		t.Fatal(e.Message)
	}
	// With a base (#1858): written over the text the edit began from, refused over any other.
	c.call(t, 23, "artifact/write", map[string]any{"agentID": a.ID, "path": path, "text": "# mine", "base": textDigest("# hi")})
	os.WriteFile(path, []byte("# an agent's"), 0o644)
	e := c.callError(t, 24, "artifact/write", map[string]any{"agentID": a.ID, "path": path, "text": "# mine again", "base": textDigest("# mine")})
	if e == nil || e.Code != wire.FailureFileChanged {
		t.Fatalf("written over a change made since: %+v", e)
	}
	if b, _ := os.ReadFile(path); string(b) != "# an agent's" {
		t.Fatal(string(b))
	}
}
