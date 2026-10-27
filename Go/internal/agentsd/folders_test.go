package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports FolderArchiveTests, FolderDeleteTests, HelperLimitTests, DiskSpaceTests,
// FolderDetectionTests and GitRemoteTests for a server.

func TestArchiveUnarchiveAndDeleteAFolder(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	working := seeded(t, d, dir, func(a *wire.Agent) {
		title := "Busy"
		a.State, a.EndedReason, a.Title = wire.AgentStateRunning, nil, &title
	})
	if e := c.callError(t, 2, "folders/archive", map[string]any{"folder": folder}); e.Code != wire.FailureFolderHasLiveAgents || e.Message != "Stop these first: Busy." {
		t.Fatalf("%+v", e)
	}
	d.change(working.ID, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonCancelled)
	})
	if e := c.callError(t, 3, "folders/delete", map[string]any{"folder": folder}); e.Message != "Only an archived folder can be deleted. Archive it first." {
		t.Fatal(e.Message)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 4, "folders/archive", map[string]any{"folder": folder}), &s)
	if s.Folder.ArchivedAt == nil {
		t.Fatalf("%+v", s.Folder)
	}
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 5, "folders/unarchive", map[string]any{"folder": folder}), &s)
	if s.Folder.ArchivedAt != nil {
		t.Fatal("still archived")
	}
	c.call(t, 6, "folders/archive", map[string]any{"folder": folder})
	c.in <- `{"jsonrpc":"2.0","id":7,"method":"folders/delete","params":{"folder":"` + string(folder) + `"}}`
	c.until(t, "folder/removed", func(method string, _ json.RawMessage) bool { return method == "folder/removed" })
	if d.Store.Agent(working.ID) != nil || len(d.Store.Folders()) != 0 || !isDir(dir) {
		t.Fatal("not deleted, or its folder went too")
	}
}

func TestAFoldersSettingsAreItsFile(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	if e := c.callError(t, 2, "folders/setHelperLimits", map[string]any{"folder": folder, "limits": map[string]any{"running": 6, "notArchived": 4}}); e.Message != "Running helpers (6) cannot be more than helpers not yet archived (4)." {
		t.Fatal(e.Message)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 3, "folders/setHelperLimits", map[string]any{"folder": folder, "limits": map[string]any{"running": 4, "agentsMayArchive": true}}), &s)
	if s.Folder.HelperLimits == nil || *s.Folder.HelperLimits.Running != 4 || s.Folder.HelperLimits.AgentsMayArchive != nil {
		t.Fatalf("%+v", s.Folder.HelperLimits)
	}
	if e := c.callError(t, 4, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{"lowGB": 1, "criticalGB": 5}}); e.Message != "Critical disk space can't be more than low disk space." {
		t.Fatal(e.Message)
	}
	c.call(t, 5, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{"lowGB": 50, "criticalGB": 2}})
	b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json"))
	// The project id that adding the folder wrote (#2317) stays beside them.
	if s.Project == nil || string(b) != "{\n  \"diskSpace\" : {\n    \"lowGB\" : 50\n  },\n  \"helperLimits\" : {\n    \"running\" : 4\n  },\n  \"project\" : \""+*s.Project+"\"\n}\n" {
		t.Fatalf("%s", b)
	}
	os.WriteFile(filepath.Join(dir, ".agents", "folder.json"), []byte("[1]"), 0o644)
	if e := c.callError(t, 6, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{}}); !strings.HasPrefix(e.Message, ".agents/folder.json is not a JSON object") {
		t.Fatal(e.Message)
	}
	json.Unmarshal(c.call(t, 7, "folders/setPinned", map[string]any{"folder": folder, "pinned": true}), &s)
	if s.Folder.Pinned == nil || !*s.Folder.Pinned {
		t.Fatal("not pinned")
	}
}

func TestFindingFolders(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	parent := t.TempDir()
	for _, n := range []string{"b", "a", ".hidden", "plain"} {
		os.MkdirAll(filepath.Join(parent, n), 0o755)
		if n != "plain" {
			os.MkdirAll(filepath.Join(parent, n, ".git"), 0o755)
		}
	}
	var found []wire.FoundFolder
	json.Unmarshal(c.call(t, 1, "folders/find", map[string]any{"paths": []string{parent}, "folders": []string{filepath.Join(parent, "plain"), " "}}), &found)
	if len(found) != 3 || !strings.HasSuffix(string(found[0].Folder), "/a") || found[2].Typed == nil || found[2].IsRepository || !found[2].Exists {
		t.Fatalf("%+v", found)
	}
}

// #2134: no chat folder. A host with a personal home lists only the folders added.
func TestNoChatFolder(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.PersonalHome = t.TempDir()
	var ps []wire.FolderSummary
	json.Unmarshal(c.call(t, 1, "folders/list", map[string]any{}), &ps)
	if len(ps) != 0 {
		t.Fatalf("%+v", ps)
	}
	if _, err := os.Stat(filepath.Join(d.PersonalHome, ".agents", "chat")); !os.IsNotExist(err) {
		t.Fatalf("~/.agents/chat made: %v", err)
	}
}

func TestGitAddresses(t *testing.T) {
	for url, want := range map[string]string{
		"https://github.com/alexec/Agents.git": "github.com/alexec/agents",
		"git@github.com:alexec/Agents.git":     "github.com/alexec/agents",
		"ssh://git@example.com:22/x/y":         "example.com:22/x/y",
	} {
		r, ok := parseRemote(url)
		if !ok || r.identity() != want {
			t.Errorf("%s: %v %q", url, ok, r.identity())
		}
	}
	for _, bad := range []string{"-x", "/local/path", "https://machine/", "a b"} {
		if _, ok := parseRemote(bad); ok {
			t.Errorf("%q read as an address", bad)
		}
	}
	r, _ := parseRemote("https://github.com/alexec/x")
	if cloneFailure(r, "fatal: repository 'x' not found\n") != "Could not clone github.com/alexec/x: repository 'x' not found" ||
		!strings.HasPrefix(cloneFailure(r, "Could not resolve host: github.com"), "Could not reach github.com.") {
		t.Fatal(cloneFailure(r, "fatal: repository 'x' not found\n"))
	}
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	if e := c.callError(t, 1, "folders/clone", map[string]any{"url": "nope"}); e.Code != wire.FailureNotACloneURL {
		t.Fatalf("%+v", e)
	}
}
