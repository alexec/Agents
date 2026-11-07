package connections

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A Forgejo's address (#3752): Codeberg when blank, https:// when it names no scheme, no
// /api/v1, and http only for this machine.
func TestForgejoRoot(t *testing.T) {
	for raw, want := range map[string]string{
		"":                               Codeberg,
		"git.example.com":                "https://git.example.com/",
		"https://git.example.com/api/v1": "https://git.example.com/",
		"https://example.com/git/":       "https://example.com/git/",
		"http://localhost:3000":          "http://localhost:3000/",
		"http://127.0.0.1:3000/":         "http://127.0.0.1:3000/",
	} {
		if got, err := ForgejoRoot(raw); err != nil || got != want {
			t.Errorf("%q: %q %v, want %q", raw, got, err, want)
		}
	}
	for _, raw := range []string{"http://git.example.com", "ftp://git.example.com", "https://me@git.example.com"} {
		if _, err := ForgejoRoot(raw); err == nil || !strings.Contains(err.Error(), "Forgejo") {
			t.Errorf("%q: %v", raw, err)
		}
	}
}

// A token is sent as Forgejo's "token" header and names its account; a wrong one says so and
// holds no token. Codeberg's connection keeps no URL; another Forgejo's keeps its root.
func TestCheckForgejoToken(t *testing.T) {
	fj := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Header.Get("Authorization") != "token fj-good":
			w.WriteHeader(http.StatusUnauthorized)
		case r.URL.Path == "/api/v1/user":
			w.Write([]byte(`{"id":2,"login":"agentstest"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer fj.Close()
	root := fj.URL + "/"
	if login, err := CheckForgejoToken(context.Background(), fj.Client(), root, "fj-good"); err != nil || login != "agentstest" {
		t.Fatalf("%q %v", login, err)
	}
	if _, err := CheckForgejoToken(context.Background(), fj.Client(), root, "fj-bad"); err == nil || strings.Contains(err.Error(), "fj-bad") {
		t.Fatalf("a wrong token: %v", err)
	}
	at := time.Now()
	if c := ForgejoConnection(Codeberg, "t", "a", at); c.URL != "" || c.Workspace != "codeberg.org" || c.Provider != Forgejo {
		t.Fatalf("codeberg: %+v", c)
	}
	if c := ForgejoConnection(root, "t", "a", at); c.URL != root || c.Workspace != strings.TrimPrefix(fj.URL, "http://") {
		t.Fatalf("own: %+v", c)
	}
}
