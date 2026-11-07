package connections

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Bitbucket's API (#3785): Bitbucket Cloud's when blank, https:// when it names no scheme, and
// http only for this machine.
func TestBitbucketRoot(t *testing.T) {
	for raw, want := range map[string]string{
		"":                          BitbucketAPI,
		"api.bitbucket.org/2.0":     BitbucketAPI,
		"http://127.0.0.1:3785/2.0": "http://127.0.0.1:3785/2.0/",
	} {
		if got, err := BitbucketRoot(raw); err != nil || got != want {
			t.Errorf("%q: %q %v, want %q", raw, got, err, want)
		}
	}
	if _, err := BitbucketRoot("http://bitbucket.example.com"); err == nil || !strings.Contains(err.Error(), "Bitbucket") {
		t.Errorf("http elsewhere: %v", err)
	}
}

// A token is sent as Basic with its email (an Atlassian API token) or as Bearer (an access
// token), and names its account; a wrong one says so and holds no token.
func TestCheckBitbucketToken(t *testing.T) {
	bb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, basic := r.BasicAuth()
		switch {
		case r.URL.Path != "/2.0/user":
			http.NotFound(w, r)
		case basic && user == "me@example.com" && pass == "api-good":
			w.Write([]byte(`{"nickname":"agentstest","display_name":"Agents Test"}`))
		case r.Header.Get("Authorization") == "Bearer access-good":
			w.Write([]byte(`{"display_name":"Repository Access Token"}`))
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	}))
	defer bb.Close()
	api := bb.URL + "/2.0/"
	ctx := context.Background()
	if login, err := CheckBitbucketToken(ctx, bb.Client(), api, "me@example.com", "api-good"); err != nil || login != "agentstest" {
		t.Fatalf("an API token: %q %v", login, err)
	}
	if login, err := CheckBitbucketToken(ctx, bb.Client(), api, "", "access-good"); err != nil || login != "Repository Access Token" {
		t.Fatalf("an access token: %q %v", login, err)
	}
	if _, err := CheckBitbucketToken(ctx, bb.Client(), api, "", "api-good"); err == nil || strings.Contains(err.Error(), "api-good") || !strings.Contains(err.Error(), "email") {
		t.Fatalf("an API token without its email: %v", err)
	}
	at := time.Now()
	if c := BitbucketConnection(BitbucketAPI, " me@example.com ", "t", "a", at); c.URL != "" || c.User != "me@example.com" || c.Workspace != "bitbucket.org" {
		t.Fatalf("cloud: %+v", c)
	}
	if c := BitbucketConnection(api, "", "t", "a", at); c.URL != api || c.User != "" {
		t.Fatalf("a fake: %+v", c)
	}
}
