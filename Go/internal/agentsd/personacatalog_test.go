package agentsd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A persona from a marketplace (#3665): Anthropic's skills repository, as the provided
// GitHub marketplace names it, served with a personas/ folder at two commits.

const (
	personaCommit = "1111111111111111111111111111111111111111"
	personaNext   = "2222222222222222222222222222222222222222"
)

var personaFiles = map[string]string{
	personaCommit: "---\nname: Reviewer\ndescription: Reads a change.\nruntime: codex\npermission-mode: read-only\n---\n\nYou review changes.\n",
	personaNext:   "---\nname: Reviewer\ndescription: Reads a change.\nruntime: claude\npermission-mode: bypass\n---\n\nYou review changes, and fix them.\n",
}

func servePersonas(t *testing.T) *atomic.Bool {
	t.Helper()
	moved := &atomic.Bool{}
	head := func() string {
		if moved.Load() {
			return personaNext
		}
		return personaCommit
	}
	repo := "/anthropics/skills"
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case p == repo+".git/info/refs":
			w.Write([]byte("001e# service=git-upload-pack\n0000" + "00a0" + head() + " HEAD\x00multi_ack symref=HEAD:refs/heads/main\n"))
		case strings.HasPrefix(p, "/api/repos"+repo+"/git/trees/"):
			commit := strings.TrimPrefix(p, "/api/repos"+repo+"/git/trees/")
			text, ok := personaFiles[commit]
			if !ok {
				http.NotFound(w, r)
				return
			}
			size := int64(len(text))
			json.NewEncoder(w).Encode(map[string]any{"tree": []skillcatalog.TreeEntry{
				{Path: "personas", Mode: "040000", Type: "tree", SHA: "aaaa"},
				{Path: "personas/reviewer.md", Mode: "100644", Type: "blob", SHA: skillcatalog.BlobSHA([]byte(text)), Size: &size},
				{Path: "personas/notes/deep.md", Mode: "100644", Type: "blob", SHA: "bbbb"},
				{Path: "skills/x/SKILL.md", Mode: "100644", Type: "blob", SHA: "cccc"},
			}})
		case strings.HasPrefix(p, "/raw"+repo+"/"):
			commit, rel, _ := strings.Cut(strings.TrimPrefix(p, "/raw"+repo+"/"), "/")
			if text, ok := personaFiles[commit]; ok && rel == "personas/reviewer.md" {
				w.Write([]byte(text))
				return
			}
			http.NotFound(w, r)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(github.Close)
	t.Setenv(skillcatalog.GitHubVariable, github.URL)
	return moved
}

func TestAPersonaSearchedPreviewedAddedUpdatedAndRemoved(t *testing.T) {
	moved := servePersonas(t)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	personal := map[string]any{"kind": "personal"}
	market := "provided:anthropic-skills"

	var found wire.CatalogSearchAnswer
	json.Unmarshal(c.call(t, 1, "personas/search", map[string]any{"query": "", "marketplace": market}), &found)
	if found.Error != nil || len(found.Results) != 1 || found.Results[0].SkillID != "reviewer" ||
		*found.Results[0].SkillPath != "personas/reviewer.md" {
		t.Fatalf("%+v", found)
	}

	var preview wire.PersonaPreviewAnswer
	json.Unmarshal(c.call(t, 2, "personas/preview", map[string]any{"result": found.Results[0], "destination": personal}), &preview)
	p := preview.Preview
	if preview.Error != nil || p == nil || p.Markdown != personaFiles[personaCommit] || p.Persona.ID != "reviewer" ||
		p.Persona.Name != "Reviewer" || *p.Persona.Settings.RuntimeID != "codex" || p.DestinationState.Free == nil {
		t.Fatalf("%+v %+v", preview.Error, p)
	}
	var added wire.PersonaAddAnswer
	json.Unmarshal(c.call(t, 3, "personas/add", map[string]any{"previewID": p.PreviewID, "destination": personal, "replace": false}), &added)
	file := filepath.Join(home, ".agents", "personas", "reviewer.md")
	if b, _ := os.ReadFile(file); string(b) != personaFiles[personaCommit] || added.Persona.ID != "reviewer" {
		t.Fatalf("%q %+v", b, added)
	}
	lock, _ := skillcatalog.LoadLock(skillcatalog.Personal, filepath.Join(home, ".agents", ".skill-lock.json"))
	if e, ok := lock.Persona("reviewer"); !ok || e.Source != "anthropics/skills" || e.Commit != personaCommit || len(lock.Names()) != 0 {
		t.Fatalf("%+v %v", e, lock.Names())
	}

	var updates wire.SkillUpdatesAnswer
	json.Unmarshal(c.call(t, 4, "personas/check-updates", map[string]any{"destination": personal}), &updates)
	if updates.Updates["reviewer"].Current == nil {
		t.Fatalf("%+v", updates)
	}

	// The source moves on and changes the runtime and the permission mode.
	moved.Store(true)
	d.catalog().updates = &skillcatalog.UpdateCache{}
	json.Unmarshal(c.call(t, 5, "personas/check-updates", map[string]any{"destination": personal}), &updates)
	if a := updates.Updates["reviewer"].Available; a == nil || a.Commit != personaNext {
		t.Fatalf("%+v", updates)
	}
	// Nothing changes until the person says so.
	if b, _ := os.ReadFile(file); string(b) != personaFiles[personaCommit] {
		t.Fatal("updated without asking")
	}
	var update wire.PersonaUpdatePreviewAnswer
	json.Unmarshal(c.call(t, 6, "personas/update-preview", map[string]any{"destination": personal, "name": "reviewer"}), &update)
	if update.Installed != personaFiles[personaCommit] || update.Edited || len(update.Changes) != 2 ||
		update.Changes[0].Key != "runtime" || *update.Changes[0].Old != "codex" || *update.Changes[0].New != "claude" ||
		update.Changes[1].Key != "permission-mode" || *update.Changes[1].New != "bypass" ||
		update.Preview.DestinationState.SameSkill == nil || !update.Preview.DestinationState.SameSkill.Update {
		t.Fatalf("%+v", update)
	}
	json.Unmarshal(c.call(t, 7, "personas/add", map[string]any{"previewID": update.Preview.PreviewID, "destination": personal, "replace": true}), &added)
	if b, _ := os.ReadFile(file); string(b) != personaFiles[personaNext] {
		t.Fatalf("%q", b)
	}
	if trashed, _ := filepath.Glob(filepath.Join(root, "trash", "reviewer.md-*")); len(trashed) != 1 {
		t.Fatalf("old copy not in the Trash: %v", trashed)
	}

	// Edited after it was added: said so.
	os.WriteFile(file, []byte(personaFiles[personaNext]+"\nMine.\n"), 0o644)
	var managed wire.PersonasManagedAnswer
	json.Unmarshal(c.call(t, 8, "personas/managed", map[string]any{"destination": personal}), &managed)
	if len(managed.Personas) != 1 || !managed.Personas[0].Edited {
		t.Fatalf("%+v", managed)
	}

	// A persona the person made is never removed, and never replaced.
	os.WriteFile(filepath.Join(home, ".agents", "personas", "mine.md"), []byte("Mine."), 0o644)
	if e := c.callError(t, 9, "personas/remove", map[string]any{"destination": personal, "name": "mine"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	var removed wire.SkillRemoveAnswer
	json.Unmarshal(c.call(t, 10, "personas/remove", map[string]any{"destination": personal, "name": "reviewer"}), &removed)
	if _, err := os.Stat(file); !os.IsNotExist(err) || !strings.Contains(removed.TrashedTo, filepath.Join(root, "trash")) {
		t.Fatalf("%v %+v", err, removed)
	}
	lock, _ = skillcatalog.LoadLock(skillcatalog.Personal, filepath.Join(home, ".agents", ".skill-lock.json"))
	if _, ok := lock.Persona("reviewer"); ok {
		t.Fatal("still in the lock")
	}
	os.WriteFile(file, []byte("Mine too."), 0o644)
	json.Unmarshal(c.call(t, 11, "personas/preview", map[string]any{"result": found.Results[0], "destination": personal}), &preview)
	if preview.Preview.DestinationState.Unmanaged == nil {
		t.Fatalf("%+v", preview.Preview.DestinationState)
	}
	if e := c.callError(t, 12, "personas/add", map[string]any{"previewID": preview.Preview.PreviewID, "destination": personal, "replace": true}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
}
