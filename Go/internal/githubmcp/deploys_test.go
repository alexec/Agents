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

// #3587: the waiting runs are read with their pending deployments; an environment with only a
// wait timer is no gate a person answers; teams are org/team; and an answer names the
// environments and the state, as the person; and what a tag ships is read by its tags and a compare.
func TestWaitingDeploysAndTheirAnswer(t *testing.T) {
	var mu sync.Mutex
	var got []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, strings.TrimSpace(r.Method+" "+r.URL.Path+" "+string(body)))
		mu.Unlock()
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/o/r/actions/runs"):
			if r.URL.Query().Get("status") != "waiting" {
				t.Errorf("listed %q", r.URL.RawQuery)
			}
			io.WriteString(w, `{"workflow_runs":[
				{"id":1,"run_attempt":1,"name":"Release","path":".github/workflows/release.yml","event":"push","status":"waiting",
				 "head_branch":"v0.17.0","head_sha":"abc","html_url":"https://github.com/o/r/actions/runs/1","updated_at":"2026-11-05T10:00:00Z",
				 "actor":{"login":"alexec","type":"User"}},
				{"id":2,"run_attempt":1,"name":"Nightly","path":".github/workflows/nightly.yml","event":"schedule","status":"waiting",
				 "head_branch":"main","head_sha":"def","html_url":"https://github.com/o/r/actions/runs/2","updated_at":"2026-11-05T10:00:00Z",
				 "actor":{"login":"alexec","type":"User"}}]}`)
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/runs/1/pending_deployments"):
			io.WriteString(w, `[
				{"environment":{"id":11,"name":"production","html_url":"https://github.com/o/r/deployments/activity_log?environments_filter=production"},
				 "current_user_can_approve":true,"reviewers":[{"type":"User","reviewer":{"login":"alexec"}},{"type":"Team","reviewer":{"slug":"release"}}]},
				{"environment":{"id":12,"name":"soak"},"current_user_can_approve":false,"reviewers":[]}]`)
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/runs/2/pending_deployments"):
			io.WriteString(w, `[{"environment":{"id":13,"name":"soak"},"current_user_can_approve":false,"reviewers":[]}]`)
		case strings.HasSuffix(r.URL.Path, "/o/r/tags"):
			io.WriteString(w, `[{"name":"v0.17.0"},{"name":"v0.16.0"}]`)
		case strings.HasSuffix(r.URL.Path, "/o/r/compare/v0.16.0...v0.17.0"):
			io.WriteString(w, `{"commits":[{"sha":"a1","commit":{"message":"One (#1)"}}]}`)
		default:
			io.WriteString(w, `[]`)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	ctx := context.Background()
	waiting, err := g.WaitingDeploys(ctx, "o/r", "", "")
	if err != nil || len(waiting) != 1 {
		t.Fatalf("waiting: %+v %v", waiting, err)
	}
	w := waiting[0]
	if w.Run.Run.ID != 1 || w.Run.Workflow != "release.yml" || w.Run.Run.Branch != "v0.17.0" || !w.Run.Trusted || !w.CanApprove ||
		w.EnvironmentNames() != "production" || !slices.Equal(w.EnvironmentIDs(), []int64{11}) ||
		!slices.Equal(w.Reviewers, []string{"alexec", "o/release"}) {
		t.Fatalf("deploy: %+v", w)
	}
	if only, _ := g.WaitingDeploys(ctx, "o/r", "nightly.yml", ""); len(only) != 0 {
		t.Fatalf("by workflow: %+v", only)
	}
	if err := g.ReviewDeployments(ctx, "o/r", 1, []int64{11}, true, "Approved in Agents"); err != nil {
		t.Fatal(err)
	}
	if err := g.ReviewDeployments(ctx, "o/r", 1, []int64{11}, false, "Rejected in Agents"); err != nil {
		t.Fatal(err)
	}
	if err := g.ReviewDeployments(ctx, "o/r", 1, nil, true, ""); err == nil {
		t.Fatal("an answer with no environments")
	}
	if tags, err := g.Tags(ctx, "o/r"); err != nil || !slices.Equal(tags, []string{"v0.17.0", "v0.16.0"}) {
		t.Fatalf("tags: %q %v", tags, err)
	}
	if commits, err := g.Compare(ctx, "o/r", "v0.16.0", "v0.17.0"); err != nil || len(commits) != 1 || commits[0] != (Commit{"a1", "One (#1)"}) {
		t.Fatalf("compare: %+v %v", commits, err)
	}
	mu.Lock()
	defer mu.Unlock()
	posts := slices.DeleteFunc(slices.Clone(got), func(s string) bool { return !strings.HasPrefix(s, "POST") })
	if !slices.Equal(posts, []string{
		`POST /repos/o/r/actions/runs/1/pending_deployments {"comment":"Approved in Agents","environment_ids":[11],"state":"approved"}`,
		`POST /repos/o/r/actions/runs/1/pending_deployments {"comment":"Rejected in Agents","environment_ids":[11],"state":"rejected"}`,
	}) {
		t.Fatalf("posts: %q", posts)
	}
}
