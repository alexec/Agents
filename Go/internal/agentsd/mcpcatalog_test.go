package agentsd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Ports MCPPreviewAndAddTests, MCPFolderTests and MCPRemoveSecretTests: a server found in
// a registry, previewed and added to a folder with its secret, listed approved; a
// hand-written one waits until approved; taking one out keeps a secret another still names.

const registryServer = `{"name":"io.github.acme/weather","title":"Weather","description":"Forecasts.","version":"1.2.0",
 "remotes":[{"type":"streamable-http","url":"https://api.githubcopilot.com/weather","headers":[
   {"name":"Authorization","description":"A GitHub token","isRequired":true,"isSecret":true}]}]}`

func serveRegistry(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v0.1/servers" && r.URL.Query().Get("search") == "weather":
			w.Write([]byte(`{"servers":[{"server":` + registryServer + `}]}`))
		case r.URL.EscapedPath() == "/v0.1/servers/io.github.acme%2Fweather/versions/latest":
			w.Write([]byte(`{"server":` + registryServer + `}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	t.Setenv(skillcatalog.RegistryVariable, srv.URL)
}

func TestAnMCPServerFoundAddedListedAndRemoved(t *testing.T) {
	serveRegistry(t)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	dest := map[string]any{"kind": "folder", "folder": folder}

	var found wire.MCPSearchAnswer
	json.Unmarshal(c.call(t, 2, "catalog/search", map[string]any{"query": "weather", "kind": "mcp"}), &found)
	if found.Error != nil || len(found.Results) != 1 || found.Results[0].Title != "Weather" ||
		found.Results[0].Publisher.Label != "acme on GitHub" || found.Results[0].Runs[0] != wire.MCPRunKindRemote ||
		*found.Results[0].Marketplace != "provided:github-mcp" {
		t.Fatalf("%+v", found)
	}

	var preview wire.MCPPreviewAnswer
	json.Unmarshal(c.call(t, 3, "mcp/preview", map[string]any{"result": found.Results[0], "destination": dest}), &preview)
	p := preview.Preview
	if preview.Error != nil || p.NameHere != "weather" || p.ChosenRun != wire.MCPRunKindRemote || p.DestinationState.Free == nil ||
		*p.Host != "api.githubcopilot.com · the publisher's own" || len(p.Variables) != 1 || p.Variables[0].Name != "GITHUB_TOKEN" {
		t.Fatalf("%+v %+v", preview.Error, p)
	}
	if e := c.callError(t, 4, "mcp/add", map[string]any{"previewID": p.PreviewID, "destination": dest, "secrets": map[string]any{},
		"plain": map[string]any{}, "replace": false}); !strings.Contains(e.Message, "GITHUB_TOKEN is required.") {
		t.Fatalf("%+v", e)
	}
	json.Unmarshal(c.call(t, 5, "mcp/preview", map[string]any{"result": found.Results[0], "destination": dest}), &preview)
	var added wire.MCPAddAnswer
	json.Unmarshal(c.call(t, 6, "mcp/add", map[string]any{"previewID": preview.Preview.PreviewID, "destination": dest,
		"secrets": map[string]any{"GITHUB_TOKEN": "ghp_x"}, "plain": map[string]any{}, "replace": false}), &added)
	if added.Server == nil || added.Server.Name != "weather" || added.Server.RegistryName != "io.github.acme/weather" {
		t.Fatalf("%+v", added)
	}
	file, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json"))
	if string(file) != "{\n  \"mcpServers\": {\n    \"weather\": {\n      \"type\": \"http\",\n      \"url\": \"https://api.githubcopilot.com/weather\",\n      \"headers\": {\n        \"Authorization\": \"Bearer ${GITHUB_TOKEN}\"\n      }\n    }\n  }\n}\n" {
		t.Fatal(string(file))
	}

	// A hand-written server beside it waits for approval; the one the sheet wrote does not.
	os.WriteFile(filepath.Join(folder, ".agents", "mcp.json"), []byte(strings.Replace(string(file), "\"mcpServers\": {\n",
		"\"mcpServers\": {\n    \"mine\": {\"command\": \"my-server\", \"args\": [\"--key\", \"${GITHUB_TOKEN}\"]},\n", 1)), 0o644)
	var list wire.MCPListAnswer
	json.Unmarshal(c.call(t, 7, "mcp/list", map[string]any{"destination": dest}), &list)
	if len(list.Servers) != 2 || list.Servers[0].Name != "mine" || list.Servers[0].Approval.Waiting == nil ||
		!list.Servers[0].Approval.Waiting.IsNew || list.Servers[0].Summary != "my-server --key ${GITHUB_TOKEN}" ||
		list.Servers[1].Approval.Approved == nil || list.Servers[1].Managed == nil || len(list.Servers[1].MissingSecrets) != 0 {
		t.Fatalf("%+v", list)
	}
	if e := c.callError(t, 8, "mcp/approve", map[string]any{"destination": dest, "name": "mine", "digest": "stale"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	list = wire.MCPListAnswer{}
	json.Unmarshal(c.call(t, 9, "mcp/approve", map[string]any{"destination": dest, "name": "mine",
		"digest": list0Digest(t, c, dest)}), &list)
	if list.Servers[0].Approval.Approved == nil || list.Servers[1].Approval.Approved == nil {
		t.Fatalf("%+v", list)
	}
	// The folder's pinned pages are said again: one of the server's waited for this (#1780).
	c.until(t, "pins/changed after mcp/approve", func(method string, _ json.RawMessage) bool { return method == "pins/changed" })

	// A secret another names stays; a server that is not there is refused.
	if e := c.callError(t, 10, "mcp/remove", map[string]any{"destination": dest, "name": "nobody"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 11, "mcp/remove", map[string]any{"destination": dest, "name": "weather", "forgetSecret": "GITHUB_TOKEN"}); !strings.Contains(e.Message, "still named by another server") {
		t.Fatalf("%+v", e)
	}
	c.call(t, 12, "mcp/remove", map[string]any{"destination": dest, "name": "weather"})
	if _, ok, _ := mcpEntryAt(filepath.Join(folder, ".agents", "mcp.json"), "weather"); ok {
		t.Fatal("still there")
	}

	var set wire.MCPSetSecretAnswer
	json.Unmarshal(c.call(t, 13, "mcp/set-secret", map[string]any{"name": "OTHER", "value": "v"}), &set)
	secrets, _ := os.ReadFile(filepath.Join(home, ".agents-secrets", "secrets.env"))
	if !set.Set || string(secrets) != "GITHUB_TOKEN=ghp_x\nOTHER=v\n" {
		t.Fatalf("%q", secrets)
	}
	if e := c.callError(t, 14, "mcp/set-secret", map[string]any{"name": "no good", "value": "v"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	c.call(t, 15, "mcp/forgetViews", map[string]any{"destination": dest, "name": "mine"})

	// A hand-written server is removed too (#2154), and the rest of the file stays as it was.
	path := filepath.Join(folder, ".agents", "mcp.json")
	os.WriteFile(path, []byte("{\n  \"note\": \"kept\",\n  \"mcpServers\": {\n    \"mine\": {\"command\": \"my-server\"},\n    \"theirs\": {\"command\": \"their-server\"}\n  }\n}\n"), 0o644)
	c.call(t, 16, "mcp/remove", map[string]any{"destination": dest, "name": "mine"})
	if _, ok, _ := mcpEntryAt(path, "mine"); ok {
		t.Fatal("the hand-written one is still there")
	}
	if left, _ := os.ReadFile(path); !strings.Contains(string(left), `"note": "kept"`) || !strings.Contains(string(left), `"theirs"`) {
		t.Fatal(string(left))
	}
}

// A personal entry removed is kept in ~/.agents/mcp.removed.json (#2195): that file is in no git.
func TestARemovedPersonalServerIsKept(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {"mine": {"command": "my-server", "args": ["--fast"]}, "theirs": {"command": "x"}}}`), 0o644)
	c.call(t, 1, "mcp/remove", map[string]any{"destination": map[string]any{"kind": "personal"}, "name": "mine"})
	kept := filepath.Join(home, ".agents", "mcp.removed.json")
	e, ok, _ := mcpEntryAt(kept, "mine")
	if !ok {
		t.Fatal("no copy kept")
	}
	if m, _ := e.(map[string]any); m["command"] != "my-server" {
		t.Fatalf("%+v", e)
	}
	if info, _ := os.Stat(kept); info.Mode().Perm() != 0o600 {
		t.Fatal(info.Mode())
	}
	if _, ok, _ := mcpEntryAt(filepath.Join(home, ".agents", "mcp.json"), "mine"); ok {
		t.Fatal("still there")
	}
}

func list0Digest(t *testing.T, c *conn, dest map[string]any) string {
	var list wire.MCPListAnswer
	json.Unmarshal(c.call(t, 98, "mcp/list", map[string]any{"destination": dest}), &list)
	return list.Servers[0].Approval.Waiting.Digest
}

func mcpEntryAt(path, name string) (any, bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, false, err
	}
	var f struct {
		MCPServers map[string]any `json:"mcpServers"`
	}
	json.Unmarshal(b, &f)
	e, ok := f.MCPServers[name]
	return e, ok, nil
}

// Ports MCPAddByHandTests: a server typed on the sheet is connected to before anything is
// written, then written as it answered, its secret to secrets.env.
func TestAnMCPServerTypedVerifiedAndAdded(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	personal := map[string]any{"kind": "personal"}

	local := map[string]any{"name": "fake", "kind": "command", "command": self, "args": []string{"--x"},
		"env": []map[string]any{{"name": "TOKEN", "value": "t0p", "secret": true}}, "url": "", "headers": []any{}}
	var v wire.MCPVerifyAnswer
	json.Unmarshal(c.call(t, 1, "mcp/verify", map[string]any{"destination": personal, "server": local}), &v)
	if v.Error != nil || v.Outcome == nil || v.Outcome.Answered == nil || *v.Outcome.Answered.ServerName != "fake" ||
		strings.Join(v.Outcome.Answered.Tools, ",") != "a,b" || v.VerifyID == nil || string(v.Entry["env"]) != `{"TOKEN":"${TOKEN}"}` {
		t.Fatalf("%+v %+v %s", v.Error, v.Outcome, v.Entry["env"])
	}
	var added wire.MCPAddAnswer
	json.Unmarshal(c.call(t, 2, "mcp/add-by-hand", map[string]any{"verifyID": v.VerifyID, "destination": personal}), &added)
	if added.Server == nil || added.Server.Run != wire.MCPRunKindCommand || !*added.Server.ByHand {
		t.Fatalf("%+v", added)
	}
	if secrets, _ := os.ReadFile(filepath.Join(home, ".agents-secrets", "secrets.env")); string(secrets) != "TOKEN=t0p\n" {
		t.Fatalf("%q", secrets)
	}
	// The name is taken now.
	json.Unmarshal(c.call(t, 3, "mcp/verify", map[string]any{"destination": personal, "server": local}), &v)
	if v.Error == nil || v.Error.NameTaken == nil {
		t.Fatalf("%+v", v)
	}

	web := fakeHTTPMCP(t)
	remote := map[string]any{"name": "web", "kind": "url", "command": "", "args": []string{}, "env": []any{}, "url": web.URL, "headers": []any{}}
	v = wire.MCPVerifyAnswer{}
	json.Unmarshal(c.call(t, 4, "mcp/verify", map[string]any{"destination": personal, "server": remote}), &v)
	if v.Outcome == nil || v.Outcome.Answered == nil || strings.Join(v.Outcome.Answered.Tools, ",") != "only" {
		t.Fatalf("%+v", v)
	}

	locked := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusUnauthorized) }))
	defer locked.Close()
	remote["name"], remote["url"] = "locked", locked.URL
	v = wire.MCPVerifyAnswer{}
	json.Unmarshal(c.call(t, 5, "mcp/verify", map[string]any{"destination": personal, "server": remote}), &v)
	if v.Outcome == nil || v.Outcome.AuthRequired == nil || v.VerifyID != nil {
		t.Fatalf("%+v", v)
	}
	remote["headers"] = []map[string]any{{"name": "Authorization", "value": "Bearer x", "secret": false}}
	v = wire.MCPVerifyAnswer{}
	json.Unmarshal(c.call(t, 6, "mcp/verify", map[string]any{"destination": personal, "server": remote}), &v)
	if v.Outcome == nil || v.Outcome.Failed == nil || v.Outcome.Failed.Value != "It refused the Authorization header it was sent (HTTP 401)." {
		t.Fatalf("%+v", v)
	}
	bad := map[string]any{"name": "-no", "kind": "command", "command": "x", "args": []string{}, "env": []any{}, "url": "", "headers": []any{}}
	v = wire.MCPVerifyAnswer{}
	json.Unmarshal(c.call(t, 7, "mcp/verify", map[string]any{"destination": personal, "server": bad}), &v)
	if v.Error == nil || v.Error.Invalid == nil {
		t.Fatalf("%+v", v)
	}
}

// Ours are rows of the Agents marketplace, a file inside agentsd, with their levels and no
// mark of their own, and added as any connector is: hosted (#1428, #2155).
func TestOursAreListedAndAddedLikeAnyConnector(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	dest := map[string]any{"kind": "folder", "folder": folder}

	var ours wire.MCPSearchAnswer
	json.Unmarshal(c.call(t, 2, "catalog/search", map[string]any{"query": "", "kind": "mcp", "marketplace": "provided:agents"}), &ours)
	if len(ours.Results) != 4 || ours.Results[0].Title != "GitHub" || ours.Results[1].Title != "Linear" || ours.Results[2].Title != "GitLab" ||
		ours.Results[3].Title != "Email" {
		t.Fatalf("%+v", ours)
	}
	github, linear := ours.Results[0], ours.Results[1]
	if github.Publisher.Label != "Agents" || deref(github.Marketplace) != "provided:agents" || *github.Levels != (wire.MCPLevels{Tools: true, Events: true, Views: true, Workflows: true, Tested: true}) {
		t.Fatalf("github: %+v", github)
	}
	if *linear.Levels != (wire.MCPLevels{Tools: true, Events: true, Views: true, Workflows: true, Tested: true}) {
		t.Fatalf("linear: %+v", linear.Levels)
	}

	var preview wire.MCPPreviewAnswer
	json.Unmarshal(c.call(t, 3, "mcp/preview", map[string]any{"result": linear, "destination": dest}), &preview)
	p := preview.Preview
	// No key to ask for: it reads the person's Linear connection (#1343).
	if preview.Error != nil || p.NameHere != "linear" || p.ChosenRun != wire.MCPRunKindCommand || len(p.Variables) != 0 ||
		p.DestinationState.Free == nil {
		t.Fatalf("%+v %+v", preview.Error, p)
	}
	var added wire.MCPAddAnswer
	json.Unmarshal(c.call(t, 4, "mcp/add", map[string]any{"previewID": p.PreviewID, "destination": dest,
		"secrets": map[string]any{}, "plain": map[string]any{}, "replace": false}), &added)
	if added.Server == nil || added.Server.RegistryName != "agents/linear" {
		t.Fatalf("%+v", added)
	}
	file, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json"))
	if !strings.Contains(string(file), `"command": "linear-mcp"`) || !strings.Contains(string(file), `"hosted": true`) ||
		strings.Contains(string(file), "LINEAR_API_KEY") {
		t.Fatal(string(file))
	}
	// Its row on the folder's Connectors page is hosted, as any hosted connector's.
	var snap wire.MCPHealthSnapshot
	json.Unmarshal(c.call(t, 5, "mcp/health", nil), &snap)
	for _, h := range snap.Servers {
		if h.Name == "linear" && !h.Hosted {
			t.Fatalf("%+v", h)
		}
	}
	// Words typed narrow it.
	json.Unmarshal(c.call(t, 6, "catalog/search", map[string]any{"query": "merge requests", "kind": "mcp", "marketplace": "provided:agents"}), &ours)
	if len(ours.Results) != 1 || ours.Results[0].ID != "agents/gitlab" {
		t.Fatalf("%+v", ours.Results)
	}
}

// A person's marketplace can be a file (#2155): the registry's shape, searched and added with no
// network; a command in its _meta is not read, so it cannot run one.
func TestAFileMarketplaceIsSearchedAndAdded(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	os.MkdirAll(filepath.Join(home, "team"), 0o755)
	os.WriteFile(filepath.Join(home, "team", "connectors.json"), []byte(`{"servers": [
	  {"server": {"name": "io.github.acme/tickets", "title": "Tickets", "description": "Acme's tickets",
	    "remotes": [{"type": "streamable-http", "url": "https://mcp.acme.example/mcp"}]}},
	  {"server": {"name": "io.github.acme/sneaky", "description": "runs anything"},
	    "_meta": {"dev.agentloops/connector": {"command": "github-mcp", "hosted": true}}}]}`), 0o644)
	if e := c.callError(t, 1, "marketplaces/add", map[string]any{"name": "Acme", "format": "file", "url": "https://x"}); e == nil ||
		!strings.Contains(e.Message, "is a path") {
		t.Fatalf("%+v", e)
	}
	c.call(t, 2, "marketplaces/add", map[string]any{"name": "Acme", "format": "file", "url": "~/team/connectors.json"})
	id := "personal:~/team/connectors.json"
	var found wire.MCPSearchAnswer
	json.Unmarshal(c.call(t, 3, "catalog/search", map[string]any{"query": "", "kind": "mcp", "marketplace": id}), &found)
	if found.Error != nil || len(found.Results) != 2 || found.Results[0].Title != "Tickets" || found.Results[1].Levels != nil {
		t.Fatalf("%+v", found)
	}
	personal := map[string]any{"kind": "personal"}
	var preview wire.MCPPreviewAnswer
	json.Unmarshal(c.call(t, 4, "mcp/preview", map[string]any{"result": found.Results[0], "destination": personal}), &preview)
	if preview.Error != nil || preview.Preview.CommandOrURL != "https://mcp.acme.example/mcp" {
		t.Fatalf("%+v %+v", preview.Error, preview.Preview)
	}
	json.Unmarshal(c.call(t, 5, "mcp/preview", map[string]any{"result": found.Results[1], "destination": personal}), &preview)
	if preview.Error == nil {
		t.Fatalf("a command in a person's file was read: %+v", preview.Preview)
	}
}
