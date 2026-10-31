package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Ports SkillUpdateRemoveTests and SkillFolderTests' listing: a folder's skills listed,
// the lock's marked as added and the person's own not, and taking one out moves it to the
// root's trash and its lock entry with it, while the person's own is refused.

var lockTime = time.Date(2026, 10, 16, 9, 0, 0, 0, time.UTC)

func TestAFoldersSkillsListedAndOneTakenOut(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	skills := filepath.Join(folder, ".agents", "skills")
	write := func(name, text string) {
		os.MkdirAll(filepath.Join(skills, name), 0o755)
		os.WriteFile(filepath.Join(skills, name, "SKILL.md"), []byte(text), 0o644)
	}
	write("added", "---\nname: added\ndescription: From a catalogue.\n---\n")
	write("mine", "---\nname: mine\n---\n")
	os.MkdirAll(filepath.Join(skills, "not-a-skill"), 0o755)
	hash, _ := skillcatalog.ComputedHash(filepath.Join(skills, "added"))
	lock, _ := skillcatalog.LoadLock(skillcatalog.FolderScope, filepath.Join(folder, "skills-lock.json"))
	lock.Upsert("added", "owner/repo", "skills/added/SKILL.md", hash, lockTime)
	lock.Write()

	dest := map[string]any{"kind": "folder", "folder": folder}
	var list wire.SkillsListAnswer
	json.Unmarshal(c.call(t, 2, "skills/list", map[string]any{"destination": dest}), &list)
	if len(list.Skills) != 2 || list.Skills[0].Name != "added" || *list.Skills[0].Description != "From a catalogue." ||
		list.Skills[0].Managed == nil || list.Skills[0].Managed.Source != "owner/repo" || list.Skills[0].Managed.Edited ||
		list.Skills[1].Name != "mine" || list.Skills[1].Managed != nil {
		t.Fatalf("%+v", list)
	}

	// An edit since it was added shows.
	os.WriteFile(filepath.Join(skills, "added", "notes.md"), []byte("mine now"), 0o644)
	list = wire.SkillsListAnswer{}
	json.Unmarshal(c.call(t, 3, "skills/list", map[string]any{"destination": dest}), &list)
	if !list.Skills[0].Managed.Edited {
		t.Fatalf("%+v", list.Skills[0].Managed)
	}

	e := c.callError(t, 4, "skills/remove", map[string]any{"destination": dest, "name": "mine"})
	var why wire.CatalogError
	b, _ := json.Marshal(e.Data)
	json.Unmarshal(b, &why)
	if e.Code != wire.FailureCatalogRefused || why.NotManaged == nil || e.Message != "mine was not added by the app or the skills tool." {
		t.Fatalf("%+v", e)
	}
	var removed wire.SkillRemoveAnswer
	json.Unmarshal(c.call(t, 5, "skills/remove", map[string]any{"destination": dest, "name": "added"}), &removed)
	if filepath.Dir(removed.TrashedTo) != filepath.Join(d.Store.Loc.Root, "trash") {
		t.Fatal(removed.TrashedTo)
	}
	if _, err := os.Stat(filepath.Join(skills, "added")); !os.IsNotExist(err) {
		t.Fatal("still there")
	}
	if lock, _ := skillcatalog.LoadLock(skillcatalog.FolderScope, filepath.Join(folder, "skills-lock.json")); len(lock.Names()) != 0 {
		t.Fatal(lock.Names())
	}

	// Somewhere that is not a folder, and a root with no personal home, are refused.
	e = c.callError(t, 6, "skills/list", map[string]any{"destination": map[string]any{"kind": "folder", "folder": t.TempDir()}})
	if e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	t.Setenv("AGENTS_PERSONAL_HOME", "")
	if d.personalHome() == "" {
		e = c.callError(t, 7, "skills/list", map[string]any{"destination": map[string]any{"kind": "personal"}})
		if e.Message != "This copy of the app has no personal ~/.agents." {
			t.Fatalf("%+v", e)
		}
	}
}

func TestAFolderPluginWaitsUntilApproved(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	plugins := filepath.Join(folder, ".agents", "plugins")
	os.MkdirAll(filepath.Join(plugins, "old", "hooks"), 0o755)
	os.WriteFile(filepath.Join(plugins, "old", ".mcp.json"), []byte(`{"mcpServers":{"x":{"command":"${CLAUDE_PLUGIN_ROOT}/x"}}}`), 0o644)

	// Present when approval began: approved as it stands, with what it carries.
	var list wire.PluginsList
	json.Unmarshal(c.call(t, 2, "plugins/list", map[string]any{"folder": "file://" + folder}), &list)
	if len(list.Plugins) != 1 || list.Plugins[0].Name != "old" || list.Plugins[0].AwaitingApproval != nil ||
		len(list.Plugins[0].Carries) != 2 || list.Plugins[0].Carries[0] != "hooks" || list.Plugins[0].Carries[1] != "connectors" {
		t.Fatalf("%+v", list)
	}
	gemini, _ := os.ReadFile(filepath.Join(plugins, "old", "gemini-extension.json"))
	if string(gemini) != "{\n  \"description\" : \"\",\n  \"mcpServers\" : {\n    \"x\" : {\n      \"command\" : \"${extensionPath}/x\"\n    }\n  },\n  \"name\" : \"old\",\n  \"version\" : \"0.1.0\"\n}\n" {
		t.Fatal(string(gemini))
	}

	// One that arrives after waits, and one changed after approval waits again.
	os.MkdirAll(filepath.Join(plugins, "new", "skills"), 0o755)
	os.WriteFile(filepath.Join(plugins, "old", "hooks", "run.sh"), []byte("echo hi"), 0o755)
	json.Unmarshal(c.call(t, 3, "plugins/list", map[string]any{"folder": "file://" + folder}), &list)
	if len(list.Plugins) != 2 || list.Plugins[0].Name != "new" || list.Plugins[0].AwaitingApproval == nil ||
		!list.Plugins[0].AwaitingApproval.IsNew || list.Plugins[1].AwaitingApproval == nil || list.Plugins[1].AwaitingApproval.IsNew {
		t.Fatalf("%+v", list)
	}
	waiting := list.Plugins[0]

	if e := c.callError(t, 4, "plugins/approve", map[string]any{"plugin": string(waiting.Folder), "digest": "stale"}); e.Code != wire.FailureNotChanged {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 5, "plugins/approve", map[string]any{"plugin": "file://" + folder, "digest": "x"}); e.Code != CodeInvalidParams {
		t.Fatalf("%+v", e)
	}
	list = wire.PluginsList{}
	json.Unmarshal(c.call(t, 6, "plugins/approve", map[string]any{"plugin": string(waiting.Folder), "digest": waiting.AwaitingApproval.Digest}), &list)
	if list.Plugins[0].AwaitingApproval != nil {
		t.Fatalf("%+v", list.Plugins[0])
	}
	var records pluginApprovals
	b, _ := os.ReadFile(filepath.Join(d.Store.Loc.Root, "plugin-approvals.json"))
	diskjson.Unmarshal(b, &records)
	if records.ApprovalsBegan == nil || records.Approved[filepath.Join(plugins, "new")] != waiting.AwaitingApproval.Digest {
		t.Fatalf("%s", b)
	}
	if _, err := os.Stat(filepath.Join(d.Store.Loc.Root, ".plugin-approvals.json.began")); err != nil {
		t.Fatal(err)
	}
}
