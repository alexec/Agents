package gitlabmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

// #4403: the assignees are set as the whole list of ids: the ones there are, less those taken
// off, and each new person's id by their username; one GitLab does not know is an error.
func TestSetAssignees(t *testing.T) {
	var put []int
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v4/"); {
		case path == "projects/group%2Fapp/merge_requests/4" && r.Method == http.MethodGet:
			_, _ = io.WriteString(w, `{"assignees": [{"id": 1, "username": "kim"}, {"id": 2, "username": "lee"}]}`)
		case path == "projects/group%2Fapp/merge_requests/4" && r.Method == http.MethodPut:
			var body struct {
				IDs []int `json:"assignee_ids"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			put = body.IDs
			_, _ = io.WriteString(w, `{}`)
		case path == "users" && r.URL.Query().Get("username") == "sam":
			_, _ = io.WriteString(w, `[{"id": 3, "username": "sam"}]`)
		case path == "users":
			_, _ = io.WriteString(w, `[]`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	if err := g.SetAssignees(context.Background(), "group/app", 4, true, []string{"KIM", "sam"}, []string{"Lee"}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(put, []int{1, 3}) {
		t.Fatalf("assignee_ids %v, want [1 3]", put)
	}
	put = nil
	if err := g.SetAssignees(context.Background(), "group/app", 4, true, []string{"nobody"}, nil); err == nil || put != nil {
		t.Fatalf("an unknown user: %v, put %v", err, put)
	}
}

// #4410: auto-merge is cancelled; a draft loses its marks from the title, and one that is not a
// draft is not changed.
func TestCancelAutoMergeAndMarkReady(t *testing.T) {
	var asked, titles []string
	title := "Draft: [Draft] Fix it"
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v4/")
		asked = append(asked, r.Method+" "+path)
		switch {
		case path == "projects/group%2Fapp/merge_requests/4" && r.Method == http.MethodGet:
			_ = json.NewEncoder(w).Encode(map[string]string{"title": title})
		case path == "projects/group%2Fapp/merge_requests/4" && r.Method == http.MethodPut:
			var body struct {
				Title string `json:"title"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			titles = append(titles, body.Title)
			_, _ = io.WriteString(w, `{}`)
		default:
			_, _ = io.WriteString(w, `{}`)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	ctx := context.Background()
	if err := g.CancelAutoMerge(ctx, "group/app", 4); err != nil {
		t.Fatal(err)
	}
	if asked[0] != "POST projects/group%2Fapp/merge_requests/4/cancel_merge_when_pipeline_succeeds" {
		t.Fatalf("cancel: %q", asked)
	}
	if err := g.MarkReady(ctx, "group/app", 4); err != nil {
		t.Fatal(err)
	}
	title = "Fix it"
	if err := g.MarkReady(ctx, "group/app", 4); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(titles, []string{"Fix it"}) {
		t.Fatalf("titles %q, want [Fix it]", titles)
	}
}
