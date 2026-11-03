package jiramcp

import (
	"context"
	"strings"
	"testing"
)

// The forge reads and writes (#3260) over a fake site.

func TestSearchJQLNarrowsByProjectStateAndFilters(t *testing.T) {
	jql := SearchJQL([]string{"ENG", "OPS"}, SearchFilter{State: "closed", Label: "bug", Feature: "work", Assignee: "Kim", Query: `say "hi"`})
	want := `project in ("ENG", "OPS") AND statusCategory = 3 AND labels = "bug" AND labels = "feature:work" AND assignee = "Kim" AND text ~ "say \"hi\"" ORDER BY updated DESC`
	if jql != want {
		t.Fatalf("jql\n%s\nwant\n%s", jql, want)
	}
	if jql := SearchJQL([]string{"ENG"}, SearchFilter{State: "all"}); jql != `project in ("ENG") ORDER BY updated DESC` {
		t.Fatalf("all: %s", jql)
	}
}

// Jira Cloud gives a token per page: a cursor after an issue in a page's middle names the page
// and how far into it, and reads it again from there.
func TestSearchOnCloudGoesOnInAPagesMiddle(t *testing.T) {
	f, j := newSite(t, true, func(_ string, body map[string]any) any {
		return map[string]any{"issues": []any{
			restIssueJSON("ENG-3", "2026-11-01T10:00:00.000+0000", map[string]any{"fixVersions": []any{map[string]any{"name": "2.4"}},
				"comment": map[string]any{"total": 3}, "parent": map[string]any{"key": "ENG-1"},
				"subtasks": []any{map[string]any{"key": "ENG-4", "fields": map[string]any{"status": map[string]any{"statusCategory": map[string]any{"key": "done"}}}},
					map[string]any{"key": "ENG-5"}},
				"status": map[string]any{"name": "Shipped", "statusCategory": map[string]any{"key": "done"}}, "assignee": alexUser}),
			restIssueJSON("ENG-2", "2026-11-01T09:00:00.000+0000", nil),
		}, "nextPageToken": "tok~2", "isLast": false}
	})
	page, err := j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, "", 1)
	if err != nil || len(page.Items) != 1 || page.Cursors[0] != "~1" || page.Next != "~1" {
		t.Fatalf("%+v %v", page, err)
	}
	i := page.Items[0]
	if i.Key != "ENG-3" || i.State != "closed" || i.Status != "Shipped" || i.Milestone != "2.4" || i.Comments != 3 || i.Parent != "ENG-1" ||
		i.SubTotal != 2 || i.SubDone != 1 || i.Author != "Alex" || len(i.Assignees) != 1 || i.UpdatedAt != "2026-11-01T10:00:00.000Z" {
		t.Fatalf("item %+v", i)
	}
	page, err = j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, page.Next, 2)
	if err != nil || len(page.Items) != 1 || page.Items[0].Key != "ENG-2" || page.Next != "tok~2~0" {
		t.Fatalf("second %+v %v", page, err)
	}
	if f.bodies[1]["nextPageToken"] != nil || f.bodies[1]["maxResults"] != float64(3) {
		t.Fatalf("the second read asks the first page again, for one more: %v", f.bodies[1])
	}
	if _, err := j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, page.Next, 2); err != nil || f.bodies[2]["nextPageToken"] != "tok~2" {
		t.Fatalf("a token with a ~ in it: %v %v", f.bodies[2], err)
	}
	if _, err := j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, "nope", 2); err == nil {
		t.Fatal("a cursor no list gave")
	}
}

// Data Center pages by startAt and says the total.
func TestSearchOnDataCenterPagesByStart(t *testing.T) {
	f, j := newSite(t, false, func(string, map[string]any) any {
		return map[string]any{"total": 5, "issues": []any{restIssueJSON("ENG-2", "2026-11-01T09:00:00.000+0000", nil)}}
	})
	page, err := j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, "3~0", 1)
	if err != nil || f.asked[0] != "POST /search" || f.bodies[0]["startAt"] != float64(3) || page.Next != "4~0" {
		t.Fatalf("%+v %v %v", page, f.bodies, err)
	}
}

// An issue's page: the description and comments Jira rendered, as Markdown, the newest page of
// comments with the cursor before it, and the transitions its workflow allows.
func TestItemPageIsMarkdownWithTransitions(t *testing.T) {
	comments, rendered := []any{}, []any{}
	for n := range 52 {
		id := string(rune('a'+n%26)) + string(rune('a'+n/26))
		comments = append(comments, map[string]any{"id": id, "body": "*text* " + id, "created": "2026-11-01T09:00:00.000+0000", "author": appUser})
		rendered = append(rendered, map[string]any{"id": id, "body": "<p><b>rendered</b> " + id + "</p>"})
	}
	f, j := newSite(t, true, func(path string, _ map[string]any) any {
		if strings.HasSuffix(path, "/transitions") {
			return map[string]any{"transitions": []any{
				map[string]any{"id": "21", "name": "Start Progress", "to": map[string]any{"statusCategory": map[string]any{"key": "indeterminate"}}},
				map[string]any{"id": "31", "name": "Done", "to": map[string]any{"statusCategory": map[string]any{"key": "done"}}},
			}}
		}
		i := restIssueJSON("ENG-3", "2026-11-01T10:00:00.000+0000", map[string]any{"description": "h2. Plain",
			"comment": map[string]any{"total": 52, "comments": comments}})
		i["renderedFields"] = map[string]any{"description": `<h2>Work</h2><p>Read <a href="https://example.com/x" class="external-link">this</a>.</p><script>x()</script>`,
			"comment": map[string]any{"comments": rendered}}
		return i
	})
	d, err := j.ItemPage(context.Background(), "ENG-3", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.asked[0], "GET /issue/ENG-3?fields=") || !strings.Contains(f.asked[0], "description") || !strings.Contains(f.asked[0], "expand=renderedFields") {
		t.Fatalf("asked %q", f.asked)
	}
	if d.Body != "## Work\n\nRead [this](https://example.com/x)." {
		t.Fatalf("body %q", d.Body)
	}
	if len(d.Thread) != 50 || d.Before != "2" || d.Thread[0].Body != "**rendered** ca" || !d.Thread[0].Bot ||
		!strings.HasSuffix(d.Thread[0].URL, "/browse/ENG-3?focusedCommentId=ca") {
		t.Fatalf("thread %d before %q first %+v", len(d.Thread), d.Before, d.Thread[0])
	}
	if len(d.Transitions) != 2 || d.Transitions[1] != (Transition{ID: "31", Name: "Done", Category: "done"}) {
		t.Fatalf("transitions %+v", d.Transitions)
	}
	older, err := j.ItemPage(context.Background(), "ENG-3", d.Before)
	if err != nil || len(older.Thread) != 2 || older.Before != "" {
		t.Fatalf("older %+v %v", older.Thread, err)
	}
}

// The writes: a comment, labels in one edit, a transition, and a close by the workflow's first
// transition to done; never from the shared answers.
func TestWritesGoToJira(t *testing.T) {
	f, j := newSite(t, true, func(path string, _ map[string]any) any {
		switch {
		case strings.HasSuffix(path, "/comment"):
			return map[string]any{"id": "77"}
		case strings.HasSuffix(path, "/transitions"):
			return map[string]any{"transitions": []any{
				map[string]any{"id": "11", "name": "Back to To Do", "to": map[string]any{"statusCategory": map[string]any{"key": "new"}}},
				map[string]any{"id": "31", "name": "Close", "to": map[string]any{"statusCategory": map[string]any{"key": "done"}}},
			}}
		}
		return nil
	})
	j.sharing = sharedFor
	ctx := context.Background()
	url, err := j.Comment(ctx, "ENG-3", "On it.")
	if err != nil || !strings.HasSuffix(url, "/browse/ENG-3?focusedCommentId=77") || f.bodies[0]["body"] != "On it." {
		t.Fatalf("comment %q %v %v", url, f.bodies, err)
	}
	if err := j.SetLabels(ctx, "ENG-3", []string{"ux"}, []string{"bug"}); err != nil || f.asked[1] != "PUT /issue/ENG-3" {
		t.Fatalf("labels %v %v", f.asked, err)
	}
	if ops := f.bodies[1]["update"].(map[string]any)["labels"].([]any); len(ops) != 2 {
		t.Fatalf("label ops %v", ops)
	}
	if err := j.SetState(ctx, "ENG-3", true); err != nil {
		t.Fatal(err)
	}
	if err := j.SetState(ctx, "ENG-3", false); err != nil {
		t.Fatal(err)
	}
	var moved []any
	for n, a := range f.asked {
		if a == "POST /issue/ENG-3/transitions" {
			moved = append(moved, f.bodies[n]["transition"].(map[string]any)["id"])
		}
	}
	if len(moved) != 2 || moved[0] != "31" || moved[1] != "11" {
		t.Fatalf("moved %v (asked %v)", moved, f.asked)
	}
}

// A plan is the issue and the issues whose parent it is, each blocked by its inward Blocks links.
func TestPlanIsTheChildrenWithTheirBlockers(t *testing.T) {
	f, j := newSite(t, true, func(path string, body map[string]any) any {
		switch {
		case strings.HasSuffix(path, "/transitions"):
			return map[string]any{"transitions": []any{}}
		case path == "/search/jql":
			return map[string]any{"issues": []any{
				restIssueJSON("ENG-4", "2026-11-01T10:00:00.000+0000", nil),
				restIssueJSON("ENG-5", "2026-11-01T10:00:00.000+0000", map[string]any{"issuelinks": []any{
					map[string]any{"type": map[string]any{"name": "Blocks"}, "inwardIssue": map[string]any{"key": "ENG-4"}},
					map[string]any{"type": map[string]any{"name": "Blocks"}, "outwardIssue": map[string]any{"key": "ENG-9"}},
					map[string]any{"type": map[string]any{"name": "Relates"}, "inwardIssue": map[string]any{"key": "ENG-8"}},
				}}),
			}, "isLast": true}
		}
		return restIssueJSON("ENG-3", "2026-11-01T10:00:00.000+0000", nil)
	})
	p, err := j.Plan(context.Background(), "ENG-3")
	if err != nil || p.Epic.Key != "ENG-3" || len(p.Children) != 2 {
		t.Fatalf("%+v %v", p, err)
	}
	if b := p.Children[1].BlockedBy; len(b) != 1 || b[0] != (Ref{Key: "ENG-4", Open: true}) || len(p.Children[0].BlockedBy) != 0 {
		t.Fatalf("blockers %+v", p.Children)
	}
	for n, a := range f.asked {
		if a == "POST /search/jql" && f.bodies[n]["jql"] != `parent = "ENG-3" ORDER BY created ASC` {
			t.Fatalf("jql %v", f.bodies[n]["jql"])
		}
	}
}
