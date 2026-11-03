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

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// toServer sends every request to srv, whatever its host: api.atlassian.com, in a test.
type toServer struct{ srv *httptest.Server }

func (t toServer) RoundTrip(r *http.Request) (*http.Response, error) {
	u, _ := url.Parse(t.srv.URL)
	r = r.Clone(r.Context())
	r.URL.Scheme, r.URL.Host, r.Host = u.Scheme, u.Host, u.Host
	return t.srv.Client().Transport.RoundTrip(r)
}

// fakeAtlassian is Atlassian's token endpoint, /me, the accessible sites, and one Jira site's
// myself and search. It keeps the last token request's body and Authorization header.
func fakeAtlassian(t *testing.T, body, auth *atomic.Value) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		auth.Store(r.Header.Get("Authorization"))
		switch {
		case r.URL.Path == "/oauth/token":
			var b map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			body.Store(b)
			fmt.Fprint(w, `{"access_token":"atl_oauth_secret","expires_in":3600,"refresh_token":"atl_refresh_secret"}`)
		case r.URL.Path == "/me":
			fmt.Fprint(w, `{"name":"Alex","email":"a@example.com"}`)
		case r.URL.Path == "/oauth/token/accessible-resources":
			fmt.Fprint(w, `[{"id":"conf-only","name":"Wiki","url":"https://wiki.atlassian.net","scopes":["read:confluence-content.all"]},`+
				`{"id":"cloud-1","name":"Agents Walk","url":"https://agentswalk.atlassian.net/","scopes":["read:jira-work"]}]`)
		case strings.HasSuffix(r.URL.Path, "/rest/api/2/myself"):
			fmt.Fprint(w, `{"accountId":"5b10","displayName":"Alex C","emailAddress":"a@example.com"}`)
		case strings.HasSuffix(r.URL.Path, "/rest/api/2/search/jql") || strings.HasSuffix(r.URL.Path, "/rest/api/2/search"):
			auth.Store(r.URL.Path + " " + r.Header.Get("Authorization"))
			fmt.Fprint(w, `{"issues":[{"id":"10001","key":"WALK-7","fields":{"summary":"Newest one","created":"2026-11-01T09:30:00.000+0000"}}]}`)
		default:
			http.NotFound(w, r)
		}
	}))
}

// Connect Jira by Atlassian's sign-in (#3304): the code flow with the app's client secret,
// which the host reads from the person's secrets, never a client; the site with Jira is kept
// with its cloud id; the answer proves the connection with the newest issue.
func TestConnectingJiraWithAtlassianSignIn(t *testing.T) {
	var body, auth atomic.Value
	atl := fakeAtlassian(t, &body, &auth)
	defer atl.Close()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	t.Setenv("AGENTS_ATLASSIAN_CLIENT_ID", "")
	t.Setenv("AGENTS_ATLASSIAN_CLIENT_SECRET", "")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.jiraHTTP = &http.Client{Transport: toServer{atl}}

	// No app in the secrets: the sign-in does not start, and says to use a token.
	if why := c.callErr(t, 1, "connections/sign-in", map[string]any{"provider": "atlassian"}); !strings.Contains(why, "API token") {
		t.Fatalf("no app: %q", why)
	}
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"), []byte("ATLASSIAN_CLIENT_ID=atl-client\nATLASSIAN_CLIENT_SECRET=atl-app-secret\n"), 0o600)
	real := d.codeFlow(wire.ConnectionProviderAtlassian)
	if real.ClientID != "atl-client" || real.ClientSecret != "atl-app-secret" {
		t.Fatalf("app from the secrets: %q", real.ClientID)
	}
	d.newCodeFlow = func(p wire.ConnectionProvider) *connections.CodeFlow {
		f := connections.NewAtlassianFlow("atl-client", "atl-app-secret")
		f.Token, f.API, f.HTTP = atl.URL+"/oauth/token", atl.URL, atl.Client()
		return f
	}

	var started wire.ConnectionSignIn
	raw := c.call(t, 2, "connections/sign-in", map[string]any{"provider": "atlassian"})
	if strings.Contains(string(raw), "atl-app-secret") {
		t.Fatalf("the client secret went to the client: %s", raw)
	}
	json.Unmarshal(raw, &started)
	u, _ := url.Parse(started.VerificationURL)
	q := u.Query()
	if started.Grant != wire.ConnectionSignInGrantAuthorizationCode || u.Host != "auth.atlassian.com" ||
		q.Get("audience") != "api.atlassian.com" || !strings.Contains(q.Get("scope"), "offline_access") ||
		!strings.Contains(q.Get("scope"), "read:confluence-content.all") || q.Get("client_id") != "atl-client" {
		t.Fatalf("started: %s", started.VerificationURL)
	}

	var done wire.ConnectionSignIn
	raw = c.call(t, 3, "connections/sign-in/complete", map[string]any{"flowID": started.FlowID, "state": q.Get("state"), "code": "code-1"})
	if strings.Contains(string(raw), "atl_oauth_secret") || strings.Contains(string(raw), "atl_refresh_secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &done)
	if done.Status != wire.ConnectionSignInStatusConnected || done.Connection == nil ||
		deref(done.Connection.Login) != "Alex" || deref(done.Connection.Workspace) != "Agents Walk" {
		t.Fatalf("done: %s", raw)
	}
	if n := done.Connection.Newest; n == nil || n.Title != "WALK-7 Newest one" || deref(n.URL) != "https://agentswalk.atlassian.net/browse/WALK-7" || n.At == nil {
		t.Fatalf("newest: %s", raw)
	}
	if got, _ := auth.Load().(string); got != "/ex/jira/cloud-1/rest/api/2/search/jql Bearer atl_oauth_secret" {
		t.Fatalf("the read went to %q", got)
	}
	sent, _ := body.Load().(map[string]string)
	if sent["client_secret"] != "atl-app-secret" || sent["code_verifier"] == "" || sent["grant_type"] != "authorization_code" {
		t.Fatalf("token request: %v", sent)
	}
	kept, ok, _ := file.Get(connections.Atlassian)
	if !ok || kept.Access != "atl_oauth_secret" || kept.Refresh != "atl_refresh_secret" || kept.Resource != "cloud-1" ||
		kept.URL != "https://agentswalk.atlassian.net" || kept.AccessExpiresAt.IsZero() {
		t.Fatalf("kept: %+v", kept)
	}
	// The list never says the newest issue: only the answer that connected does.
	var list wire.ConnectionsList
	json.Unmarshal(c.call(t, 4, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 1 || list.Connections[0].Provider != wire.ConnectionProviderAtlassian || list.Connections[0].Newest != nil ||
		list.Connections[0].ByToken != nil {
		t.Fatalf("list: %+v", list)
	}
}

// Connect Jira with a token (#3304): with an email, a Jira Cloud API token sent as Basic; with
// none, a Data Center personal access token sent as Bearer. Checked with the site and kept.
func TestConnectingJiraWithAnAPIToken(t *testing.T) {
	var body, auth atomic.Value
	jira := fakeAtlassian(t, &body, &auth)
	defer jira.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.jiraHTTP = jira.Client()

	var bad wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 1, "connections/sign-in/token", map[string]any{"provider": "atlassian", "token": "tok"}), &bad)
	if bad.Error == nil || !strings.Contains(*bad.Error, "site") {
		t.Fatalf("no site: %+v", bad)
	}

	var cloud wire.ConnectionTokenAnswer
	raw := c.call(t, 2, "connections/sign-in/token", map[string]any{"provider": "atlassian", "url": jira.URL + "/",
		"user": "a@example.com", "token": "ATATT-secret"})
	if strings.Contains(string(raw), "ATATT-secret") {
		t.Fatalf("the token went back: %s", raw)
	}
	json.Unmarshal(raw, &cloud)
	if cloud.Connection == nil || deref(cloud.Connection.Login) != "Alex C" || cloud.Connection.ByToken == nil || cloud.Connection.Newest == nil ||
		cloud.Connection.Newest.Title != "WALK-7 Newest one" {
		t.Fatalf("cloud: %s", raw)
	}
	if got, _ := auth.Load().(string); got != "/rest/api/2/search/jql Basic YUBleGFtcGxlLmNvbTpBVEFUVC1zZWNyZXQ=" {
		t.Fatalf("cloud read: %q", got)
	}
	kept, _, _ := file.Get(connections.Atlassian)
	if kept.URL != jira.URL || kept.User != "a@example.com" || kept.Resource != "" || kept.Refresh != "" {
		t.Fatalf("kept: %+v", kept)
	}

	var dc wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 3, "connections/sign-in/token", map[string]any{"provider": "atlassian", "url": jira.URL,
		"token": "pat-secret"}), &dc)
	if dc.Connection == nil {
		t.Fatalf("data center: %+v", dc)
	}
	if got, _ := auth.Load().(string); got != "/rest/api/2/search Bearer pat-secret" {
		t.Fatalf("data center read: %q", got)
	}
}
