package githubmcp

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

// #3706: a secret goes sealed to the repository's key and only its key can open it; a variable
// is changed when it is there and made when it is not; a gate names its reviewers by id.
func TestCISettings(t *testing.T) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got []string
	var sealed map[string]string
	var gate string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		got = append(got, r.Method+" "+r.URL.Path)
		switch {
		case r.URL.Path == "/repos/o/r/actions/secrets/public-key":
			io.WriteString(w, `{"key_id":"k1","key":"`+base64.StdEncoding.EncodeToString(pub[:])+`"}`)
		case r.Method == http.MethodPut && r.URL.Path == "/repos/o/r/actions/secrets/SENTRY_TOKEN":
			json.Unmarshal(body, &sealed)
			w.WriteHeader(http.StatusCreated)
		case r.Method == http.MethodPatch && r.URL.Path == "/repos/o/r/actions/variables/OLD":
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPatch:
			w.WriteHeader(http.StatusNotFound)
		case r.Method == http.MethodPost && r.URL.Path == "/repos/o/r/actions/variables":
			w.WriteHeader(http.StatusCreated)
		case r.URL.Path == "/users/alexec":
			io.WriteString(w, `{"id":7}`)
		case r.URL.Path == "/orgs/o/teams/release":
			io.WriteString(w, `{"id":9}`)
		case r.Method == http.MethodPut && r.URL.Path == "/repos/o/r/environments/app-store":
			gate = string(body)
			io.WriteString(w, `{}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	ctx := context.Background()

	if err := g.SetActionsSecret(ctx, "o/r", "SENTRY_TOKEN", "s3cret-value"); err != nil {
		t.Fatal(err)
	}
	if sealed["key_id"] != "k1" || strings.Contains(sealed["encrypted_value"], "s3cret") {
		t.Fatalf("sent %v", sealed)
	}
	raw, _ := base64.StdEncoding.DecodeString(sealed["encrypted_value"])
	if opened, ok := box.OpenAnonymous(nil, raw, pub, priv); !ok || string(opened) != "s3cret-value" {
		t.Fatalf("opened %q %v", opened, ok)
	}

	if replaced, err := g.SetActionsVariable(ctx, "o/r", "OLD", "1"); err != nil || !replaced {
		t.Fatalf("OLD: %v %v", replaced, err)
	}
	if replaced, err := g.SetActionsVariable(ctx, "o/r", "GCP_DEPLOY_SA", "sa@p.iam"); err != nil || replaced {
		t.Fatalf("new: %v %v", replaced, err)
	}

	if err := g.SetEnvironmentGate(ctx, "o/r", "app-store", []string{"alexec", "o/release"}); err != nil {
		t.Fatal(err)
	}
	if gate != `{"reviewers":[{"type":"User","id":7},{"type":"Team","id":9}]}` {
		t.Fatalf("gate %s", gate)
	}
	if err := g.SetEnvironmentGate(ctx, "o/r", "app-store", []string{"nobody"}); err == nil || !strings.Contains(err.Error(), "no user or team nobody") {
		t.Fatalf("nobody: %v", err)
	}
	if err := g.SetEnvironmentGate(ctx, "o/r", "app-store", []string{"other/team"}); err == nil {
		t.Fatal("a team of another org was taken")
	}
	if err := g.SetEnvironmentGate(ctx, "o/r", "app-store", nil); err == nil {
		t.Fatal("no reviewers was taken")
	}
}
