package gitlabmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

const hierarchyAnswer = `{"data":{"project":{"workItems":{"nodes":[{"widgets":[{"__typename":"WorkItemWidgetLabels"},
 {"__typename":"WorkItemWidgetHierarchy","parent":null,"children":{"nodes":[
  {"iid":"6","state":"OPEN","namespace":{"fullPath":"group/app"},"widgets":[{},{"linkedItems":{"nodes":[
   {"linkType":"is_blocked_by","workItem":{"iid":"7","state":"OPEN","namespace":{"fullPath":"group/app"}}},
   {"linkType":"relates_to","workItem":{"iid":"8","state":"OPEN","namespace":{"fullPath":"group/app"}}},
   {"linkType":"is_blocked_by","workItem":{"iid":"2","state":"CLOSED","namespace":{"fullPath":"group/lib"}}}]}}]},
  {"iid":"7","state":"CLOSED","namespace":{"fullPath":"group/app"},"widgets":[]},
  {"iid":"3","state":"OPEN","namespace":{"fullPath":"group/lib"},"widgets":[]},
  {"iid":"x","state":"OPEN","namespace":null}]}}]}]}}}}`

// #3267: a plan is one GraphQL query for the hierarchy and the "blocked by" links, the epic by
// REST, and one REST list for each project its children are in; a child GitLab does not list
// keeps what the hierarchy said.
func TestPlanReadsWorkItemsAndLinks(t *testing.T) {
	var mu sync.Mutex
	var asked []string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		asked = append(asked, r.Method+" "+r.URL.EscapedPath()+"?"+r.URL.RawQuery)
		mu.Unlock()
		switch r.URL.EscapedPath() {
		case "/api/graphql":
			var req struct {
				Variables map[string]any `json:"variables"`
			}
			body, _ := io.ReadAll(r.Body)
			json.Unmarshal(body, &req)
			if req.Variables["path"] != "group/app" || req.Variables["iid"] != "5" {
				io.WriteString(w, `{"data":{"project":null}}`)
				return
			}
			io.WriteString(w, hierarchyAnswer)
		case "/api/v4/projects/group%2Fapp/issues/5":
			json.NewEncoder(w).Encode(obj{"iid": 5, "title": "Epic", "state": "opened", "labels": []string{"epic"}})
		case "/api/v4/projects/group%2Fapp/issues":
			json.NewEncoder(w).Encode([]obj{forgeItemJSON(7, "closed", "2026-11-02T09:00:00Z"), forgeItemJSON(6, "opened", "2026-11-02T08:00:00Z")})
		case "/api/v4/projects/group%2Flib/issues":
			json.NewEncoder(w).Encode([]obj{})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	g.sharing = 0
	p, err := g.Plan(context.Background(), "group/app", 5)
	if err != nil {
		t.Fatal(err)
	}
	if p.Epic.Title != "Epic" || p.Epic.SubTotal != 3 || p.Epic.SubDone != 1 || len(p.Children) != 3 {
		t.Fatalf("plan: %+v", p)
	}
	six := p.Children[0]
	if six.Number != 6 || six.Title != "Item 6" || six.ParentProject != "group/app" || six.ParentNumber != 5 ||
		len(six.BlockedBy) != 2 || six.BlockedBy[0] != (Ref{"group/app", 7, true}) || six.BlockedBy[1] != (Ref{"group/lib", 2, false}) {
		t.Fatalf("six: %+v", six)
	}
	if lib := p.Children[2]; lib.Project != "group/lib" || lib.Number != 3 || lib.State != "open" || lib.Title != "" {
		t.Fatalf("a child GitLab does not list: %+v", lib)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(asked) != 4 || !strings.Contains(asked[2], "iids%5B%5D=6&iids%5B%5D=7") || !strings.HasPrefix(asked[1], "POST /api/graphql") {
		t.Fatalf("asked: %q", asked)
	}
}

// #3267: GitLab's labels are all of them, by commas: a label and a feature.
func TestListPathFeature(t *testing.T) {
	if p := listPath("group/app", SearchFilter{Label: "bug", Feature: "work"}, "opened", "", 20); !strings.Contains(p, "labels=bug%2Cfeature%3Awork") {
		t.Fatalf("path: %s", p)
	}
}

// #3282: a group board's scope is labels and a milestone, beside the list's own label.
func TestListPathBoard(t *testing.T) {
	p := listPath("group/app", SearchFilter{Label: "bug", Board: BoardScope{Labels: []string{"team-a"}, Milestone: "0.17"}}, "opened", "", 20)
	if !strings.Contains(p, "labels=bug%2Cteam-a") || !strings.Contains(p, "milestone=0.17") {
		t.Fatalf("path: %s", p)
	}
}

// #4242: Blockers are many work items' "blocked by" links in one GraphQL query, by their iids.
func TestBlockersReadManyWorkItems(t *testing.T) {
	var asked []map[string]any
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		asked = append(asked, req.Variables)
		io.WriteString(w, `{"data":{"project":{"workItems":{"nodes":[
 {"iid":"6","widgets":[{},{"linkedItems":{"nodes":[
  {"linkType":"is_blocked_by","workItem":{"iid":"7","state":"OPEN","namespace":{"fullPath":"group/app"}}},
  {"linkType":"blocks","workItem":{"iid":"8","state":"OPEN","namespace":{"fullPath":"group/app"}}},
  {"linkType":"is_blocked_by","workItem":{"iid":"2","state":"CLOSED","namespace":{"fullPath":"group/lib"}}}]}}]},
 {"iid":"9","widgets":[]}]}}}}`)
	}))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	g.sharing = 0
	by, err := g.Blockers(context.Background(), "group/app", []int{6, 9})
	if err != nil {
		t.Fatal(err)
	}
	if len(by[6]) != 2 || by[6][0] != (Ref{"group/app", 7, true}) || by[6][1] != (Ref{"group/lib", 2, false}) || by[9] == nil || len(by[9]) != 0 {
		t.Fatalf("blockers: %+v", by)
	}
	if len(asked) != 1 || asked[0]["path"] != "group/app" || fmt.Sprint(asked[0]["iids"]) != "[6 9]" || asked[0]["first"] != float64(2) {
		t.Fatalf("asked: %v", asked)
	}
}
