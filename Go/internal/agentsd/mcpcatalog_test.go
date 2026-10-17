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

// Ports MCPPreviewAndAddTests, MCPProjectTests and MCPRemoveSecretTests: a server found in
// a registry, previewed and added to a project with its secret, listed approved; a
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
	project := t.TempDir()
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})
	dest := map[string]any{"kind": "project", "folder": project}

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
	file, _ := os.ReadFile(filepath.Join(project, ".agents", "mcp.json"))
	if string(file) != "{\n  \"mcpServers\": {\n    \"weather\": {\n      \"type\": \"http\",\n      \"url\": \"https://api.githubcopilot.com/weather\",\n      \"headers\": {\n        \"Authorization\": \"Bearer ${GITHUB_TOKEN}\"\n      }\n    }\n  }\n}\n" {
		t.Fatal(string(file))
	}

	// A hand-written server beside it waits for approval; the one the sheet wrote does not.
	os.WriteFile(filepath.Join(project, ".agents", "mcp.json"), []byte(strings.Replace(string(file), "\"mcpServers\": {\n",
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

	// A hand-written server is not the app's to remove, and a secret another names stays.
	if e := c.callError(t, 10, "mcp/remove", map[string]any{"destination": dest, "name": "mine"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 11, "mcp/remove", map[string]any{"destination": dest, "name": "weather", "forgetSecret": "GITHUB_TOKEN"}); !strings.Contains(e.Message, "still named by another server") {
		t.Fatalf("%+v", e)
	}
	c.call(t, 12, "mcp/remove", map[string]any{"destination": dest, "name": "weather"})
	if _, ok, _ := mcpEntryAt(filepath.Join(project, ".agents", "mcp.json"), "weather"); ok {
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
