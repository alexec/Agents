package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
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
	// running, notArchived and queued are rules now (#2957, FR-015, #4377): this method
	// keeps them in the folder's own policy layer, reads them back from it, and enforces
	// them (#3149).
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 3, "folders/setHelperLimits", map[string]any{"folder": folder, "limits": map[string]any{"running": 4, "notArchived": 6, "queued": 2, "agentsMayArchive": true}}), &s)
	if l := s.Folder.HelperLimits; l == nil || l.Running == nil || *l.Running != 4 || l.NotArchived == nil || *l.NotArchived != 6 ||
		l.Queued == nil || *l.Queued != 2 || l.AgentsMayArchive != nil {
		t.Fatalf("%+v", s.Folder.HelperLimits)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "policy.json")); string(b) != "{\n  \"helpers\": {\n    \"mostNotArchived\": 6,\n    \"mostQueued\": 2,\n    \"mostRunning\": 4\n  }\n}\n" {
		t.Fatalf("%s", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json")); strings.Contains(string(b), "helperLimits") {
		t.Fatalf("the limits are not written to folder.json any more: %s", b)
	}
	if running, notArchived, queued := d.helperLimitsIn(dir); running != 4 || notArchived != 6 || queued != 2 {
		t.Fatal(running, notArchived, queued)
	}
	if e := c.callError(t, 30, "folders/setHelperLimits", map[string]any{"folder": folder, "limits": map[string]any{"running": 7, "notArchived": 6}}); e.Message != "Running helpers (7) cannot be more than helpers not yet archived (6)." {
		t.Fatal(e.Message)
	}
	// Back to the default: no choice, read back as none.
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 31, "folders/setHelperLimits", map[string]any{"folder": folder, "limits": map[string]any{"notArchived": 6}}), &s)
	if l := s.Folder.HelperLimits; l == nil || l.Running != nil || l.NotArchived == nil || *l.NotArchived != 6 {
		t.Fatalf("%+v", s.Folder.HelperLimits)
	}
	if running, _, queued := d.helperLimitsIn(dir); running != defaultHelpersRunning || queued != defaultHelpersQueued {
		t.Fatal(running, queued)
	}
	if e := c.callError(t, 4, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{"lowPercent": 1, "criticalPercent": 5}}); e.Message != "Critical disk space can't be more than low disk space." {
		t.Fatal(e.Message)
	}
	c.call(t, 5, "folders/setDiskSpace", map[string]any{"folder": folder, "diskSpace": map[string]any{"lowPercent": 30, "criticalPercent": 1}})
	b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json"))
	// The project id that adding the folder wrote (#2317) stays beside them.
	if s.Project == nil || string(b) != "{\n  \"diskSpace\" : {\n    \"lowPercent\" : 30\n  },\n  \"project\" : \""+*s.Project+"\"\n}\n" {
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

// #4506: folderChanged says one folder's summary, the same row folders(true) would make
// for it, not a summary of every folder.
func TestFolderChangedSummaryMatchesFolders(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	root := t.TempDir()
	const n = 4
	records := make([]wire.Folder, n)
	for i := range records {
		dir := filepath.Join(root, fmt.Sprintf("folder-%d", i))
		if err := os.Mkdir(dir, 0o750); err != nil {
			t.Fatal(err)
		}
		records[i] = wire.Folder{Folder: store.FolderURL(dir), AddedAt: now()}
	}
	if err := d.Store.SaveFolders(records); err != nil {
		t.Fatal(err)
	}
	target := store.FolderPath(records[2].Folder)
	var liveID wire.UUID
	for i := range n * 3 {
		dir := store.FolderPath(records[i%n].Folder)
		a := seeded(t, d, dir, nil)
		if dir == target {
			liveID = a.ID
		}
	}
	d.change(liveID, func(a *wire.Agent) { a.Title = nil })
	var got wire.FolderSummary
	c.until(t, "folder/changed", func(method string, params json.RawMessage) bool {
		if method != wire.NotifyFolderChanged.Name {
			return false
		}
		var s wire.FolderSummary
		json.Unmarshal(params, &s)
		if store.FolderPath(s.Folder.Folder) != target {
			return false
		}
		got = s
		return true
	})
	var want wire.FolderSummary
	found := false
	for _, s := range d.folders(true) {
		if store.FolderPath(s.Folder.Folder) == target {
			want, found = s, true
			break
		}
	}
	if !found {
		t.Fatal("folders(true) has no row for the target folder")
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("folder/changed:\n%+v\nfolders(true):\n%+v", got, want)
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
