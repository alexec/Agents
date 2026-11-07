package githubmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// #3708: a repository that is not there is made private and empty, the person's own with
// user/repos and an organisation's with orgs/…/repos; one that is there is only read.
func TestMakeRepository(t *testing.T) {
	var mu sync.Mutex
	var got []string
	var made map[string]any
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		got = append(got, r.Method+" "+r.URL.Path)
		switch {
		case r.URL.Path == "/user":
			io.WriteString(w, `{"login":"someone","id":42}`)
		case r.Method == http.MethodGet && r.URL.Path == "/repos/someone/old":
			io.WriteString(w, `{"full_name":"someone/old","clone_url":"https://github.com/someone/old.git"}`)
		case r.Method == http.MethodPost && (r.URL.Path == "/user/repos" || r.URL.Path == "/orgs/acme/repos"):
			json.Unmarshal(body, &made)
			w.WriteHeader(http.StatusCreated)
			owner := "someone"
			if r.URL.Path == "/orgs/acme/repos" {
				owner = "acme"
			}
			io.WriteString(w, `{"full_name":"`+owner+`/`+made["name"].(string)+`","clone_url":"https://github.com/`+owner+`/x.git"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	ctx := context.Background()

	r, isNew, err := g.MakeRepository(ctx, "", "tidelog", "Tide Log")
	if err != nil || !isNew || r.FullName != "someone/tidelog" || r.Login != "someone" || r.UserID != 42 {
		t.Fatalf("%+v %v %v", r, isNew, err)
	}
	if made["private"] != true || made["auto_init"] != false || made["description"] != "Tide Log" {
		t.Errorf("made %v", made)
	}
	if r, isNew, err := g.MakeRepository(ctx, "acme", "tidelog", ""); err != nil || !isNew || r.FullName != "acme/tidelog" {
		t.Fatalf("org: %+v %v %v", r, isNew, err)
	}
	mu.Lock()
	got = nil
	mu.Unlock()
	if r, isNew, err := g.MakeRepository(ctx, "someone", "old", ""); err != nil || isNew || r.CloneURL != "https://github.com/someone/old.git" {
		t.Fatalf("there: %+v %v %v", r, isNew, err)
	}
	for _, call := range got {
		if call[:4] == "POST" {
			t.Errorf("made one that was there: %v", got)
		}
	}
	if _, _, err := g.MakeRepository(ctx, "", "a/b", ""); err == nil {
		t.Error("a/b was taken as a name")
	}
}
