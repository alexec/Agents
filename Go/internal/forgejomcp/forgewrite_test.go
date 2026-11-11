package forgejomcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
)

// #4403: the assignees are set as the whole list of logins: the ones there are, less those taken
// off, and the new ones once each.
func TestSetAssignees(t *testing.T) {
	var patched []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/repos/walkalex/app/issues/3" {
			http.NotFound(w, r)
			return
		}
		switch r.Method {
		case http.MethodGet:
			_, _ = io.WriteString(w, `{"assignees": [{"id": 1, "login": "kim"}, {"id": 2, "login": "lee"}]}`)
		case http.MethodPatch:
			var body struct {
				Assignees []string `json:"assignees"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			patched = body.Assignees
			_, _ = io.WriteString(w, `{}`)
		}
	}))
	t.Cleanup(s.Close)
	f := NewRealForgejo(s.URL, func() string { return token }, nil)
	if err := f.SetAssignees(context.Background(), "walkalex/app", 3, []string{"Kim", "sam"}, []string{"LEE"}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(patched, []string{"kim", "sam"}) {
		t.Fatalf("assignees %v, want [kim sam]", patched)
	}
}

// #4410: auto-merge is cancelled by DELETE on the merge; a draft's WIP marks leave its title.
func TestCancelAutoMergeAndMarkReady(t *testing.T) {
	var asked, titles []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = append(asked, r.Method+" "+r.URL.Path)
		switch {
		case r.URL.Path == "/api/v1/repos/walkalex/app/pulls/3" && r.Method == http.MethodGet:
			_, _ = io.WriteString(w, `{"number": 3, "title": "WIP: [wip] Fix it"}`)
		case r.URL.Path == "/api/v1/repos/walkalex/app/pulls/3" && r.Method == http.MethodPatch:
			var body struct {
				Title string `json:"title"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			titles = append(titles, body.Title)
			_, _ = io.WriteString(w, `{}`)
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	t.Cleanup(s.Close)
	f := NewRealForgejo(s.URL, func() string { return token }, nil)
	ctx := context.Background()
	if err := f.CancelAutoMerge(ctx, "walkalex/app", 3); err != nil {
		t.Fatal(err)
	}
	if asked[0] != "DELETE /api/v1/repos/walkalex/app/pulls/3/merge" {
		t.Fatalf("cancel: %q", asked)
	}
	if err := f.MarkReady(ctx, "walkalex/app", 3); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(titles, []string{"Fix it"}) {
		t.Fatalf("titles %q, want [Fix it]", titles)
	}
	if got := readyTitle("Fix it"); got != "Fix it" {
		t.Fatalf("readyTitle of a title with no mark: %q", got)
	}
}
