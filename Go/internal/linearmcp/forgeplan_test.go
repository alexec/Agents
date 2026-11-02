package linearmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const planAnswer = `{"data":{"issue":{"identifier":"ENG-5","title":"Epic","url":"u","updatedAt":"2026-11-02T10:00:00.000Z","team":{"key":"ENG"},
 "state":{"type":"started"},"labels":{"nodes":[{"name":"Epic"}]},"commentCount":{"nodes":[]},"parent":null,
 "children":{"nodes":[{"state":{"type":"completed"}},{"state":{"type":"started"}}]},
 "plan":{"nodes":[
  {"identifier":"ENG-6","title":"First","url":"u6","updatedAt":"2026-11-02T09:00:00.000Z","team":{"key":"ENG"},"state":{"type":"completed"},
   "labels":{"nodes":[]},"commentCount":{"nodes":[]},"parent":{"identifier":"ENG-5"},"children":{"nodes":[]},"inverseRelations":{"nodes":[]}},
  {"identifier":"ENG-7","title":"Second","url":"u7","updatedAt":"2026-11-02T08:00:00.000Z","team":{"key":"ENG"},"state":{"type":"backlog"},
   "labels":{"nodes":[]},"commentCount":{"nodes":[]},"parent":{"identifier":"ENG-5"},"children":{"nodes":[]},"inverseRelations":{"nodes":[
    {"type":"blocks","issue":{"identifier":"ENG-6","state":{"type":"completed"}}},
    {"type":"related","issue":{"identifier":"ENG-9","state":{"type":"started"}}},
    {"type":"blocks","issue":{"identifier":"OPS-1","state":{"type":"started"}}}]}},
  {}]}}}}`

// #3267: one query reads an epic, its children in Linear's order with their parent, and each
// child's blockers (the issues of its "blocks" inverse relations); the epic counts its children.
func TestPlanReadsChildrenAndBlockers(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		if !strings.Contains(req.Query, "ForgePlan") || req.Variables["id"] != "ENG-5" {
			io.WriteString(w, `{"data":{"issue":null}}`)
			return
		}
		io.WriteString(w, planAnswer)
	}))
	t.Cleanup(s.Close)
	l := NewRealLinear(s.URL, func() string { return "Bearer t" })
	l.sharing = 0
	p, err := l.Plan(context.Background(), "ENG-5")
	if err != nil {
		t.Fatal(err)
	}
	if p.Epic.SubTotal != 2 || p.Epic.SubDone != 1 || p.Epic.Parent != "" || len(p.Children) != 2 {
		t.Fatalf("plan: %+v", p)
	}
	if c := p.Children[0]; c.Identifier != "ENG-6" || c.State != "closed" || c.Parent != "ENG-5" || len(c.BlockedBy) != 0 {
		t.Fatalf("first: %+v", c)
	}
	if b := p.Children[1].BlockedBy; len(b) != 2 || b[0] != (Ref{"ENG-6", false}) || b[1] != (Ref{"OPS-1", true}) {
		t.Fatalf("second's blockers: %+v", b)
	}
	if _, err := l.Plan(context.Background(), "ENG-404"); err == nil || err.(*LinearError).Kind != NotFound {
		t.Fatalf("a missing issue: %v", err)
	}
}

// #3267: a label and a feature are each a filter, so an issue has both.
func TestSearchFilterFeature(t *testing.T) {
	both, _ := json.Marshal(SearchFilterOf([]string{"ENG"}, SearchFilter{Label: "Bug", Feature: "work"}))
	if !strings.Contains(string(both), `"and":[{"labels":{"name":{"eq":"Bug"}}},{"labels":{"name":{"eq":"feature:work"}}}]`) ||
		strings.Contains(string(both), `"labels":{"name":{"eq":"Bug"}},`) {
		t.Fatalf("filter: %s", both)
	}
	one, _ := json.Marshal(SearchFilterOf([]string{"ENG"}, SearchFilter{Feature: "work"}))
	if !strings.Contains(string(one), `"labels":{"name":{"eq":"feature:work"}}`) || strings.Contains(string(one), `"and"`) {
		t.Fatalf("filter: %s", one)
	}
}
