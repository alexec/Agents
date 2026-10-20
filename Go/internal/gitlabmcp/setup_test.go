package gitlabmcp

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"testing"
)

// The set-up's reads (#1632) against a fake GitLab: the newest issue and merge request, the
// last pipeline in a slot's words, nothing when there is none, and a 404 refused.
func TestSetupReads(t *testing.T) {
	gl := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/v4/projects/group/hidden/"):
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"message":"404 Project Not Found"}`))
		case strings.HasSuffix(r.URL.Path, "/issues"):
			json.NewEncoder(w).Encode([]map[string]any{{"iid": 4, "title": "Walk it", "web_url": "https://gitlab.com/group/app/-/issues/4", "created_at": "2026-10-20T10:00:00Z"}})
		case strings.HasSuffix(r.URL.Path, "/merge_requests"):
			w.Write([]byte(`[]`))
		case strings.HasSuffix(r.URL.Path, "/pipelines"):
			json.NewEncoder(w).Encode([]map[string]any{{"id": 99, "ref": "main", "status": "failed", "web_url": "https://gitlab.com/group/app/-/pipelines/99", "updated_at": "2026-10-20T10:00:00Z"}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer gl.Close()
	g := NewRealGitLab(gl.URL, func() string { return "glpat" }, nil)
	ctx := context.Background()
	if n, err := g.NewestIssue(ctx, "group/app"); err != nil || n == nil || n.Number != 4 || n.Title != "Walk it" {
		t.Fatalf("issue %+v %v", n, err)
	}
	if n, err := g.NewestMergeRequest(ctx, "group/app"); err != nil || n != nil {
		t.Fatalf("no merge requests: %+v %v", n, err)
	}
	if n, err := g.LastPipeline(ctx, "group/app"); err != nil || n == nil || n.Title != "Pipeline on main" || n.Outcome != "failed" {
		t.Fatalf("pipeline %+v %v", n, err)
	}
	_, err := g.NewestIssue(ctx, "group/hidden")
	var refused *GitLabError
	if !errors.As(err, &refused) || !refused.Refused {
		t.Fatalf("a hidden project: %v", err)
	}
}

// A project's remote names its GitLab: the connected one first, then gitlab.com, then a host
// named gitlab.
func TestProjectAt(t *testing.T) {
	for _, c := range []struct{ remote, root, project string }{
		{"git@gitlab.com:group/sub/app.git", "https://gitlab.com/", "group/sub/app"},
		{"https://gitlab.example.com/team/app.git", "https://gitlab.example.com/", "team/app"},
		{"ssh://git@code.example.org/team/app.git", "https://code.example.org/", "team/app"},
		{"git@gitlab.internal:ops/tool.git", "https://gitlab.internal/", "ops/tool"},
	} {
		dir := t.TempDir()
		for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", c.remote}} {
			if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v %s", args, err, out)
			}
		}
		root, project, ok := ProjectAt(context.Background(), dir, []string{"https://code.example.org/", "https://gitlab.com/"})
		if !ok || root != c.root || project != c.project {
			t.Errorf("%s: %q %q %v, want %q %q", c.remote, root, project, ok, c.root, c.project)
		}
	}
	dir := t.TempDir()
	exec.Command("git", "-C", dir, "init", "-q").Run()
	exec.Command("git", "-C", dir, "remote", "add", "origin", "git@github.com:alexec/agents.git").Run()
	if _, _, ok := ProjectAt(context.Background(), dir, []string{"https://gitlab.com/"}); ok {
		t.Error("a GitHub remote is not a GitLab project")
	}
}
