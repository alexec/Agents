package connections

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeGitHub is github.com's device-code and token endpoints and the API's /user. Each
// poll of the token endpoint takes the next of polls; a refresh answers refresh.
type fakeGitHub struct {
	t       *testing.T
	mu      sync.Mutex
	polls   []map[string]any
	refresh map[string]any
	forms   []map[string]string
	server  *httptest.Server
}

func newFake(t *testing.T) *fakeGitHub {
	f := &fakeGitHub{t: t}
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
		switch {
		case r.URL.Path == "/login/device/code":
			json.NewEncoder(w).Encode(map[string]any{"device_code": "dev-123", "user_code": "WDJB-MJHT",
				"verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5})
		case r.URL.Path == "/login/oauth/access_token" && r.PostForm.Get("grant_type") == "refresh_token":
			json.NewEncoder(w).Encode(f.refresh)
		case r.URL.Path == "/login/oauth/access_token":
			if len(f.polls) == 0 {
				json.NewEncoder(w).Encode(map[string]any{"error": "authorization_pending"})
				return
			}
			next := f.polls[0]
			f.polls = f.polls[1:]
			json.NewEncoder(w).Encode(next)
		case r.URL.Path == "/api/user":
			if r.Header.Get("Authorization") != "Bearer ghu_new" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"login": "octocat"})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

// flow is the fake's flow, with a clock that moves only when it sleeps.
func (f *fakeGitHub) flow(now *time.Time, slept *[]time.Duration) *DeviceFlow {
	return &DeviceFlow{ClientID: GitHubClientID, Base: f.server.URL + "/", API: f.server.URL + "/api/",
		HTTP: f.server.Client(), Now: func() time.Time { return *now },
		Sleep: func(ctx context.Context, d time.Duration) error {
			*slept = append(*slept, d)
			*now = now.Add(d)
			return ctx.Err()
		}}
}

var granted = map[string]any{"access_token": "ghu_new", "expires_in": 28800, "refresh_token": "ghr_new",
	"refresh_token_expires_in": 15897600, "token_type": "bearer", "scope": ""}

func TestDeviceFlowWaitsSlowsDownAndGetsTheToken(t *testing.T) {
	fake := newFake(t)
	fake.polls = []map[string]any{{"error": "authorization_pending"}, {"error": "slow_down", "interval": 10}, granted}
	now := time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	var slept []time.Duration
	flow := fake.flow(&now, &slept)
	code, err := flow.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if code.UserCode != "WDJB-MJHT" || code.VerificationURL != "https://github.com/login/device" || code.Interval != 5*time.Second {
		t.Fatalf("code: %+v", code)
	}
	tok, err := flow.Wait(context.Background(), code)
	if err != nil {
		t.Fatal(err)
	}
	if got := []time.Duration{5 * time.Second, 5 * time.Second, 10 * time.Second}; len(slept) != 3 || slept[0] != got[0] || slept[1] != got[1] || slept[2] != got[2] {
		t.Fatalf("slept %v, want the interval, then GitHub's slower one after slow_down", slept)
	}
	if tok.Access != "ghu_new" || tok.Refresh != "ghr_new" || !tok.AccessExpiresAt.Equal(now.Add(8*time.Hour)) {
		t.Fatalf("token: %+v", tok)
	}
	// No client secret is ever sent: the device flow needs none.
	for _, form := range fake.forms {
		if _, ok := form["client_secret"]; ok {
			t.Fatalf("a client secret was sent: %v", form["path"])
		}
		if form["client_id"] != GitHubClientID {
			t.Fatalf("client id %q", form["client_id"])
		}
	}
	login, err := flow.Login(context.Background(), tok.Access)
	if err != nil || login != "octocat" {
		t.Fatalf("login %q %v", login, err)
	}
}

func TestDeviceFlowEndsOnExpiredAndDenied(t *testing.T) {
	for _, c := range []struct {
		answer map[string]any
		want   error
	}{
		{map[string]any{"error": "expired_token"}, ErrExpired},
		{map[string]any{"error": "access_denied"}, ErrDenied},
	} {
		fake := newFake(t)
		fake.polls = []map[string]any{c.answer}
		now := time.Now()
		var slept []time.Duration
		flow := fake.flow(&now, &slept)
		code, _ := flow.Start(context.Background())
		if _, err := flow.Wait(context.Background(), code); !errors.Is(err, c.want) {
			t.Fatalf("%v: got %v", c.answer, err)
		}
	}
	// A code whose time is up ends without asking GitHub again.
	fake := newFake(t)
	now := time.Now()
	var slept []time.Duration
	flow := fake.flow(&now, &slept)
	code, _ := flow.Start(context.Background())
	code.ExpiresAt = now.Add(12 * time.Second)
	if _, err := flow.Wait(context.Background(), code); !errors.Is(err, ErrExpired) {
		t.Fatalf("got %v", err)
	}
	if len(slept) != 3 {
		t.Fatalf("polled %d times", len(slept))
	}
}

func TestAFailureHoldsNoToken(t *testing.T) {
	fake := newFake(t)
	fake.refresh = map[string]any{"error": "server_error", "error_description": "try later"}
	flow := fake.flow(new(time.Time), new([]time.Duration))
	_, err := flow.Refresh(context.Background(), "ghr_secret")
	if err == nil || strings.Contains(err.Error(), "ghr_secret") {
		t.Fatalf("got %v", err)
	}
}

func TestRefreshRenewsBeforeTheEndAndSaysSignInAgainWhenRefused(t *testing.T) {
	fake := newFake(t)
	s := &File{Path: filepath.Join(t.TempDir(), ".agents-secrets", FileName)}
	now := time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	flow := fake.flow(&now, new([]time.Duration))
	old := Connection{Provider: GitHub, Login: "octocat", Access: "ghu_old", Refresh: "ghr_old",
		AccessExpiresAt: now.Add(time.Hour), RefreshExpiresAt: now.Add(1000 * time.Hour), ConnectedAt: now.Add(-7 * time.Hour)}
	if err := s.Put(old); err != nil {
		t.Fatal(err)
	}
	// An hour left: not yet.
	if r, err := RefreshIfDue(context.Background(), s, flow, GitHub, now); r != Unchanged || err != nil {
		t.Fatalf("early: %v %v", r, err)
	}
	// Nine minutes left: renewed, with the refresh token spent.
	fake.refresh = granted
	soon := now.Add(51 * time.Minute)
	if r, err := RefreshIfDue(context.Background(), s, flow, GitHub, soon); r != Renewed || err != nil {
		t.Fatalf("due: %v %v", r, err)
	}
	c, _, _ := s.Get(GitHub)
	if c.Access != "ghu_new" || c.Refresh != "ghr_new" || c.Login != "octocat" || !c.ConnectedAt.Equal(old.ConnectedAt) {
		t.Fatalf("renewed: %+v", c)
	}
	last := fake.forms[len(fake.forms)-1]
	if last["refresh_token"] != "ghr_old" || last["client_secret"] != "" {
		t.Fatalf("refresh form: %v", last)
	}
	// GitHub refuses the next one: the tokens go, the row stays and says sign in again.
	fake.refresh = map[string]any{"error": "bad_refresh_token"}
	if r, err := RefreshIfDue(context.Background(), s, flow, GitHub, now.Add(8*time.Hour)); r != Refused || err != nil {
		t.Fatalf("refused: %v %v", r, err)
	}
	c, ok, _ := s.Get(GitHub)
	if !ok || !c.SignInAgain || c.Access != "" || c.Refresh != "" || c.Login != "octocat" {
		t.Fatalf("after a refusal: %+v", c)
	}
	if r, _ := RefreshIfDue(context.Background(), s, flow, GitHub, now.Add(9*time.Hour)); r != Unchanged {
		t.Fatalf("asked again after a refusal: %v", r)
	}
}

func TestRefreshLeavesTheConnectionOnANetworkFailure(t *testing.T) {
	fake := newFake(t)
	s := &File{Path: filepath.Join(t.TempDir(), FileName)}
	now := time.Now()
	flow := fake.flow(&now, new([]time.Duration))
	fake.server.Close()
	c := Connection{Provider: GitHub, Access: "ghu_old", Refresh: "ghr_old", AccessExpiresAt: now.Add(time.Minute)}
	s.Put(c)
	if r, err := RefreshIfDue(context.Background(), s, flow, GitHub, now); r != Unchanged || err == nil {
		t.Fatalf("got %v %v", r, err)
	}
	got, _, _ := s.Get(GitHub)
	if got.Refresh != "ghr_old" || got.SignInAgain {
		t.Fatalf("changed: %+v", got)
	}
}

func TestTheFileIsTheOwnersOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), ".agents-secrets")
	s := &File{Path: filepath.Join(dir, FileName)}
	if _, ok, err := s.Get(GitHub); ok || err != nil {
		t.Fatalf("empty: %v %v", ok, err)
	}
	if err := s.Put(Connection{Provider: GitHub, Login: "octocat", Access: "ghu_x"}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(s.Path)
	di, _ := os.Stat(dir)
	if fi.Mode().Perm() != 0o600 || di.Mode().Perm() != 0o700 {
		t.Fatalf("modes %v %v", fi.Mode().Perm(), di.Mode().Perm())
	}
	all, _ := List(s)
	if len(all) != 1 || all[0].Login != "octocat" {
		t.Fatalf("list: %+v", all)
	}
	if err := s.Delete(GitHub); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.Get(GitHub); ok {
		t.Fatal("still there")
	}
	// A file that does not read is not written over.
	os.WriteFile(s.Path, []byte("{"), 0o600)
	if err := s.Put(Connection{Provider: GitHub}); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("got %v", err)
	}
}

func TestTokenReaderReadsTheHostsStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), FileName)
	l := Locator("file:" + path)
	read := TokenReader(l, GitHub)
	if read() != "" {
		t.Fatal("a token with no connection")
	}
	s, _ := Open(l)
	s.Put(Connection{Provider: GitHub, Access: "ghu_x", AccessExpiresAt: time.Now().Add(time.Hour)})
	if got := read(); got != "ghu_x" {
		t.Fatalf("got %q", got)
	}
	// An ended token is not given, and a "sign in again" has none.
	s.Put(Connection{Provider: GitHub, Access: "ghu_old", AccessExpiresAt: time.Now().Add(-time.Second)})
	if got := TokenReader(l, GitHub)(); got != "" {
		t.Fatalf("an ended token: %q", got)
	}
	s.Put(Connection{Provider: GitHub, SignInAgain: true})
	if got := TokenReader(l, GitHub)(); got != "" {
		t.Fatalf("sign in again: %q", got)
	}
}

func TestEachRootHasItsOwnStore(t *testing.T) {
	a, b := KeychainService("/Users/x/Library/Application Support/Agents"), KeychainService("/tmp/run-1/root")
	if a == b || !strings.HasPrefix(a, "agents.connection.") {
		t.Fatalf("%q %q", a, b)
	}
	t.Setenv(EnvName, "file:/tmp/x.json")
	if FromEnv() != "file:/tmp/x.json" {
		t.Fatal("the env is not the store")
	}
	if _, err := Open("nowhere"); err == nil {
		t.Fatal("opened nowhere")
	}
	l := ForHost("/r", "/home/p")
	if runtime.GOOS == "darwin" && !strings.HasPrefix(string(l), "keychain:agents.connection.") ||
		runtime.GOOS != "darwin" && l != "file:/home/p/.agents-secrets/connections.json" {
		t.Fatalf("for host: %q", l)
	}
}

// The real login Keychain, under a service made for the test and deleted after: a Mac only.
func TestKeychainKeepsAConnection(t *testing.T) {
	if _, err := os.Stat("/usr/bin/security"); err != nil || runtime.GOOS != "darwin" {
		t.Skip("no Keychain here")
	}
	k := &Keychain{Service: "agents.connection.test-" + strings.ReplaceAll(time.Now().Format("150405.000000"), ".", "")}
	t.Cleanup(func() { k.Delete(GitHub) })
	if _, ok, err := k.Get(GitHub); ok || err != nil {
		t.Fatalf("empty: %v %v", ok, err)
	}
	c := Connection{Provider: GitHub, Login: "octocat", Access: "ghu_x", Refresh: "ghr_y",
		AccessExpiresAt: time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)}
	if err := k.Put(c); err != nil {
		t.Fatal(err)
	}
	c.Access = "ghu_z"
	if err := k.Put(c); err != nil {
		t.Fatal(err)
	}
	got, ok, err := k.Get(GitHub)
	if err != nil || !ok || got.Access != "ghu_z" || got.Login != "octocat" || !got.AccessExpiresAt.Equal(c.AccessExpiresAt) {
		t.Fatalf("got %+v %v %v", got, ok, err)
	}
	if err := k.Delete(GitHub); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := k.Get(GitHub); ok {
		t.Fatal("still there")
	}
}
