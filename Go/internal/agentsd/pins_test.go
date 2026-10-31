package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// Ports PinsTests and DaemonPinsTests: a folder's pins in .agents/pins.json, in the bytes
// the Swift host writes, under its limits and in its words.

func folder(t testing.TB, c *conn, n int) string {
	t.Helper()
	dir := t.TempDir()
	c.call(t, n, "folders/add", map[string]any{"folder": store.FolderURL(dir)})
	return dir
}

func TestPinsAreTheSwiftFile(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.MkdirAll(filepath.Join(dir, "docs"), 0o755)
	os.WriteFile(filepath.Join(dir, "docs", "README.md"), []byte("# hi"), 0o644)
	os.WriteFile(filepath.Join(dir, "plan.md"), []byte("# plan"), 0o644)
	folder := store.FolderURL(dir)
	var views []wire.PinView
	json.Unmarshal(c.call(t, 2, "pins/pin", map[string]any{"folder": folder, "path": "docs/README.md"}), &views)
	if len(views) != 1 || views[0].Title != "docs" || views[0].Kind != wire.PinKindMarkdown || views[0].Missing ||
		views[0].PinnedBy != (wire.PinnerView{Kind: wire.PinnerKindPerson, ID: "", Name: "the person"}) {
		t.Fatalf("%+v", views)
	}
	json.Unmarshal(c.call(t, 3, "pins/pin", map[string]any{"folder": folder, "path": filepath.Join(dir, "plan.md"), "title": "The plan"}), &views)
	b, _ := os.ReadFile(filepath.Join(dir, ".agents", "pins.json"))
	want := `{
  "pins" : [
    {
      "path" : "docs/README.md",
      "pinned_by" : {
        "person" : true
      }
    },
    {
      "path" : "plan.md",
      "pinned_by" : {
        "person" : true
      },
      "title" : "The plan"
    }
  ]
}
`
	if string(b) != want {
		t.Fatalf("pins.json\n%s", b)
	}
	c.call(t, 4, "pins/arrange", map[string]any{"folder": folder, "paths": []string{"plan.md", "nope.md"}})
	if f := d.readPins(dir); f.pins[0].path != "plan.md" || len(f.pins) != 2 {
		t.Fatalf("%+v", f.pins)
	}
	for i, tc := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"folder": folder, "path": "../x.md"}, "Nothing was pinned: ../x.md is not in this folder."},
		{map[string]any{"folder": folder, "path": "gone.md"}, "Nothing was pinned: there is no file at gone.md in the folder."},
		{map[string]any{"folder": folder, "path": "plan.md", "title": strings.Repeat("t", 61)}, "Nothing was pinned: `title` is at most 60 characters."},
		{map[string]any{"folder": store.FolderURL(t.TempDir()), "path": "plan.md"}, ""},
	} {
		e := c.callError(t, 10+i, "pins/pin", tc.params)
		if tc.want != "" && e.Message != tc.want || e.Code != wire.FailurePinRefused {
			t.Fatalf("%d: %+v", i, e)
		}
	}
	os.WriteFile(filepath.Join(dir, "x.txt"), nil, 0o644)
	if e := c.callError(t, 20, "pins/pin", map[string]any{"folder": folder, "path": "x.txt"}); e.Message != "Nothing was pinned: only a Markdown (.md) or HTML (.html) page can be pinned." {
		t.Fatal(e.Message)
	}
	for i := 0; i < 8; i++ {
		name := filepath.Join(dir, strings.Repeat("p", i+1)+".md")
		os.WriteFile(name, nil, 0o644)
		c.call(t, 30+i, "pins/pin", map[string]any{"folder": folder, "path": filepath.Base(name)})
	}
	os.WriteFile(filepath.Join(dir, "eleven.md"), nil, 0o644)
	if e := c.callError(t, 40, "pins/pin", map[string]any{"folder": folder, "path": "eleven.md"}); !strings.Contains(e.Message, "already has 10 pins") {
		t.Fatal(e.Message)
	}
	// Read and typed on, as a page.
	var r wire.FileReading
	json.Unmarshal(c.call(t, 41, "pins/read", map[string]any{"folder": folder, "path": "plan.md"}), &r)
	if r.Text == nil || *r.Text != "# plan" {
		t.Fatalf("%+v", r)
	}
	c.call(t, 42, "pins/write", map[string]any{"folder": folder, "path": "plan.md", "text": "# new"})
	if b, _ := os.ReadFile(filepath.Join(dir, "plan.md")); string(b) != "# new" {
		t.Fatal(string(b))
	}
	if e := c.callError(t, 43, "pins/write", map[string]any{"folder": folder, "path": "x.txt", "text": "x"}); e.Message != "Only a Markdown page can be typed on." {
		t.Fatal(e.Message)
	}
	c.call(t, 44, "pins/unpin", map[string]any{"folder": folder, "path": "plan.md"})
	if e := c.callError(t, 45, "pins/unpin", map[string]any{"folder": folder, "path": "plan.md"}); e.Message != "Nothing was unpinned: plan.md is not pinned in this folder." {
		t.Fatal(e.Message)
	}
	var all []wire.FolderPins
	json.Unmarshal(c.call(t, 46, "pins/list", nil), &all)
	if len(all) != 1 || len(all[0].Pins) != 9 {
		t.Fatalf("%+v", all)
	}
}

// An entry this build cannot read is kept, written back after the rest, and counts.
// A pins.json in the folder before it is a folder is said when it is added (#1622), so a
// window that read pins/list before then shows the pin at once.
func TestPinsThereBeforeTheFolderAreSaidOnAdd(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".agents"), 0o755)
	os.WriteFile(filepath.Join(dir, "plan.md"), []byte("# plan"), 0o644)
	os.WriteFile(filepath.Join(dir, ".agents", "pins.json"),
		[]byte(`{"pins":[{"path":"plan.md","pinned_by":{"person":true}}]}`), 0o644)
	c.in <- `{"jsonrpc":"2.0","id":1,"method":"folders/add","params":{"folder":"` + string(store.FolderURL(dir)) + `"}}`
	c.until(t, "pins/changed with plan.md", func(method string, p json.RawMessage) bool {
		if method != "pins/changed" {
			return false
		}
		var n wire.PinsChangedNotification
		json.Unmarshal(p, &n)
		return len(n.Pins) == 1 && n.Pins[0].Path == "plan.md"
	})
}

func TestAnUnreadPinIsKept(t *testing.T) {
	f, err := readPinsFile([]byte(`{"pins":[{"future":{"x":1},"pinned_by":{"person":true}},{"path":"a.md","pinned_by":{"agent":"A"}},{"path":"a.md","pinned_by":{"person":true}},{"path":"../b.md","pinned_by":{"person":true}}],"sessions":[{"session":"S","pinned_by":{"person":true}},{"session":"S","pinned_by":{"person":true}}]}`))
	if err != nil || len(f.pins) != 1 || len(f.unread) != 1 || len(f.sessions) != 1 {
		t.Fatalf("%+v %v", f, err)
	}
	b, _ := f.data()
	if !strings.Contains(string(b), `"future" : {`) || strings.Index(string(b), `"a.md"`) > strings.Index(string(b), `"future"`) {
		t.Fatalf("%s", b)
	}
}

func TestSessionPinsAndArchive(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	one := seeded(t, d, dir, nil)
	two := seeded(t, d, dir, nil)
	c.call(t, 2, "pins/pinSession", map[string]any{"folder": folder, "agentID": one.ID})
	c.call(t, 3, "pins/pinSession", map[string]any{"folder": folder, "agentID": two.ID})
	c.call(t, 4, "pins/arrangeSessions", map[string]any{"folder": folder, "agentIDs": []wire.UUID{two.ID}})
	if f := d.readPins(dir); len(f.sessions) != 2 || f.sessions[0].Session != two.ID {
		t.Fatalf("%+v", f.sessions)
	}
	other := seeded(t, d, t.TempDir(), nil)
	if e := c.callError(t, 5, "pins/pinSession", map[string]any{"folder": folder, "agentID": other.ID}); e.Message != "Nothing was pinned: that session is not in this folder." {
		t.Fatal(e.Message)
	}
	c.call(t, 6, "agents/archive", map[string]any{"agentID": two.ID})
	if f := d.readPins(dir); len(f.sessions) != 1 || f.sessions[0].Session != one.ID {
		t.Fatalf("archived still pinned %+v", f.sessions)
	}
	c.call(t, 7, "pins/unpinSession", map[string]any{"folder": folder, "agentID": one.ID})
	if _, err := os.Stat(filepath.Join(dir, ".agents", "pins.json")); !os.IsNotExist(err) {
		t.Fatal("an empty pins file was left")
	}
}

func TestPreferencesMergeAndModes(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var got map[string]any
	json.Unmarshal(c.call(t, 1, "preferences/set", map[string]any{"a": 1, "b": "x/y"}), &got)
	got = nil
	json.Unmarshal(c.call(t, 2, "preferences/set", map[string]any{"a": nil, "c": true}), &got)
	if len(got) != 2 || got["b"] != "x/y" || got["c"] != true {
		t.Fatalf("%v", got)
	}
	if b, _ := os.ReadFile(filepath.Join(d.SettingsDir, "display.json")); string(b) != `{"b":"x/y","c":true}` {
		t.Fatalf("%s", b)
	}
	cat := "mode"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.AdvertisedOptions = []wire.ConfigOption{{ID: "permission", Name: "Mode", Type: "select", Category: &cat}}
	})
	c.call(t, 3, "agents/setOption", map[string]any{"agentID": a.ID, "optionID": "permission", "value": "plan"})
	var modes map[string]string
	json.Unmarshal(c.call(t, 4, "modes/remembered", nil), &modes)
	if modes["claude"] != "plan" {
		t.Fatalf("%v", modes)
	}
}

func TestPersonas(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	folder := filepath.Join(dir, ".agents", "personas")
	os.MkdirAll(folder, 0o755)
	os.WriteFile(filepath.Join(folder, "reviewer.md"), []byte("---\nname: Reviewer\ndescription: Reads code\nmodel: opus # the big one\noptions:\n  fast: true\nlabels: [review, Review]\n---\n\nYou review.\n"), 0o644)
	os.WriteFile(filepath.Join(folder, "plain.md"), []byte("Just a prompt"), 0o644)
	os.WriteFile(filepath.Join(folder, "broken.md"), []byte("---\nname: x\n"), 0o644)
	os.WriteFile(filepath.Join(folder, ".hidden.md"), nil, 0o644)
	os.Symlink(filepath.Join(folder, "plain.md"), filepath.Join(folder, "linked.md"))
	var ps []wire.Persona
	json.Unmarshal(c.call(t, 1, "personas/list", map[string]any{"folder": store.FolderURL(dir)}), &ps)
	byID := map[string]wire.Persona{}
	var names []string
	for _, p := range ps {
		byID[p.ID] = p
		names = append(names, p.Name)
	}
	if strings.Join(names, ",") != "broken,linked,plain,Reviewer" {
		t.Fatal(names)
	}
	r := byID["reviewer"]
	if *r.Description != "Reads code" || *r.Settings.Model != "opus" || r.Settings.Options["fast"] != "true" ||
		strings.Join(r.Settings.Labels, ",") != "review" || r.Origin != "folder" {
		t.Fatalf("%+v", r)
	}
	if *byID["broken"].Problem != "The metadata block is never closed" || *byID["linked"].Problem != "This file could not be read" {
		t.Fatalf("%+v %+v", byID["broken"], byID["linked"])
	}
}

func TestPersonaFilesCanBeManagedInEachScope(t *testing.T) {
	personal := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", personal)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folderPath := store.FolderURL(dir)
	content := "---\nname: Review\nfuture-key: keep me\n---\n\nRead carefully.\n"
	c.call(t, 2, "personas/save", map[string]any{"folder": folderPath, "origin": "folder", "id": "review", "content": content})
	var files wire.PersonaFilesAnswer
	json.Unmarshal(c.call(t, 3, "personas/files", map[string]any{"folder": folderPath, "origin": "folder"}), &files)
	if len(files) != 1 || files[0].ID != "review" || files[0].Content != content || files[0].Origin != wire.PersonaOriginFolder {
		t.Fatalf("folder files: %+v", files)
	}
	personalContent := "Plain personal prompt\n"
	c.call(t, 4, "personas/save", map[string]any{"origin": "personal", "id": "review", "content": personalContent})
	json.Unmarshal(c.call(t, 5, "personas/files", map[string]any{"origin": "personal"}), &files)
	if len(files) != 1 || files[0].Content != personalContent || files[0].Origin != wire.PersonaOriginPersonal {
		t.Fatalf("personal files: %+v", files)
	}
	c.call(t, 6, "personas/save", map[string]any{"folder": folderPath, "origin": "folder", "id": "review", "content": content, "delete": true})
	json.Unmarshal(c.call(t, 7, "personas/files", map[string]any{"folder": folderPath, "origin": "folder"}), &files)
	if len(files) != 0 {
		t.Fatalf("deleted folder persona remains: %+v", files)
	}
	if e := c.callError(t, 8, "personas/save", map[string]any{"folder": folderPath, "origin": "folder", "id": "../escape", "content": "x"}); e.Code == 0 {
		t.Fatal("accepted a persona path traversal")
	}
}

func TestTheAppsYAML(t *testing.T) {
	m, err := yamlnode.MappingFrom([]string{"name: \"a: b\"", "on:", "  - schedule:", "      at: \"09:00\"", "days: [mon, 'tue']", "url: http://x#y"})
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := m["name"].Text(); s != "a: b" {
		t.Fatal(s)
	}
	if at, _ := m["on"].Sequence[0].Mapping["schedule"].Mapping["at"].Text(); at != "09:00" {
		t.Fatal(at)
	}
	if v, _ := m["days"].Values(); strings.Join(v, ",") != "mon,tue" {
		t.Fatal(v)
	}
	if s, _ := m["url"].Text(); s != "http://x#y" {
		t.Fatal(s)
	}
	if _, err := yamlnode.MappingFrom([]string{"just words"}); err == nil || err.Error() != `Line 2: "just words" is not a key` {
		t.Fatal(err)
	}
}
