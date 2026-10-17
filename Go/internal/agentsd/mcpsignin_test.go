package agentsd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports MCPSignInTests: a server that answers 401 is signed in to through its own
// authorization server (metadata, registration, PKCE, the code on loopback, the token),
// its row says so, a session sends its bearer, and signing out takes it away.

func TestSigningInToAnMCPServer(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	var srv *httptest.Server
	var verifierSeen, resourceSeen atomic.Value
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/mcp":
			if r.Header.Get("Authorization") != "Bearer at-1" {
				w.Header().Set("WWW-Authenticate", `Bearer resource_metadata="`+srv.URL+`/.well-known/oauth-protected-resource/mcp"`)
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}`)
		case "/.well-known/oauth-protected-resource/mcp":
			fmt.Fprintf(w, `{"resource":"%s/mcp","authorization_servers":["%s"],"scopes_supported":["read"]}`, srv.URL, srv.URL)
		case "/.well-known/oauth-authorization-server":
			fmt.Fprintf(w, `{"issuer":"%s","authorization_endpoint":"%s/authorize","token_endpoint":"%s/token",
				"registration_endpoint":"%s/register","revocation_endpoint":"%s/revoke","code_challenge_methods_supported":["S256"]}`,
				srv.URL, srv.URL, srv.URL, srv.URL, srv.URL)
		case "/register":
			fmt.Fprint(w, `{"client_id":"c-1"}`)
		case "/token":
			r.ParseForm()
			if r.Form.Get("code") != "the-code" || r.Form.Get("client_id") != "c-1" {
				w.WriteHeader(400)
				fmt.Fprint(w, `{"error":"invalid_request","error_description":"bad code"}`)
				return
			}
			verifierSeen.Store(r.Form.Get("code_verifier"))
			resourceSeen.Store(r.Form.Get("resource"))
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600}`)
		case "/revoke":
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"remote":{"type":"http","url":"`+srv.URL+`/mcp"}}}`), 0o644)
	personal := map[string]any{"kind": "personal"}

	// The list asks it once, and it wants a sign-in.
	var list wire.MCPListAnswer
	json.Unmarshal(c.call(t, 1, "mcp/list", map[string]any{"destination": personal}), &list)
	if len(list.Servers) != 1 || list.Servers[0].SignIn == nil || *list.Servers[0].SignIn != wire.MCPSignInStateNeedsSignIn {
		t.Fatalf("%+v", list)
	}

	target := map[string]any{"entry": map[string]any{"destination": personal, "name": "remote"}}
	var started wire.MCPSignInAnswer
	json.Unmarshal(c.call(t, 2, "mcp/sign-in", map[string]any{"target": target}), &started)
	if started.Error != nil || started.FlowID == nil || started.AuthorizationURL == nil {
		t.Fatalf("%+v", started)
	}
	page, _ := url.Parse(*started.AuthorizationURL)
	q := page.Query()
	if page.Path != "/authorize" || q.Get("client_id") != "c-1" || q.Get("code_challenge_method") != "S256" ||
		q.Get("resource") != srv.URL+"/mcp" || q.Get("scope") != "read" {
		t.Fatal(*started.AuthorizationURL)
	}
	// The browser comes back: a stranger's state is refused, then the right one is taken.
	if res, err := http.Get(q.Get("redirect_uri") + "?code=x&state=wrong"); err != nil || res.StatusCode != 400 {
		t.Fatal(err, res.StatusCode)
	}
	done := make(chan string, 1)
	go func() {
		res, err := http.Get(q.Get("redirect_uri") + "?code=the-code&state=" + q.Get("state"))
		if err != nil {
			done <- err.Error()
			return
		}
		b := make([]byte, 4096)
		n, _ := res.Body.Read(b)
		done <- string(b[:n])
	}()
	var waited wire.MCPSignInWaitAnswer
	json.Unmarshal(c.call(t, 3, "mcp/sign-in/wait", map[string]any{"flowID": started.FlowID}), &waited)
	if waited.Status.SignedIn == nil {
		t.Fatalf("%+v", waited.Status)
	}
	if body := <-done; !strings.Contains(body, "Signed in to remote") {
		t.Fatal(body)
	}
	if v, _ := verifierSeen.Load().(string); len(v) != 43 {
		t.Fatal(v)
	}
	if r, _ := resourceSeen.Load().(string); r != srv.URL+"/mcp" {
		t.Fatal(r)
	}
	kept, _ := os.ReadFile(filepath.Join(home, ".agents-secrets", "mcp-sign-ins.json"))
	if info, _ := os.Stat(filepath.Join(home, ".agents-secrets", "mcp-sign-ins.json")); !strings.Contains(string(kept), `"access": "at-1"`) || info.Mode().Perm() != 0o600 {
		t.Fatal(string(kept))
	}

	list = wire.MCPListAnswer{}
	json.Unmarshal(c.call(t, 4, "mcp/list", map[string]any{"destination": personal}), &list)
	if *list.Servers[0].SignIn != wire.MCPSignInStateSignedIn {
		t.Fatalf("%+v", list)
	}
	servers := d.sessionMCP(t.TempDir())
	if len(servers) != 1 || servers[0].Http == nil || servers[0].Http.Headers[len(servers[0].Http.Headers)-1].Value != "Bearer at-1" {
		t.Fatalf("%+v", servers)
	}

	var out wire.MCPSignOutAnswer
	json.Unmarshal(c.call(t, 5, "mcp/sign-out", map[string]any{"target": target}), &out)
	list = wire.MCPListAnswer{}
	json.Unmarshal(c.call(t, 6, "mcp/list", map[string]any{"destination": personal}), &list)
	if out.Error != nil || *list.Servers[0].SignIn != wire.MCPSignInStateNeedsSignIn {
		t.Fatalf("%+v %+v", out, list)
	}
	// A session leaves out a server that needs a sign-in.
	if servers := d.sessionMCP(t.TempDir()); len(servers) != 0 {
		t.Fatalf("%+v", servers)
	}
}
