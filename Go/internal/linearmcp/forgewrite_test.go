package linearmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
)

// #3271: a new child is made in the epic's team with its parent and the labels Linear has; an
// issue there already is moved under the epic; a block is made on the blocker and taken off by
// its relation's id; a block that is there is not made again, and each write is asked again,
// not answered from the shared reads.
func TestPlanWritesOnLinear(t *testing.T) {
	var mu sync.Mutex
	var asked []string
	blocked := false
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		mu.Lock()
		defer mu.Unlock()
		q := req.Query
		switch {
		case strings.Contains(q, "issueCreate"):
			asked = append(asked, "create "+req.Variables["team"].(string)+" "+req.Variables["parent"].(string)+" "+req.Variables["title"].(string)+" "+strings.Join(anyStrings(req.Variables["labels"]), ","))
			io.WriteString(w, `{"data":{"issueCreate":{"success":true,"issue":{"identifier":"ENG-9","url":"u9"}}}}`)
		case strings.Contains(q, "parentId: $parent"):
			asked = append(asked, "parent "+req.Variables["id"].(string)+" "+req.Variables["parent"].(string))
			io.WriteString(w, `{"data":{"issueUpdate":{"success":true}}}`)
		case strings.Contains(q, "issueRelationCreate"):
			asked = append(asked, "block "+req.Variables["blocker"].(string)+" "+req.Variables["blocked"].(string))
			blocked = true
			io.WriteString(w, `{"data":{"issueRelationCreate":{"success":true}}}`)
		case strings.Contains(q, "issueRelationDelete"):
			asked = append(asked, "unblock "+req.Variables["id"].(string))
			blocked = false
			io.WriteString(w, `{"data":{"issueRelationDelete":{"success":true}}}`)
		case strings.Contains(q, "inverseRelations"):
			rel := ``
			if blocked {
				rel = `{"id":"rel-1","type":"blocks","issue":{"identifier":"ENG-6"}}`
			}
			io.WriteString(w, `{"data":{"issue":{"id":"id-7","inverseRelations":{"nodes":[`+rel+`]}}}}`)
		case strings.Contains(q, "issueLabels"):
			io.WriteString(w, `{"data":{"issueLabels":{"nodes":[{"id":"l-task","name":"Task"},{"id":"l-work","name":"feature:work"}]}}}`)
		case strings.Contains(q, "labels(first: 100)"):
			id := req.Variables["id"].(string)
			io.WriteString(w, `{"data":{"issue":{"id":"id-`+id[strings.Index(id, "-")+1:]+`","team":{"id":"team-1"},"labels":{"nodes":[]}}}}`)
		default:
			io.WriteString(w, `{"data":{}}`)
		}
	}))
	t.Cleanup(s.Close)
	l := NewRealLinear(s.URL, func() string { return "Bearer t" })
	ctx := context.Background()
	id, url, err := l.AddChild(ctx, "ENG-5", "New", []string{"task", "feature:work", "story"})
	if err != nil || id != "ENG-9" || url != "u9" {
		t.Fatalf("add: %q %q %v", id, url, err)
	}
	if err := l.SetParent(ctx, "ENG-7", "ENG-5"); err != nil {
		t.Fatal(err)
	}
	for _, b := range []bool{true, true, false, true} {
		if err := l.SetBlockedBy(ctx, "ENG-7", "ENG-6", b); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{"create team-1 id-5 New l-task,l-work", "parent ENG-7 id-5", "block id-6 id-7", "unblock rel-1", "block id-6 id-7"}
	mu.Lock()
	defer mu.Unlock()
	if !slices.Equal(asked, want) {
		t.Fatalf("asked:\n%q\nwant\n%q", asked, want)
	}
}

func anyStrings(v any) []string {
	out := []string{}
	if a, ok := v.([]any); ok {
		for _, s := range a {
			out = append(out, s.(string))
		}
	}
	return out
}
