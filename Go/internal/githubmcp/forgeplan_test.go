package githubmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const planAnswer = `{"data":{"repository":{"issue":{"number":3265,"title":"Epic","url":"u","issueState":"OPEN","updatedAt":"2026-11-02T10:00:00Z",
 "author":{"login":"alexec","__typename":"User"},"repository":{"nameWithOwner":"alexec/Agents"},"labels":{"nodes":[{"name":"epic","color":"5319e7"}]},
 "assignees":{"nodes":[]},"milestone":{"title":"0.16"},"commentCount":{"totalCount":0},"parent":null,"subIssuesSummary":{"total":2,"completed":1},
 "subIssues":{"nodes":[
  {"number":3267,"title":"Wire","url":"u1","issueState":"CLOSED","updatedAt":"2026-11-02T09:00:00Z","author":null,"repository":{"nameWithOwner":"alexec/Agents"},
   "labels":{"nodes":[{"name":"task"}]},"assignees":{"nodes":[]},"milestone":null,"commentCount":{"totalCount":1},
   "parent":{"number":3265,"repository":{"nameWithOwner":"alexec/Agents"}},"subIssuesSummary":{"total":0,"completed":0},"blockedBy":{"nodes":[]}},
  {"number":3268,"title":"Plan section","url":"u2","issueState":"OPEN","updatedAt":"2026-11-02T08:00:00Z","author":null,"repository":{"nameWithOwner":"alexec/Agents"},
   "labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,"commentCount":{"totalCount":0},
   "parent":{"number":3265,"repository":{"nameWithOwner":"alexec/Agents"}},"subIssuesSummary":{"total":0,"completed":0},
   "blockedBy":{"nodes":[{"number":3267,"state":"CLOSED","repository":{"nameWithOwner":"alexec/Agents"}},{"number":9,"state":"OPEN","repository":{"nameWithOwner":"alexec/web"}},{}]}},
  {}]}}}}}`

// #3267: one query reads an epic, its sub-issues in GitHub's order, each with its parent and
// blockers; an empty node is left out; a missing issue is NotFound.
func TestPlanReadsSubIssuesAndBlockers(t *testing.T) {
	var query string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		query = req.Query
		if req.Variables["number"] == float64(404) {
			io.WriteString(w, `{"data":{"repository":{"issue":null}}}`)
			return
		}
		io.WriteString(w, planAnswer)
	}))
	t.Cleanup(s.Close)
	g := NewRealGitHub(s.URL, func() string { return "t" }, nil)
	p, err := g.Plan(context.Background(), "alexec/Agents", 3265)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"subIssues(first: 100)", "blockedBy(first: 50)", "subIssuesSummary { total completed }", "parent { number"} {
		if !strings.Contains(query, want) {
			t.Fatalf("query has no %s: %s", want, query)
		}
	}
	if p.Epic.Number != 3265 || p.Epic.SubTotal != 2 || p.Epic.SubDone != 1 || p.Epic.ParentRepo != "" || len(p.Children) != 2 {
		t.Fatalf("plan: %+v", p)
	}
	first, second := p.Children[0], p.Children[1]
	if first.Number != 3267 || first.State != "closed" || first.ParentNumber != 3265 || first.ParentRepo != "alexec/Agents" || len(first.BlockedBy) != 0 {
		t.Fatalf("first: %+v", first)
	}
	if len(second.BlockedBy) != 2 || second.BlockedBy[0] != (Ref{"alexec/Agents", 3267, false}) || second.BlockedBy[1] != (Ref{"alexec/web", 9, true}) {
		t.Fatalf("second's blockers: %+v", second.BlockedBy)
	}
	if _, err := g.Plan(context.Background(), "alexec/Agents", 404); err == nil || err.(*GitHubError).Kind != NotFound {
		t.Fatalf("a missing issue: %v", err)
	}
}

// #3267: a feature narrows a search to its label, with any other label.
func TestSearchQueryFeature(t *testing.T) {
	q := SearchQuery([]string{"o/r"}, SearchFilter{Label: "bug", Feature: "work"})
	if !strings.Contains(q, `label:"bug" label:"feature:work"`) {
		t.Fatalf("query: %s", q)
	}
}
