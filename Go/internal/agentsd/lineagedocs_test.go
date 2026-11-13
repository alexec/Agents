package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

func writeDoc(t *testing.T, root, rel string) string {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("# A doc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// #3308: a read of a doc under specs/ or docs/, in the folder or the session's worktree, and a
// docs page fetched, are reads; a doc's path or a docs page's address said is links-to. A path
// that is not there, a file outside specs/ and docs/, and an address that is not a docs page
// link nothing.
func TestDocsASessionReadsOrLinksTo(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder, worktree := t.TempDir(), t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	writeDoc(t, folder, "docs/how-to/use-jira.md")
	spec := writeDoc(t, worktree, "specs/2348-lineage/spec.md")
	readme := writeDoc(t, folder, "README.md")
	a := seeded(t, d, worktree, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "w", Folder: store.FolderURL(folder)}
	})
	read := "read"
	d.noteDocRead(a.ID, wire.ToolCall{Title: "Read", Kind: &read, Locations: []wire.ToolCallLocation{{Path: spec}, {Path: readme}}})
	d.noteDocRead(a.ID, wire.ToolCall{Title: "notion fetch", RawInput: json.RawMessage(`{"url":"https://www.notion.so/acme/Design-abc123?pvs=4"}`)})
	d.noteDocRead(a.ID, wire.ToolCall{Title: "fetch", RawInput: json.RawMessage(`{"url":"https://example.com/docs/x"}`)})
	d.noteDocLinks(a.ID, "I read docs/how-to/use-jira.md and `specs/missing/spec.md`, and the design at "+
		"https://acme.atlassian.net/wiki/spaces/ENG/pages/12/Design. See https://acme.atlassian.net/browse/ENG-1 too.")

	s := sessionNode(a.ID)
	wantLinks(t, active(d, s),
		s.Ref+" reads github:doc:alexec/agents#specs/2348-lineage/spec.md (agent)",
		s.Ref+" reads web:doc:www.notion.so#/acme/Design-abc123 (agent)",
		s.Ref+" links-to github:doc:alexec/agents#docs/how-to/use-jira.md (agent)",
		s.Ref+" links-to web:doc:acme.atlassian.net#/wiki/spaces/ENG/pages/12/Design (agent)")

	// Archived, its doc links end with the rest.
	if err := d.archive(a.ID); err != nil {
		t.Fatal(err)
	}
	wantLinks(t, active(d, s))
}

// #3308: a folder with no forge names its docs by their path.
func TestADocInAFolderWithNoForge(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {}}
	writeDoc(t, folder, "specs/1-x/spec.md")
	a := seeded(t, d, folder, nil)
	d.noteDocLinks(a.ID, "Per specs/1-x/spec.md.")
	s := sessionNode(a.ID)
	wantLinks(t, active(d, s), s.Ref+" links-to file:doc:#"+filepath.ToSlash(folder)+"/specs/1-x/spec.md (agent)")
}

// #3308: the issue's and the PR's section name the docs its sessions read, and a doc does
// not take the walk on to the other work of the sessions that read it too.
func TestTheLineageSectionNamesTheDocs(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	spec := writeDoc(t, folder, "specs/2348-lineage/spec.md")
	writeDoc(t, folder, "docs/explanation/views.md")
	lane := func(label, title, branch string) wire.Agent {
		a := seeded(t, d, folder, func(a *wire.Agent) {
			a.Title = &title
			a.Worktree = &wire.AgentWorktree{Name: "w", Branch: &branch, Folder: store.FolderURL(folder)}
			a.Labels = []wire.SessionLabel{{Value: label, Owner: wire.SessionLabelOwnerPerson}}
		})
		d.noteLineage(nil, a)
		return a
	}
	a := lane("#7", "Fix the walk", "agents/7-fix")
	other := lane("#8", "Something else", "agents/8-else")
	helper := seeded(t, d, folder, func(h *wire.Agent) { h.StartedByAgent = &a.ID })
	d.noteLineage(nil, helper)
	read := "read"
	call := wire.ToolCall{Title: "Read", Kind: &read, Locations: []wire.ToolCallLocation{{Path: spec}}}
	d.noteDocRead(a.ID, call)
	d.noteDocRead(helper.ID, call)
	d.noteDocLinks(a.ID, "Following docs/explanation/views.md.")
	d.noteDocRead(other.ID, call)
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": `{"pr":{"number":9,"branch":"agents/7-fix",` +
		`"title":"Fix it","url":"https://github.com/alexec/Agents/pull/9","fixes":["#7"]}}`}})
	d.lineageSettle(5 * time.Second)

	node, base, _ := nodeOfURL("https://github.com/alexec/Agents/issues/7")
	v := d.lineageViewOf(node, base)
	if v.Summary != "2 sessions · 1 pull request (1 open) · 2 docs" {
		t.Errorf("summary %q; sessions %+v", v.Summary, v.Sessions)
	}
	docs := map[string]lineageViewNode{}
	for _, n := range v.Docs {
		docs[n.Name] = n
	}
	if n := docs["specs/2348-lineage/spec.md"]; n.URL != "https://github.com/alexec/agents/blob/HEAD/specs/2348-lineage/spec.md" || n.Words != "read by 2 sessions" {
		t.Errorf("spec %+v", n)
	}
	if n := docs["docs/explanation/views.md"]; n.Words != "linked by 1 session" || len(docs) != 2 {
		t.Errorf("docs %+v", v.Docs)
	}

	// Issue 8's session read the spec too; issue 7's section does not name it, through the doc.
	for _, s := range v.Sessions {
		if s.ID == string(other.ID) {
			t.Errorf("issue 8's session on issue 7: %+v", v.Sessions)
		}
	}
	node, base, _ = nodeOfURL("https://github.com/alexec/Agents/issues/8")
	if v := d.lineageViewOf(node, base); v.Summary != "1 session · 0 pull requests · 1 doc" {
		t.Errorf("issue 8 %q", v.Summary)
	}
}

// #3308: a doc's name and address in the section.
func TestDocNameAndURL(t *testing.T) {
	for _, c := range []struct{ ref, base, name, url string }{
		{"github:doc:alexec/agents#specs/1/spec.md", "https://github.com", "specs/1/spec.md", "https://github.com/alexec/agents/blob/HEAD/specs/1/spec.md"},
		{"gitlab:doc:group/sub/project#docs/a.md", "https://git.example.com", "docs/a.md", "https://git.example.com/group/sub/project/-/blob/HEAD/docs/a.md"},
		{"gitlab:doc:group/project#docs/a.md", "", "docs/a.md", "https://gitlab.com/group/project/-/blob/HEAD/docs/a.md"},
		{"forgejo:doc:kim/notes#docs/a.md", "http://localhost:3844", "docs/a.md", "http://localhost:3844/kim/notes/src/HEAD/docs/a.md"},
		{"forgejo:doc:kim/notes#docs/a.md", "", "docs/a.md", ""},
		{"bitbucket:doc:walkalex/app#docs/a.md", "", "docs/a.md", "https://bitbucket.org/walkalex/app/src/HEAD/docs/a.md"},
		{"file:doc:#/Users/me/src/thing/specs/1/spec.md", "", "specs/1/spec.md", ""},
		{"https://www.notion.so/acme/Design-abc123", "", "www.notion.so/acme/Design-abc123", "https://www.notion.so/acme/Design-abc123"},
	} {
		if n, u := docName(c.ref), docURL(c.ref, c.base); n != c.name || u != c.url {
			t.Errorf("%s: %q %q, want %q %q", c.ref, n, u, c.name, c.url)
		}
	}
	for raw, want := range map[string]bool{
		"https://docs.google.com/document/d/abc/edit":         true,
		"https://drive.google.com/file/d/abc":                 true,
		"https://acme.notion.site/Page-1":                     true,
		"https://confluence.example.com/display/ENG/Design":   true,
		"https://acme.atlassian.net/wiki/spaces/ENG/pages/1/": true,
		"https://acme.atlassian.net/browse/ENG-1":             false,
		"https://github.com/alexec/Agents/issues/7":           false,
		"ftp://notion.so/x":                                   false,
	} {
		if _, ok := docsPage(raw); ok != want {
			t.Errorf("%s: %v, want %v", raw, ok, want)
		}
	}
}
