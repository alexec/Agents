package githubmcp

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
)

// restAPI answers the plan's writes (#3271) and keeps each request as "METHOD path body".
func restAPI(t *testing.T) (*RealGitHub, func() []string) {
	var mu sync.Mutex
	var got []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, strings.TrimSpace(r.Method+" "+r.URL.Path+" "+string(body)))
		mu.Unlock()
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/issues/7"):
			io.WriteString(w, `{"id":700,"number":7}`)
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/issues/8"):
			io.WriteString(w, `{"id":800,"number":8}`)
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/o/r/issues"):
			w.WriteHeader(http.StatusCreated)
			io.WriteString(w, `{"id":900,"number":9,"html_url":"https://github.com/o/r/issues/9"}`)
		case r.Method == http.MethodDelete && strings.HasSuffix(r.URL.Path, "/800"):
			w.WriteHeader(http.StatusNotFound)
			io.WriteString(w, `{"message":"Not Found"}`)
		case r.Method == http.MethodGet:
			w.WriteHeader(http.StatusNotFound)
			io.WriteString(w, `{"message":"Not Found"}`)
		default:
			io.WriteString(w, `{}`)
		}
	}))
	t.Cleanup(s.Close)
	return NewRealGitHub(s.URL, func() string { return "t" }, nil), func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(got)
	}
}

// #3271: a new child is an issue with its labels; a sub-issue and a blocker go by the issue's id,
// not its number; a link to take off that is not there is not an error; an issue that is not
// there is.
func TestPlanWritesGoByIssueID(t *testing.T) {
	g, got := restAPI(t)
	ctx := context.Background()
	n, url, err := g.CreateIssue(ctx, "o/r", "New child", []string{"task", "feature:work"})
	if err != nil || n != 9 || url != "https://github.com/o/r/issues/9" {
		t.Fatalf("create: %d %q %v", n, url, err)
	}
	if err := g.AddSubIssue(ctx, "o/r", 1, "o/s", 7); err != nil {
		t.Fatal(err)
	}
	if err := g.SetBlockedBy(ctx, "o/r", 7, "o/r", 8, true); err != nil {
		t.Fatal(err)
	}
	if err := g.SetBlockedBy(ctx, "o/r", 7, "o/r", 8, false); err != nil {
		t.Fatalf("a link that is not there: %v", err)
	}
	if err := g.AddSubIssue(ctx, "o/r", 1, "o/r", 404); err == nil {
		t.Fatal("added an issue that is not there")
	}
	want := []string{
		`POST /repos/o/r/issues {"labels":["task","feature:work"],"title":"New child"}`,
		`GET /repos/o/s/issues/7`,
		`POST /repos/o/r/issues/1/sub_issues {"replace_parent":true,"sub_issue_id":700}`,
		`GET /repos/o/r/issues/8`,
		`POST /repos/o/r/issues/7/dependencies/blocked_by {"issue_id":800}`,
		`GET /repos/o/r/issues/8`,
		`DELETE /repos/o/r/issues/7/dependencies/blocked_by/800`,
		`GET /repos/o/r/issues/404`,
	}
	if g := got(); !slices.Equal(g, want) {
		t.Fatalf("asked:\n%q\nwant\n%q", g, want)
	}
}

// #3865: a forge request's answer writes the issue's body and takes the person off it.
func TestRequestWritesSetBodyAndUnassign(t *testing.T) {
	g, got := restAPI(t)
	ctx := context.Background()
	if err := g.SetBody(ctx, "o/r", 5, "- [x] Sign in"); err != nil {
		t.Fatal(err)
	}
	if err := g.Unassign(ctx, "o/r", 5, []string{"alexec"}); err != nil {
		t.Fatal(err)
	}
	want := []string{
		`PATCH /repos/o/r/issues/5 {"body":"- [x] Sign in"}`,
		`DELETE /repos/o/r/issues/5/assignees {"assignees":["alexec"]}`,
	}
	if g := got(); !slices.Equal(g, want) {
		t.Fatalf("asked:\n%q\nwant\n%q", g, want)
	}
}

// #4403: Assign adds the logins on the issue's assignees; Unassign takes them off.
func TestAssignAndUnassign(t *testing.T) {
	g, got := restAPI(t)
	ctx := context.Background()
	if err := g.Assign(ctx, "o/r", 7, []string{"kim", "lee"}); err != nil {
		t.Fatal(err)
	}
	if err := g.Unassign(ctx, "o/r", 7, []string{"lee"}); err != nil {
		t.Fatal(err)
	}
	want := []string{`POST /repos/o/r/issues/7/assignees {"assignees":["kim","lee"]}`, `DELETE /repos/o/r/issues/7/assignees {"assignees":["lee"]}`}
	if g := got(); !slices.Equal(g, want) {
		t.Fatalf("requests:\n%q\nwant\n%q", g, want)
	}
}
