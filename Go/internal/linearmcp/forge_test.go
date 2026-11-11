package linearmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

const forgeSearchAnswer = `{"data":{"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"end"},"edges":[
 {"cursor":"c1","node":{"identifier":"ENG-4","title":"Sync the billing export","url":"https://linear.app/a/issue/ENG-4",
  "updatedAt":"2026-11-01T10:00:00.000Z","team":{"key":"ENG"},"state":{"type":"started"},"projectMilestone":{"name":"Beta"},
  "labels":{"nodes":[{"name":"Bug","color":"#EB5757"}]},"assignee":{"displayName":"alex"},"creator":{"displayName":"kim","avatarUrl":"https://public.linear.app/k/avatar"},
  "botActor":null,"commentCount":{"nodes":[{},{}]}}},
 {"cursor":"c2","node":{"identifier":"OPS-1","title":"Rotate keys","url":"u","updatedAt":"2026-11-01T09:00:00.000Z",
  "team":{"key":"OPS"},"state":{"type":"canceled"},"projectMilestone":null,"labels":{"nodes":[]},"assignee":null,
  "creator":null,"botActor":{"name":"GitHub"},"commentCount":{"nodes":[]}}},
 {"cursor":"c3","node":{}}]}}}`

const forgeItemAnswer = `{"data":{"issue":{"identifier":"ENG-4","title":"Sync the billing export","url":"u","updatedAt":"2026-11-01T10:00:00.000Z",
 "team":{"key":"ENG"},"state":{"type":"completed"},"labels":{"nodes":[]},"commentCount":{"nodes":[{}]},"description":"The body.",
 "comments":{"pageInfo":{"hasNextPage":true,"endCursor":"older"},"nodes":[
  {"body":"Newest.","createdAt":"2026-11-01T10:02:00.000Z","url":"c2","user":null,"botActor":{"name":"GitHub"}},
  {"body":"Oldest.","createdAt":"2026-11-01T10:01:00.000Z","url":"c1","user":{"displayName":"kim","avatarUrl":"https://public.linear.app/k/avatar"}}]}}}}`

func forgeLinear(t *testing.T) (*RealLinear, *[]map[string]any) {
	var mu sync.Mutex
	var asked []map[string]any
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		mu.Lock()
		asked = append(asked, req.Variables)
		mu.Unlock()
		switch {
		case strings.Contains(req.Query, "ForgeIssues"):
			io.WriteString(w, forgeSearchAnswer)
		case req.Variables["id"] == "ENG-4":
			io.WriteString(w, forgeItemAnswer)
		default:
			io.WriteString(w, `{"data":{"issue":null}}`)
		}
	}))
	t.Cleanup(s.Close)
	l := NewRealLinear(s.URL, func() string { return "Bearer t" })
	l.sharing = 0
	return l, &asked
}

// #3209: one query for every team, by key; each issue in the model the daemon maps, with the
// cursor after it; an empty node left out.
func TestForgeSearchListsManyTeamsInOneQuery(t *testing.T) {
	l, asked := forgeLinear(t)
	p, err := l.Search(context.Background(), []string{"ENG", "OPS"}, SearchFilter{State: "all", Label: "Bug", Assignee: "alex", Query: "billing"}, "c0", 500)
	if err != nil {
		t.Fatal(err)
	}
	if len(*asked) != 1 || (*asked)[0]["after"] != "c0" || (*asked)[0]["first"] != float64(100) {
		t.Fatalf("asked: %v", *asked)
	}
	filter, _ := json.Marshal((*asked)[0]["filter"])
	for _, want := range []string{`"team":{"key":{"in":["ENG","OPS"]}}`, `"labels":{"name":{"eq":"Bug"}}`, `"assignee":{"displayName":{"eqIgnoreCase":"alex"}}`,
		`"title":{"containsIgnoreCase":"billing"}`} {
		if !strings.Contains(string(filter), want) {
			t.Fatalf("filter %s has no %s", filter, want)
		}
	}
	if strings.Contains(string(filter), `"state"`) {
		t.Fatalf("state all has a state: %s", filter)
	}
	if len(p.Items) != 2 || p.Next != "end" || len(p.Cursors) != 2 || p.Cursors[1] != "c2" {
		t.Fatalf("page: %+v", p)
	}
	i := p.Items[0]
	if i.Identifier != "ENG-4" || i.Team != "ENG" || i.State != "open" || i.Milestone != "Beta" || i.Author != "kim" || i.AuthorAvatar != "https://public.linear.app/k/avatar" || i.Comments != 2 ||
		i.LabelColors["Bug"] != "#eb5757" || len(i.Assignees) != 1 {
		t.Fatalf("first: %+v", i)
	}
	if b := p.Items[1]; b.State != "closed" || b.Author != "GitHub" || b.Assignees == nil {
		t.Fatalf("second: %+v", b)
	}
	if open := SearchFilterOf([]string{"ENG"}, SearchFilter{}); open["state"] == nil {
		t.Fatalf("open has no state: %v", open)
	}
}

// #3311: no teams is the whole workspace, one query with no team in its filter.
func TestForgeSearchListsTheWholeWorkspace(t *testing.T) {
	l, asked := forgeLinear(t)
	p, err := l.Search(context.Background(), nil, SearchFilter{}, "", 50)
	if err != nil {
		t.Fatal(err)
	}
	filter, _ := json.Marshal((*asked)[0]["filter"])
	if len(*asked) != 1 || (*asked)[0]["first"] != float64(50) || strings.Contains(string(filter), `"team"`) || len(p.Items) != 2 {
		t.Fatalf("asked %v, filter %s, page %+v", *asked, filter, p)
	}
}

// One issue: its description and the newest page of its comments, oldest first, with the cursor
// of the page before it; an issue Linear does not have says so.
func TestForgeItemPage(t *testing.T) {
	l, _ := forgeLinear(t)
	d, err := l.ItemPage(context.Background(), "ENG-4", "")
	if err != nil {
		t.Fatal(err)
	}
	if d.Body != "The body." || d.State != "closed" || d.Before != "older" || len(d.Thread) != 2 {
		t.Fatalf("detail: %+v", d)
	}
	if d.Thread[0].Body != "Oldest." || d.Thread[0].Author != "kim" || d.Thread[0].Avatar != "https://public.linear.app/k/avatar" || d.Thread[1].Avatar != "" || d.Thread[1].Author != "GitHub" || !d.Thread[1].Bot {
		t.Fatalf("thread: %+v", d.Thread)
	}
	if _, err := l.ItemPage(context.Background(), "ENG-404", ""); err == nil {
		t.Fatal("an issue Linear does not have was read")
	} else if le, ok := err.(*LinearError); !ok || le.Kind != NotFound {
		t.Fatalf("not found: %v", err)
	}
}

// A closed issue's state says why it closed (#4365).
func TestStateReasonOf(t *testing.T) {
	for _, c := range []struct{ stateType, name, want string }{
		{"completed", "Done", "completed"},
		{"canceled", "Canceled", "not_planned"},
		{"canceled", "Duplicate", "duplicate"},
	} {
		if got := stateReasonOf(c.stateType, c.name); got != c.want {
			t.Errorf("%s %s: %q, want %q", c.stateType, c.name, got, c.want)
		}
	}
}

// #4373: an issue says when it was made, and a completed or canceled one when it closed.
func TestItemDates(t *testing.T) {
	for _, c := range []struct {
		json, closed string
	}{
		{`{"state":{"type":"started"},"createdAt":"2026-10-01T10:00:00.000Z"}`, ""},
		{`{"state":{"type":"completed"},"createdAt":"2026-10-01T10:00:00.000Z","completedAt":"2026-10-02T10:00:00.000Z"}`, "2026-10-02T10:00:00.000Z"},
		{`{"state":{"type":"canceled"},"createdAt":"2026-10-01T10:00:00.000Z","canceledAt":"2026-10-03T10:00:00.000Z"}`, "2026-10-03T10:00:00.000Z"},
	} {
		var n forgeNode
		if err := json.Unmarshal([]byte(c.json), &n); err != nil {
			t.Fatal(err)
		}
		if i := n.item(); i.CreatedAt != "2026-10-01T10:00:00.000Z" || i.ClosedAt != c.closed {
			t.Errorf("%s: %q %q", c.json, i.CreatedAt, i.ClosedAt)
		}
	}
}
