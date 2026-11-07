package forgejomcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// What lineage asks (#3844), against a stand-in Forgejo whose answers are a scratch Forgejo
// 17's, cut down: a merged pull request, an issue with a milestone, a milestone, a release's
// compare, a commit's pull request, and the cost comment posted, edited and posted again.
func TestLineageAsks(t *testing.T) {
	var mu sync.Mutex
	var asked []string
	answers := map[string]string{
		"GET repos/walkalex/app/issues/2": `{"title":"Add a","state":"closed","labels":[],"milestone":null,` +
			`"pull_request":{"merged":true,"merged_at":"2026-11-07T13:17:48Z"}}`,
		"GET repos/walkalex/app/issues/1":                `{"title":"Lineage asks Forgejo","state":"open","labels":[{"name":"bug"}],"milestone":{"id":1,"title":"0.2 Lineage"},"pull_request":null}`,
		"GET repos/walkalex/app/milestones/1":            `{"id":1,"title":"0.2 Lineage","state":"open"}`,
		"GET repos/walkalex/app/milestones":              `[{"id":1,"title":"0.2 Lineage"}]`,
		"GET repos/walkalex/app/git/commits/v0.2.0":      `{"sha":"961a","commit":{"committer":{"date":"2026-11-07T13:17:47Z"}}}`,
		"GET repos/walkalex/app/compare/v0.1.0...v0.2.0": `{"commits":[{"sha":"961a","commit":{"message":"Add a (#2)\n"}}]}`,
		"GET repos/walkalex/app/commits/961a/pull":       `{"number":2}`,
		"GET repos/walkalex/app/issues/2/comments":       `[{"id":5,"body":"Thanks"},{"id":6,"body":"<!-- mark -->\nold"}]`,
		"PATCH repos/walkalex/app/issues/comments/6":     `{"id":6,"body":"new"}`,
		"POST repos/walkalex/app/issues/3/comments":      `{"id":7,"body":"new"}`,
		"GET repos/walkalex/app/issues/3/comments":       `[]`,
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Method + " " + strings.TrimPrefix(r.URL.Path, "/api/v1/")
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		said := key
		for _, part := range []string{r.URL.Query().Get("state"), string(body)} {
			if part != "" {
				said += " " + part
			}
		}
		asked = append(asked, said)
		mu.Unlock()
		a, ok := answers[key]
		if !ok {
			http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
			return
		}
		_, _ = io.WriteString(w, a)
	}))
	t.Cleanup(server.Close)
	fj := NewRealForgejo(server.URL, func() string { return token }, nil)
	ctx := context.Background()

	if n, err := fj.Node(ctx, "walkalex/app", 2); err != nil || fmt.Sprint(n) != "{Add a merged [] 0}" {
		t.Errorf("a merged pull request: %+v %v", n, err)
	}
	if n, err := fj.Node(ctx, "walkalex/app", 1); err != nil || fmt.Sprint(n) != "{Lineage asks Forgejo open [bug] 1}" {
		t.Errorf("an issue: %+v %v", n, err)
	}
	if n, err := fj.MilestoneNode(ctx, "walkalex/app", 1); err != nil || n.Title != "0.2 Lineage" || n.State != "open" {
		t.Errorf("a milestone: %+v %v", n, err)
	}
	if ms, err := fj.Milestones(ctx, "walkalex/app"); err != nil || fmt.Sprint(ms) != "[{1 0.2 Lineage}]" {
		t.Errorf("the milestones: %+v %v", ms, err)
	}
	if at, err := fj.CommitTime(ctx, "walkalex/app", "v0.2.0"); err != nil || !at.Equal(time.Date(2026, 11, 7, 13, 17, 47, 0, time.UTC)) {
		t.Errorf("a tag's time: %v %v", at, err)
	}
	if cs, err := fj.Compare(ctx, "walkalex/app", "v0.1.0", "v0.2.0"); err != nil || fmt.Sprint(cs) != "[{961a Add a (#2)\n}]" {
		t.Errorf("a compare: %+v %v", cs, err)
	}
	if n, err := fj.CommitPR(ctx, "walkalex/app", "961a"); err != nil || n != 2 {
		t.Errorf("a commit's pull request: %d %v", n, err)
	}
	if n, err := fj.CommitPR(ctx, "walkalex/app", "beef"); err != nil || n != 0 {
		t.Errorf("a commit with no pull request: %d %v", n, err)
	}
	// The marked comment is found and edited; a deleted one is found again; none is posted.
	if id, err := fj.CostComment(ctx, "walkalex/app", 2, "", "<!-- mark -->", "new"); err != nil || id != "6" {
		t.Errorf("the marked comment: %q %v", id, err)
	}
	if id, err := fj.CostComment(ctx, "walkalex/app", 2, "99", "<!-- mark -->", "new"); err != nil || id != "6" {
		t.Errorf("a deleted comment: %q %v", id, err)
	}
	if id, err := fj.CostComment(ctx, "walkalex/app", 3, "", "<!-- mark -->", "new"); err != nil || id != "7" {
		t.Errorf("a new comment: %q %v", id, err)
	}
	var writes []string
	for _, a := range asked {
		if !strings.HasPrefix(a, "GET") {
			writes = append(writes, a)
		}
	}
	want := []string{`PATCH repos/walkalex/app/issues/comments/6 {"body":"new"}`, `PATCH repos/walkalex/app/issues/comments/99 {"body":"new"}`,
		`PATCH repos/walkalex/app/issues/comments/6 {"body":"new"}`, `POST repos/walkalex/app/issues/3/comments {"body":"new"}`}
	if fmt.Sprint(writes) != fmt.Sprint(want) {
		t.Errorf("wrote\n%v\nwant\n%v", writes, want)
	}
	if !strings.Contains(strings.Join(asked, "\n"), "GET repos/walkalex/app/milestones all") {
		t.Errorf("the milestones were not asked with state=all: %v", asked)
	}
}
