package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// callError is one call that must fail, and its error.
func callError(t *testing.T, c *conn, id int, method string, params any) Error {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	c.in <- string(b)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m struct {
				ID    json.RawMessage `json:"id"`
				Error *Error          `json:"error"`
			}
			json.Unmarshal([]byte(line), &m)
			if string(m.ID) != string(mustJSON(id)) {
				continue
			}
			if m.Error == nil {
				t.Fatalf("%s: no error: %s", method, line)
			}
			return *m.Error
		case <-deadline:
			t.Fatalf("%s: no answer", method)
		}
	}
}

// firstBuild/start (#5056) makes ~/.agents/first-build, adds it as a folder, starts the
// agent there with the host's prompt and the first-build label, and refuses a second while
// the first is not archived, with its id.
func TestFirstBuildStart(t *testing.T) {
	fakeRuntimes(t)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	params := map[string]any{"idea": "  An iPhone app that logs my runs ", "starter": "iphone-app", "runtimeID": "claude"}
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "firstBuild/start", params), &id)

	folder, _ := store.Resolve(filepath.Join(home, ".agents", "first-build"))
	if fi, err := os.Stat(folder); err != nil || !fi.IsDir() {
		t.Fatalf("no folder: %v", err)
	}
	if _, err := os.Stat(filepath.Join(folder, ".git")); err == nil {
		t.Fatal("the folder is a repository")
	}
	a := d.Store.Agent(id)
	if a == nil || store.FolderPath(a.Cwd) != folder {
		t.Fatalf("%+v", a)
	}
	if !slices.ContainsFunc(a.Labels, func(l wire.SessionLabel) bool {
		return l.Value == "first-build" && l.Owner == wire.SessionLabelOwnerPerson
	}) {
		t.Fatalf("labels %+v", a.Labels)
	}
	added := func() int {
		n := 0
		for _, f := range d.Store.Folders() {
			if store.FolderPath(f.Folder) == folder {
				n++
			}
		}
		return n
	}
	if added() != 1 {
		t.Fatalf("added %d times", added())
	}

	// A second Submit, or a second client: refused, with the session it opens instead.
	e := callError(t, c, 2, "firstBuild/start", params)
	if e.Code != wire.FailureFirstBuildRunning {
		t.Fatalf("%+v", e)
	}
	if data, _ := e.Data.(map[string]any); data["agentID"] != string(id) {
		t.Fatalf("data %+v", e.Data)
	}

	// Archived, a new first build starts, in the same folder, added once.
	c.call(t, 3, "agents/archive", map[string]any{"agentID": id})
	var again wire.UUID
	json.Unmarshal(c.call(t, 4, "firstBuild/start", map[string]any{"idea": "A website for my book club",
		"starter": "web-service", "runtimeID": "claude"}), &again)
	if again == "" || again == id || added() != 1 {
		t.Fatalf("again %q, added %d", again, added())
	}

	// New App… (#5132): another first build starts while one is there, in the same folder.
	var another wire.UUID
	json.Unmarshal(c.call(t, 5, "firstBuild/start", map[string]any{"idea": "An iPhone app that logs my runs",
		"starter": "iphone-app", "runtimeID": "claude", "another": true}), &another)
	if another == "" || another == again || added() != 1 || d.Store.Agent(again).ArchivedAt != nil {
		t.Fatalf("another %q, added %d", another, added())
	}
}

// The prompt is the host's, the same from every client (spec 5048 §7).
func TestFirstBuildPrompt(t *testing.T) {
	got := firstBuildPrompt("A website for my book club's reading list", firstBuildKinds[wire.FirstBuildStarterWebService],
		wire.FirstBuildStarterWebService)
	want := "Build my first app with the start-a-new-app skill. The idea: A website for my book club's reading list. " +
		"The kind: Web service; the starter: web-service. Keep the first-build task list as your plan."
	if got != want {
		t.Fatalf("%q", got)
	}
	if firstBuildKinds[wire.FirstBuildStarterIphoneApp] != "iPhone app" {
		t.Fatal(firstBuildKinds[wire.FirstBuildStarterIphoneApp])
	}
}

// An empty idea, a starter that is not one, and no runtime are refused before anything is made.
func TestFirstBuildStartRefusesWhatIsNotAFirstBuild(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	_, c := start(t, t.TempDir())
	for i, p := range []map[string]any{
		{"idea": "  ", "starter": "iphone-app", "runtimeID": "claude"},
		{"idea": "A game", "starter": "android-app", "runtimeID": "claude"},
		{"idea": "A game", "starter": "web-service", "runtimeID": ""},
	} {
		if e := callError(t, c, i+1, "firstBuild/start", p); e.Code != CodeInvalidParams {
			t.Fatalf("%v: %+v", p, e)
		}
	}
	if _, err := os.Stat(filepath.Join(home, ".agents", "first-build")); err == nil {
		t.Fatal("a refused start made the folder")
	}
}

// A scratch root, with no personal home, keeps the folder in the root, never in a home.
func TestFirstBuildOnAScratchRootStaysInTheRoot(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("AGENTS_PERSONAL_HOME", "")
	root := t.TempDir()
	d, c := start(t, root)
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "firstBuild/start", map[string]any{"idea": "An iPhone app that reminds me to water my plants",
		"starter": "iphone-app", "runtimeID": "claude"}), &id)
	want, _ := store.Resolve(filepath.Join(d.Store.Loc.Root, "first-build"))
	if got := store.FolderPath(d.Store.Agent(id).Cwd); got != want {
		t.Fatalf("%s, want %s", got, want)
	}
}
