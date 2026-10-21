package connections

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeGitLab is gitlab.com's device and token endpoints (which answer 400 while waiting, as
// GitLab does) and the API's /user and /personal_access_tokens/self.
type fakeGitLab struct {
	mu      sync.Mutex
	polls   []map[string]any
	refresh map[string]any
	forms   []map[string]string
	expires string
	server  *httptest.Server
}

func newFakeGitLab(t *testing.T) *fakeGitLab {
	f := &fakeGitLab{}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		r.ParseForm()
		form := map[string]string{"path": r.URL.Path}
		for k := range r.PostForm {
			form[k] = r.PostForm.Get(k)
		}
		f.forms = append(f.forms, form)
		w.Header().Set("Content-Type", "application/json")
		answer := func(a map[string]any) {
			if a["error"] != nil {
				w.WriteHeader(http.StatusBadRequest)
			}
			json.NewEncoder(w).Encode(a)
		}
		switch {
		case r.URL.Path == "/oauth/authorize_device":
			json.NewEncoder(w).Encode(map[string]any{"device_code": "dev-gl", "user_code": "GLAB-CODE",
				"verification_uri": "https://gitlab.com/oauth/device", "expires_in": 300, "interval": 5})
		case r.URL.Path == "/oauth/token" && r.PostForm.Get("grant_type") == "refresh_token":
			answer(f.refresh)
		case r.URL.Path == "/oauth/token":
			if len(f.polls) == 0 {
				answer(map[string]any{"error": "authorization_pending"})
				return
			}
			next := f.polls[0]
			f.polls = f.polls[1:]
			answer(next)
		case r.URL.Path == "/api/v4/user":
			if a := r.Header.Get("Authorization"); a != "Bearer gloas-new" && a != "Bearer glpat-good" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"id": 7, "username": "agentstest"})
		case r.URL.Path == "/api/v4/personal_access_tokens/self" && f.expires != "":
			json.NewEncoder(w).Encode(map[string]any{"expires_at": f.expires, "scopes": []string{"api"}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeGitLab) flow(now *time.Time) *DeviceFlow {
	flow := NewGitLabFlow()
	flow.ClientID = "gitlab-app"
	flow.Base, flow.API, flow.HTTP = f.server.URL+"/", f.server.URL+"/api/v4/", f.server.Client()
	flow.Now = func() time.Time { return *now }
	flow.Sleep = func(ctx context.Context, d time.Duration) error {
		*now = now.Add(d)
		return ctx.Err()
	}
	return flow
}

func TestGitLabDeviceFlowAsksForTheAPIScopeAndGetsTheAccount(t *testing.T) {
	fake := newFakeGitLab(t)
	fake.polls = []map[string]any{{"error": "authorization_pending"},
		{"access_token": "gloas-new", "token_type": "Bearer", "expires_in": 7200, "refresh_token": "glrt-new", "scope": "api"}}
	now := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	flow := fake.flow(&now)
	code, err := flow.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if code.UserCode != "GLAB-CODE" || code.VerificationURL != "https://gitlab.com/oauth/device" {
		t.Fatalf("code: %+v", code)
	}
	tok, err := flow.Wait(context.Background(), code)
	if err != nil {
		t.Fatal(err)
	}
	if tok.Access != "gloas-new" || tok.Refresh != "glrt-new" || !tok.AccessExpiresAt.Equal(now.Add(2*time.Hour)) {
		t.Fatalf("token: %+v", tok)
	}
	if fake.forms[0]["scope"] != "api" || fake.forms[0]["client_id"] != "gitlab-app" {
		t.Fatalf("start asked %v", fake.forms[0])
	}
	for _, form := range fake.forms {
		if _, ok := form["client_secret"]; ok {
			t.Fatalf("a client secret was sent: %v", form["path"])
		}
	}
	if login, err := flow.Login(context.Background(), tok.Access); err != nil || login != "agentstest" {
		t.Fatalf("login %q %v", login, err)
	}
}

func TestGitLabRefreshRefusedIsSignInAgain(t *testing.T) {
	fake := newFakeGitLab(t)
	fake.refresh = map[string]any{"error": "invalid_grant", "error_description": "The provided authorization grant is invalid"}
	now := time.Now()
	if _, err := fake.flow(&now).Refresh(context.Background(), "glrt-old"); !errors.Is(err, ErrRefused) {
		t.Fatalf("got %v, want ErrRefused", err)
	}
	fake.refresh = map[string]any{"error": "server_error"}
	_, err := fake.flow(&now).Refresh(context.Background(), "glrt-old")
	if err == nil || !strings.HasPrefix(err.Error(), "GitLab said server_error") {
		t.Fatalf("got %v, want GitLab's own words", err)
	}
}

func TestGitLabRoot(t *testing.T) {
	for in, want := range map[string]string{
		"":                                    GitLabCom,
		"gitlab.com":                          GitLabCom,
		"https://gitlab.example.com/":         "https://gitlab.example.com/",
		"https://gitlab.example.com/api/v4":   "https://gitlab.example.com/",
		"git.example.com/gitlab/":             "https://git.example.com/gitlab/",
		"http://127.0.0.1:8929":               "http://127.0.0.1:8929/",
		"http://localhost:8929/api/v4/":       "http://localhost:8929/",
		"  https://gitlab.example.com:8443  ": "https://gitlab.example.com:8443/",
	} {
		if got, err := GitLabRoot(in); err != nil || got != want {
			t.Errorf("GitLabRoot(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"http://gitlab.example.com", "ftp://gitlab.example.com", "https://me:pw@gitlab.example.com",
		"https://gitlab.example.com/?x=1", "https://"} {
		if got, err := GitLabRoot(bad); err == nil {
			t.Errorf("GitLabRoot(%q) = %q, want an error", bad, got)
		}
	}
}

func TestCheckGitLabTokenReadsTheAccountAndTheEnd(t *testing.T) {
	fake := newFakeGitLab(t)
	fake.expires = "2027-10-18"
	root := fake.server.URL + "/"
	got, err := CheckGitLabToken(context.Background(), fake.server.Client(), root, "glpat-good")
	if err != nil {
		t.Fatal(err)
	}
	if got.Login != "agentstest" || !got.ExpiresAt.Equal(time.Date(2027, 10, 19, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("got %+v", got)
	}
	_, err = CheckGitLabToken(context.Background(), fake.server.Client(), root, "glpat-bad")
	if err == nil || strings.Contains(err.Error(), "glpat-bad") || !strings.Contains(err.Error(), "did not take") {
		t.Fatalf("a refused token: %v", err)
	}
	// A self-managed GitLab's connection names its host; gitlab.com's names none.
	c := GitLabConnection(root, "glpat-good", got, time.Now())
	if c.URL != root || c.Workspace != strings.TrimPrefix(fake.server.URL, "http://") || c.Refresh != "" {
		t.Fatalf("connection %+v", c)
	}
	if c := GitLabConnection(GitLabCom, "glpat-good", got, time.Now()); c.URL != "" || c.Workspace != "" {
		t.Fatalf("gitlab.com connection %+v", c)
	}
}

func TestAnEndedGitLabTokenAsksToSignInAgain(t *testing.T) {
	s := &File{Path: t.TempDir() + "/c.json"}
	end := time.Date(2027, 10, 19, 0, 0, 0, 0, time.UTC)
	if err := s.Put(Connection{Provider: GitLab, Login: "agentstest", Access: "glpat-good", URL: "https://gitlab.example.com/",
		AccessExpiresAt: end}); err != nil {
		t.Fatal(err)
	}
	r, err := RefreshIfDue(context.Background(), s, NewGitLabFlow(), GitLab, end.Add(-time.Minute))
	if err != nil || r != Refused {
		t.Fatalf("got %v %v", r, err)
	}
	c, _, _ := s.Get(GitLab)
	// Its end is kept, so the row says the token ended, not that a renewal was refused (#1865).
	if !c.SignInAgain || c.Access != "" || c.URL != "https://gitlab.example.com/" || !c.AccessExpiresAt.Equal(end) {
		t.Fatalf("kept %+v", c)
	}
}
