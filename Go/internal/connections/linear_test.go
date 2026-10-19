package connections

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeLinear is Linear's token endpoint and GraphQL API. A refresh answers refresh.
type fakeLinear struct {
	mu      sync.Mutex
	forms   []url.Values
	refresh map[string]any
	server  *httptest.Server
}

func newFakeLinear(t *testing.T) *fakeLinear {
	f := &fakeLinear{}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/oauth/token":
			r.ParseForm()
			f.forms = append(f.forms, r.PostForm)
			if r.PostForm.Get("grant_type") == "refresh_token" {
				if f.refresh["error"] != nil {
					w.WriteHeader(http.StatusBadRequest)
				}
				json.NewEncoder(w).Encode(f.refresh)
				return
			}
			if r.PostForm.Get("code") != "code-1" {
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]any{"error": "invalid_grant"})
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"access_token": "lin_oauth_new", "token_type": "Bearer",
				"expires_in": 86399, "refresh_token": "lin_refresh_new", "scope": "read write"})
		case "/graphql":
			if r.Header.Get("Authorization") != "Bearer lin_oauth_new" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{
				"viewer": map[string]any{"name": "Alex", "email": "alex@example.com"},
				"organization": map[string]any{"name": "Agents Walk"}}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeLinear) flow(now time.Time) *CodeFlow {
	return &CodeFlow{ClientID: LinearClientID, RedirectURI: HandBackURL, Scopes: LinearScopes,
		Authorize: "https://linear.app/oauth/authorize", Token: f.server.URL + "/oauth/token",
		API: f.server.URL + "/graphql", Name: "Linear", HTTP: f.server.Client(), Now: func() time.Time { return now }}
}

// The address carries the challenge and the state, never the verifier; the state carries a web
// page's origin after a dot, and only an origin.
func TestLinearAuthorizeAddress(t *testing.T) {
	p, err := NewPKCE("")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(p.Verifier))
	if p.Challenge != base64.RawURLEncoding.EncodeToString(sum[:]) || len(p.Verifier) < 43 || strings.Contains(p.State, ".") {
		t.Fatalf("pkce: %+v", p)
	}
	u, _ := url.Parse(NewLinearFlow().AuthorizeURL(p))
	q := u.Query()
	if u.Host != "linear.app" || q.Get("client_id") != LinearClientID || q.Get("redirect_uri") != HandBackURL ||
		q.Get("code_challenge") != p.Challenge || q.Get("code_challenge_method") != "S256" || q.Get("state") != p.State ||
		q.Get("response_type") != "code" || strings.Contains(u.String(), p.Verifier) {
		t.Fatalf("address: %s", u)
	}

	web, err := NewPKCE("https://control.agentloops.dev/")
	if err != nil {
		t.Fatal(err)
	}
	_, tail, ok := strings.Cut(web.State, ".")
	origin, _ := base64.RawURLEncoding.DecodeString(tail)
	if !ok || string(origin) != "https://control.agentloops.dev" {
		t.Fatalf("web state: %s", web.State)
	}
	for _, bad := range []string{"agents://x", "javascript:alert(1)", "https://a.example/path", "https://u@a.example", "a.example"} {
		if _, err := NewPKCE(bad); err == nil {
			t.Errorf("%s was taken as an origin", bad)
		}
	}
}

// The code and the verifier buy a pair; the account is the viewer and the workspace; a wrong
// code is the provider's words, with no secret in them.
func TestLinearExchangeAndAccount(t *testing.T) {
	f := newFakeLinear(t)
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	flow := f.flow(now)
	tok, err := flow.Exchange(context.Background(), "code-1", "the-verifier")
	if err != nil {
		t.Fatal(err)
	}
	if tok.Access != "lin_oauth_new" || tok.Refresh != "lin_refresh_new" || !tok.AccessExpiresAt.Equal(now.Add(86399*time.Second)) {
		t.Fatalf("token: %+v", tok)
	}
	form := f.forms[0]
	if form.Get("code_verifier") != "the-verifier" || form.Get("client_id") != LinearClientID ||
		form.Get("redirect_uri") != HandBackURL || form.Get("client_secret") != "" {
		t.Fatalf("form: %v", form)
	}
	login, workspace, err := flow.Account(context.Background(), tok.Access)
	if err != nil || login != "Alex" || workspace != "Agents Walk" {
		t.Fatalf("account: %q %q %v", login, workspace, err)
	}
	_, err = flow.Exchange(context.Background(), "stolen", "the-verifier")
	var failure *Failure
	if !errors.As(err, &failure) || failure.Code != "invalid_grant" || strings.Contains(err.Error(), "stolen") {
		t.Fatalf("wrong code: %v", err)
	}
}

// A refresh rotates the pair; a refused one makes the connection say "Sign in again".
func TestLinearRefreshRotatesAndRefuses(t *testing.T) {
	f := newFakeLinear(t)
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	s := &File{Path: t.TempDir() + "/connections.json"}
	s.Put(Connection{Provider: Linear, Login: "Alex", Workspace: "Agents Walk", Access: "old", Refresh: "r1",
		AccessExpiresAt: now.Add(5 * time.Minute), ConnectedAt: now.Add(-time.Hour)})

	f.refresh = map[string]any{"access_token": "a2", "refresh_token": "r2", "expires_in": 86399}
	if got, err := RefreshIfDue(context.Background(), s, f.flow(now), Linear, now); got != Renewed || err != nil {
		t.Fatalf("renew: %v %v", got, err)
	}
	c, _, _ := s.Get(Linear)
	if c.Access != "a2" || c.Refresh != "r2" || c.Workspace != "Agents Walk" || f.forms[0].Get("refresh_token") != "r1" {
		t.Fatalf("renewed: %+v", c)
	}

	f.refresh = map[string]any{"error": "invalid_grant"}
	later := now.Add(24 * time.Hour)
	if got, _ := RefreshIfDue(context.Background(), s, f.flow(later), Linear, later); got != Refused {
		t.Fatalf("refused: %v", got)
	}
	c, _, _ = s.Get(Linear)
	if !c.SignInAgain || c.Access != "" || c.Refresh != "" || c.Workspace != "Agents Walk" {
		t.Fatalf("after refusal: %+v", c)
	}
}
