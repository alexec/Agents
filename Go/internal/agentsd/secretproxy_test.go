package agentsd

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4120: an http MCP server whose header names a secret with Ask before use reaches its server
// through agentsd. The runtime's config has agentsd's route and token, never the value; the
// first request asks a person and is not held; once they allow it, agentsd adds the value on
// each request, and the session's runtime starts again so it connects. A stdio server with a
// flagged ${NAME} is left out.
func TestAnHTTPServerGetsAFlaggedSecretThroughAgentsd(t *testing.T) {
	const value = "s3cret-token-4120"
	var mu sync.Mutex
	var seen []http.Header
	var seenQuery []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Header.Clone())
		seenQuery = append(seenQuery, r.URL.RawQuery)
		mu.Unlock()
		io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Mcp-Session-Id", "upstream-session")
		io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"notes"}}}`)
	}))
	defer upstream.Close()

	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	path := skillcatalog.SecretsPath(home)
	os.MkdirAll(filepath.Dir(path), 0o700)
	env, _ := skillcatalog.LoadSecretsForChange(path)
	env.Set("PLAIN_KEY", "plain")
	if err := env.Save(path); err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(home, ".agents"), 0o700)
	mcp := `{"mcpServers":{
		"notes":{"url":"` + upstream.URL + `/mcp?k=${PLAIN_KEY}","headers":{"Authorization":"Bearer ${API_TOKEN}"}},
		"local":{"command":"notes-mcp","env":{"TOKEN":"${API_TOKEN}"}}}}`
	if err := os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(mcp), 0o600); err != nil {
		t.Fatal(err)
	}
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	// As main does before it accepts a connection (#5070, as #4857 did for the fill tests):
	// your policy's first read makes the first-start move, which writes person-key and
	// settings/policy-yours.json into the root. Read lazily, it ran on whichever goroutine
	// asked first, under load as late as the root's TempDir removal ("directory not empty").
	d.WarmYourPolicy()
	if err := d.saveSecret("API_TOKEN", value, true); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), nil)

	servers := d.mcpServersFor(a.ID)
	b, _ := json.Marshal(servers)
	if strings.Contains(string(b), value) || strings.Contains(string(b), "notes-mcp") {
		t.Fatalf("the runtime's config has the value or the stdio server: %s", b)
	}
	var route, token string
	for _, s := range servers {
		if s.Http != nil && s.Http.Name == "notes" {
			route, token = s.Http.Url, bearer(s.Http.Headers[0].Value)
		}
	}
	if !strings.HasPrefix(route, "http://127.0.0.1:") || !strings.Contains(route, secretProxyPathPrefix) || token == "" {
		t.Fatalf("notes is not agentsd's route: %s", b)
	}
	post := func(tok string) (*http.Response, string) {
		req, _ := http.NewRequest(http.MethodPost, route, strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`))
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Content-Type", "application/json")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		return res, string(body)
	}

	// Another token does not reach the route.
	if res, _ := post("not-the-token"); res.StatusCode != http.StatusNotFound {
		t.Fatal(res.Status)
	}

	// The first request asks, and is refused at once with the request to wait on.
	before := d.warmKey(d.Store.Agent(a.ID))
	_, body := post(token)
	r := openSecretUse(t, d)
	if u := r.Detail.SecretUse; u.Use != wire.SecretUseMCP || u.Place != "notes" || u.Name != "API_TOKEN" || r.Title != "Send API_TOKEN to the MCP server notes" {
		t.Fatalf("%+v", r)
	}
	if !strings.Contains(body, `"error"`) || !strings.Contains(body, string(r.ID)) || strings.Contains(body, value) {
		t.Fatal(body)
	}
	mu.Lock()
	if len(seen) != 0 {
		t.Fatal("a refused request reached the server")
	}
	mu.Unlock()

	// Allowed for the session: the runtime starts again at its next turn, and each request
	// has the value, never agentsd's token.
	answerUse(t, d, r, secretUseSession)
	if d.warmKey(d.Store.Agent(a.ID)) == before {
		t.Fatal("the runtime would not start again to connect")
	}
	res, body := post(token)
	if res.StatusCode != http.StatusOK || !strings.Contains(body, `"serverInfo"`) || res.Header.Get("Mcp-Session-Id") != "upstream-session" {
		t.Fatal(res.Status, body)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 1 || seen[0].Get("Authorization") != "Bearer "+value || seenQuery[0] != "k=plain" {
		t.Fatalf("%v %v", seen, seenQuery)
	}

	// A start with no session (a preview) leaves the server out.
	for _, s := range d.sessionMCP(t.TempDir()) {
		if s.Http != nil && s.Http.Name == "notes" {
			t.Fatal("notes was given with no session to ask for")
		}
	}
}

// #4120: a person's deny holds for the route, so a runtime that tries again does not ask again.
func TestADeniedServerDoesNotAskAgain(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"),
		[]byte(`{"mcpServers":{"notes":{"url":"https://notes.example.com/${API_TOKEN}"}}}`), 0o600)
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	// As above: the first-start move before the test, not during its cleanup (#5070).
	d.WarmYourPolicy()
	if err := d.saveSecret("API_TOKEN", "v4120", true); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), nil)
	var p *secretProxy
	d.mcpServersFor(a.ID)
	d.secretProxyMu.Lock()
	for _, x := range d.secretProxies {
		p = x
	}
	d.secretProxyMu.Unlock()
	if p == nil || len(p.flagged) != 1 || p.flagged[0] != "API_TOKEN" {
		t.Fatalf("%+v", p)
	}
	if _, words := d.secretProxyValues(p); words == "" {
		t.Fatal("not asked")
	}
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)
	if _, words := d.secretProxyValues(p); !strings.Contains(words, "A person denied the use of API_TOKEN at notes") {
		t.Fatal(words)
	}
	for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
		if r.Detail.SecretUse != nil {
			t.Fatal("asked again after a deny")
		}
	}
	// A new start takes the old routes away.
	d.dropAppTokens(a.ID)
	d.secretProxyMu.Lock()
	defer d.secretProxyMu.Unlock()
	if len(d.secretProxies) != 0 {
		t.Fatal("a route outlived its token")
	}
}
