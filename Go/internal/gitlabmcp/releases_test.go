package gitlabmcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// #4426: a project's releases (an upcoming one is a pre-release) and a release's compare.
func TestReleasesAndCompare(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v4/"); path {
		case "projects/group%2Fapp/releases":
			if r.URL.Query().Get("per_page") != "100" {
				t.Errorf("per_page %q", r.URL.Query().Get("per_page"))
			}
			_, _ = io.WriteString(w, `[{"tag_name": "v2.0.0", "name": "Two", "description": "Notes.", "created_at": "2026-11-04T09:00:00Z",
				"released_at": "2026-11-04T10:00:00Z", "upcoming_release": true, "author": {"username": "kim", "avatar_url": "a"},
				"assets": {"count": 3}, "_links": {"self": "u"}}]`)
		case "projects/group%2Fapp/repository/compare":
			if r.URL.Query().Get("from") != "v1.9.0" || r.URL.Query().Get("to") != "v2.0.0" {
				t.Errorf("compare %v", r.URL.Query())
			}
			_, _ = io.WriteString(w, `{"commits": [{"id": "c1", "message": "Faster (!4)"}], "web_url": "w"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	got, err := g.Releases(context.Background(), "group/app", 500)
	if err != nil || fmt.Sprint(got) != "[{v2.0.0 Two Notes. true 2026-11-04T09:00:00Z 2026-11-04T10:00:00Z kim a 3 u}]" {
		t.Fatalf("releases: %+v %v", got, err)
	}
	cs, err := g.Compare(context.Background(), "group/app", "v1.9.0", "v2.0.0")
	if err != nil || fmt.Sprint(cs) != "[{c1 Faster (!4)}]" {
		t.Fatalf("compare: %+v %v", cs, err)
	}
}
