package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// #2032: a connected server's list views are rows of their own, named by the service.

func TestAServersListViewsShowWithoutAPinAndHide(t *testing.T) {
	var calls atomic.Int32
	server := fakeViewServer(t, &calls)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"ci":{"url":"`+server.URL+`"},
		"local":{"command":"local-server"}}}`), 0o644)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)

	// The first list reads the catalog in the background, then the rows are said.
	var all []wire.FolderPins
	c.call(t, 20, "pins/list", nil)
	c.until(t, "pins/changed with ci's view", func(method string, p json.RawMessage) bool {
		var n wire.PinsChangedNotification
		json.Unmarshal(p, &n)
		return method == "pins/changed" && len(n.Views) == 1
	})
	json.Unmarshal(c.call(t, 2, "pins/list", nil), &all)
	if len(all) != 1 || len(all[0].Pins) != 0 || len(all[0].Views) != 1 {
		t.Fatalf("%+v", all)
	}
	v := all[0].Views[0]
	if v.Title != "ci · Pull requests" || v.Kind != wire.PinKindView || v.Path != "ui://ci/board" || v.View == nil ||
		v.View.Tool != "board" || v.View.Server != "ci" || v.PinnedBy.Kind != wire.PinnerKindServer || v.Hidden != nil {
		t.Fatalf("%+v", v)
	}
	if calls.Load() != 0 {
		t.Fatal("listing the views called a tool")
	}
	// Opened with no pin, its call names no agent: the server's own views say it is of ci.
	if r := c.call(t, 8, "views/call", map[string]any{"agentID": store.NewUUID(), "folder": folder, "viewID": store.NewUUID(),
		"name": "board", "server": "ci", "feed": true}); !strings.Contains(string(r), `"called":"board"`) {
		t.Fatalf("%s", r)
	}

	// Hidden: still listed, marked, and kept in pins.json; shown again.
	c.call(t, 3, "pins/hideView", map[string]any{"folder": folder, "uri": "ui://ci/board", "hidden": true})
	json.Unmarshal(c.call(t, 4, "pins/list", nil), &all)
	if h := all[0].Views[0].Hidden; h == nil || !*h {
		t.Fatalf("%+v", all[0].Views)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "pins.json")); !strings.Contains(string(b), `"hidden_views" : [`) {
		t.Fatalf("%s", b)
	}
	c.call(t, 5, "pins/hideView", map[string]any{"folder": folder, "uri": "ui://ci/board", "hidden": false})
	if _, err := os.Stat(filepath.Join(dir, ".agents", "pins.json")); !os.IsNotExist(err) {
		t.Fatal("an empty pins.json was left")
	}

	// Pinned, it shows as its pin only.
	c.call(t, 6, "pins/pin", map[string]any{"folder": folder, "view": map[string]any{"server": "ci", "uri": "ui://ci/board", "tool": "board"}})
	json.Unmarshal(c.call(t, 7, "pins/list", nil), &all)
	if len(all[0].Pins) != 1 || len(all[0].Views) != 0 {
		t.Fatalf("%+v", all[0])
	}
}

func TestAViewFedByAToolWithRequiredArgumentsIsNoList(t *testing.T) {
	tool := func(name, uri string, required ...string) json.RawMessage {
		b, _ := json.Marshal(map[string]any{"name": name, "_meta": map[string]any{"ui": map[string]any{"resourceUri": uri}},
			"annotations": map[string]any{"readOnlyHint": true}, "inputSchema": map[string]any{"type": "object", "required": required}})
		return b
	}
	c := makeViewCatalog("github", []json.RawMessage{tool("show_pull_requests", "ui://github/pulls"),
		tool("show_pull_request", "ui://github/pr", "number")}, []json.RawMessage{
		json.RawMessage(`{"uri":"ui://github/pulls"}`), json.RawMessage(`{"uri":"ui://github/pr"}`),
	}, nowFunc())
	if c.Version != viewCatalogVersion || c.Tools[0].NeedsArguments || !c.Tools[1].NeedsArguments {
		t.Fatalf("%+v", c)
	}
}

func TestAToolIsNotAViewWhenItsResourceIsNotListed(t *testing.T) {
	tool, _ := json.Marshal(map[string]any{"name": "get_me", "_meta": map[string]any{"ui": map[string]any{
		"resourceUri": "ui://github/profile", "visibility": []string{"model", "app"},
	}}})
	c := makeViewCatalog("github", []json.RawMessage{tool}, nil, nowFunc())
	if got := c.tool("get_me"); got != nil {
		t.Fatalf("unlisted resource made get_me a view: %+v", got)
	}

	resource, _ := json.Marshal(map[string]any{"uri": "ui://github/profile"})
	c = makeViewCatalog("github", []json.RawMessage{tool}, []json.RawMessage{resource}, nowFunc())
	if got := c.tool("get_me"); got == nil || got.ResourceURI != "ui://github/profile" {
		t.Fatalf("listed resource was not attached to the tool: %+v", got)
	}
}

func TestAListViewsName(t *testing.T) {
	linear := &viewCatalog{Resources: []viewResource{{URI: "ui://linear/issues", Title: ptr("Linear issues")}}}
	for _, tc := range []struct {
		catalog *viewCatalog
		uri     string
		server  string
		want    string
	}{
		{linear, "ui://linear/issues", "Linear", "Issues"},
		{&viewCatalog{}, "ui://github/pulls", "GitHub", "Pulls"},
		{&viewCatalog{Resources: []viewResource{{URI: "ui://x/y", Title: ptr("Pull requests")}}}, "ui://x/y", "GitHub", "Pull requests"},
	} {
		if got := listViewTitle(tc.catalog, wire.ViewPin{URI: tc.uri}, tc.server); got != tc.want {
			t.Errorf("%s: %q", tc.uri, got)
		}
	}
}

func TestOurViewsShowWhereTheRepoFits(t *testing.T) {
	for remote, want := range map[string]string{
		"https://github.com/alexec/agents.git": "github.com",
		"git@github.com:alexec/agents.git":     "github.com",
		"ssh://git@GitLab.com:22/a/b.git":      "gitlab.com",
		"https://me:token@git.acme.dev/a/b":    "git.acme.dev",
		"/srv/repos/a.git":                     "",
	} {
		if got := remoteHost(remote); got != want {
			t.Errorf("%s: %q", remote, got)
		}
	}
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:a/b.git\n"), 0o644)
	// A worktree reads the repo's config.
	wt := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git", "worktrees", "w"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "worktrees", "w", "commondir"), []byte("../..\n"), 0o644)
	os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+filepath.Join(dir, ".git", "worktrees", "w")+"\n"), 0o644)
	if originHost(dir) != "github.com" || originHost(wt) != "github.com" || originHost(t.TempDir()) != "" {
		t.Fatal(originHost(dir), originHost(wt))
	}
	github, _ := mcpcatalog.OursByID("agents/github")
	gitlab, _ := mcpcatalog.OursByID("agents/gitlab")
	linear, _ := mcpcatalog.OursByID("agents/linear")
	if !oursFits(github, "github.com") || oursFits(github, "gitlab.com") || oursFits(github, "") ||
		!oursFits(gitlab, "git.acme.dev") || oursFits(gitlab, "github.com") || !oursFits(linear, "") {
		t.Fatal("fits")
	}
}
