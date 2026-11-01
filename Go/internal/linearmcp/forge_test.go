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
  "labels":{"nodes":[{"name":"Bug","color":"#EB5757"}]},"assignee":{"displayName":"alex"},"creator":{"displayName":"kim"},
  "botActor":null,"commentCount":{"nodes":[{},{}]}}},
 {"cursor":"c2","node":{"identifier":"OPS-1","title":"Rotate keys","url":"u","updatedAt":"2026-11-01T09:00:00.000Z",
  "team":{"key":"OPS"},"state":{"type":"canceled"},"projectMilestone":null,"labels":{"nodes":[]},"assignee":null,
  "creator":null,"botActor":{"name":"GitHub"},"commentCount":{"nodes":[]}}},
 {"cursor":"c3","node":{}}]}}}`

const forgeItemAnswer = `{"data":{"issue":{"identifier":"ENG-4","title":"Sync the billing export","url":"u","updatedAt":"2026-11-01T10:00:00.000Z",
 "team":{"key":"ENG"},"state":{"type":"completed"},"labels":{"nodes":[]},"commentCount":{"nodes":[{}]},"description":"The body.",
 "comments":{"pageInfo":{"hasNextPage":true,"endCursor":"older"},"nodes":[
  {"body":"Newest.","createdAt":"2026-11-01T10:02:00.000Z","url":"c2","user":null,"botActor":{"name":"GitHub"}},
  {"body":"Oldest.","createdAt":"2026-11-01T10:01:00.000Z","url":"c1","user":{"displayName":"kim"}}]}}}}`

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
	if i.Identifier != "ENG-4" || i.Team != "ENG" || i.State != "open" || i.Milestone != "Beta" || i.Author != "kim" || i.Comments != 2 ||
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
	if d.Thread[0].Body != "Oldest." || d.Thread[0].Author != "kim" || d.Thread[1].Author != "GitHub" || !d.Thread[1].Bot {
		t.Fatalf("thread: %+v", d.Thread)
	}
	if _, err := l.ItemPage(context.Background(), "ENG-404", ""); err == nil {
		t.Fatal("an issue Linear does not have was read")
	} else if le, ok := err.(*LinearError); !ok || le.Kind != NotFound {
		t.Fatalf("not found: %v", err)
	}
}
