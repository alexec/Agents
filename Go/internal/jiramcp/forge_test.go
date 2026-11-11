package jiramcp

import (
	"context"
	"encoding/json"
	"slices"
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
// and how far into it, and reads it again from there. The first page counts the list, by Jira
// Cloud's approximate count (#4396).
func TestSearchOnCloudGoesOnInAPagesMiddle(t *testing.T) {
	f, j := newSite(t, true, func(path string, body map[string]any) any {
		if path == "/search/approximate-count" {
			return map[string]any{"count": 7}
		}
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
	if err != nil || len(page.Items) != 1 || page.Cursors[0] != "~1" || page.Next != "~1" || page.Total == nil || *page.Total != 7 {
		t.Fatalf("%+v %v", page, err)
	}
	if f.asked[1] != "POST /search/approximate-count" || f.bodies[1]["jql"] != f.bodies[0]["jql"] {
		t.Fatalf("count: %v %v", f.asked, f.bodies[1])
	}
	i := page.Items[0]
	if i.Key != "ENG-3" || i.State != "closed" || i.Status != "Shipped" || i.Milestone != "2.4" || i.Comments != 3 || i.Parent != "ENG-1" ||
		i.SubTotal != 2 || i.SubDone != 1 || i.Author != "Alex" || i.AuthorAvatar != "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/u1/48" || len(i.Assignees) != 1 || i.UpdatedAt != "2026-11-01T10:00:00.000Z" {
		t.Fatalf("item %+v", i)
	}
	page, err = j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, page.Next, 2)
	if err != nil || len(page.Items) != 1 || page.Items[0].Key != "ENG-2" || page.Next != "tok~2~0" || page.Total != nil {
		t.Fatalf("second %+v %v", page, err)
	}
	if f.bodies[2]["nextPageToken"] != nil || f.bodies[2]["maxResults"] != float64(3) {
		t.Fatalf("the second read asks the first page again, for one more: %v", f.bodies[2])
	}
	if _, err := j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, page.Next, 2); err != nil || f.bodies[3]["nextPageToken"] != "tok~2" {
		t.Fatalf("a token with a ~ in it: %v %v", f.bodies[3], err)
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
	if err != nil || f.asked[0] != "POST /search" || f.bodies[0]["startAt"] != float64(3) || page.Next != "4~0" || page.Total != nil {
		t.Fatalf("%+v %v %v", page, f.bodies, err)
	}
	// Data Center counts with the first page itself (#4396).
	if page, err = j.Search(context.Background(), []string{"ENG"}, SearchFilter{}, "", 1); err != nil || page.Total == nil || *page.Total != 5 || len(f.asked) != 2 {
		t.Fatalf("first page %+v %v %v", page, f.asked, err)
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

// #4242: Blockers are many issues' inward Blocks links, in one search by key.
func TestBlockersSearchByKey(t *testing.T) {
	f, j := newSite(t, true, func(path string, body map[string]any) any {
		return map[string]any{"issues": []any{
			restIssueJSON("ENG-5", "2026-11-01T10:00:00.000+0000", map[string]any{"issuelinks": []any{
				map[string]any{"type": map[string]any{"name": "Blocks"}, "inwardIssue": map[string]any{"key": "ENG-4"}},
				map[string]any{"type": map[string]any{"name": "Blocks"}, "outwardIssue": map[string]any{"key": "ENG-9"}},
			}}),
			restIssueJSON("ENG-6", "2026-11-01T10:00:00.000+0000", nil),
		}, "isLast": true}
	})
	by, err := j.Blockers(context.Background(), []string{"ENG-5", "ENG-6"})
	if err != nil || len(by["ENG-5"]) != 1 || by["ENG-5"][0] != (Ref{Key: "ENG-4", Open: true}) || len(by["ENG-6"]) != 0 {
		t.Fatalf("%+v %v", by, err)
	}
	if _, ok := by["ENG-6"]; !ok || len(f.asked) != 1 || f.asked[0] != "POST /search/jql" || f.bodies[0]["jql"] != `key in ("ENG-5", "ENG-6")` {
		t.Fatalf("by %+v, asked %q %v", by, f.asked, f.bodies)
	}
}

// #3282: a board's issues are its filter's, in place of the projects', read from Jira
// Software's API.
func TestABoardIsItsFilter(t *testing.T) {
	if jql := SearchJQL(nil, SearchFilter{Filter: "10040", Label: "bug"}); jql != `filter = 10040 AND statusCategory != 3 AND labels = "bug" ORDER BY updated DESC` {
		t.Fatalf("jql: %s", jql)
	}
	f, j := newSite(t, true, func(path string, _ map[string]any) any {
		if path == "/rest/agile/1.0/board/12/configuration" {
			return map[string]any{"id": 12, "filter": map[string]any{"id": "10040"}}
		}
		return map[string]any{"filter": map[string]any{}}
	})
	if id, err := j.BoardFilter(context.Background(), "12"); err != nil || id != "10040" {
		t.Fatalf("%q %v", id, err)
	}
	if _, err := j.BoardFilter(context.Background(), "13"); err == nil {
		t.Fatal("a board with no filter")
	}
	if _, err := j.BoardFilter(context.Background(), "../x"); err == nil {
		t.Fatal("a board id that is not a number")
	}
	if len(f.asked) != 2 || f.asked[0] != "GET /rest/agile/1.0/board/12/configuration" {
		t.Fatalf("asked %q", f.asked)
	}
}

// A done issue's resolution says why it closed (#4365).
func TestStateReasonOf(t *testing.T) {
	for _, c := range []struct{ resolution, want string }{
		{"Done", "completed"}, {"Fixed", "completed"}, {"", "completed"},
		{"Duplicate", "duplicate"}, {"Won't Do", "not_planned"}, {"Cannot Reproduce", "not_planned"},
	} {
		if got := stateReasonOf(c.resolution); got != c.want {
			t.Errorf("%q: %q, want %q", c.resolution, got, c.want)
		}
	}
}

// #4373: an issue says when it was made, and a done one its resolution date.
func TestItemDates(t *testing.T) {
	for category, closed := range map[string]bool{"indeterminate": false, "done": true} {
		var r restIssue
		if err := json.Unmarshal([]byte(`{"key":"ENG-1","fields":{"status":{"name":"S","statusCategory":{"key":"`+category+`"}},
			"created":"2026-10-01T10:00:00.000+0000","resolutiondate":"2026-10-02T10:00:00.000+0000"}}`), &r); err != nil {
			t.Fatal(err)
		}
		i := r.item("https://acme.atlassian.net")
		if i.CreatedAt != normalized("2026-10-01T10:00:00.000+0000") || i.CreatedAt == "" ||
			(i.ClosedAt == normalized("2026-10-02T10:00:00.000+0000")) != closed || closed && i.ClosedAt == "" {
			t.Errorf("%s: %q %q", category, i.CreatedAt, i.ClosedAt)
		}
	}
}

// #4626: an issue's read has its sub-tasks and the issues whose parent it is, each once, from
// one search more, and its changelog's label, assignee and resolution changes, oldest first.
func TestItemPageHasChildrenAndEvents(t *testing.T) {
	change := func(created string, items ...map[string]any) map[string]any {
		return map[string]any{"id": created, "created": created, "author": alexUser, "items": items}
	}
	f, j := newSite(t, true, func(path string, body map[string]any) any {
		switch {
		case strings.HasSuffix(path, "/transitions"):
			return map[string]any{"transitions": []any{}}
		case path == "/search/jql":
			return map[string]any{"issues": []any{
				restIssueJSON("ENG-5", "2026-11-01T10:00:00.000+0000", map[string]any{"summary": "Sub-task"}),
				restIssueJSON("ENG-6", "2026-11-01T10:00:00.000+0000", map[string]any{"summary": "Story",
					"status": map[string]any{"name": "Done", "statusCategory": map[string]any{"key": "done"}}}),
			}, "isLast": true}
		}
		i := restIssueJSON("ENG-3", "2026-11-01T10:00:00.000+0000", map[string]any{"subtasks": []any{
			map[string]any{"key": "ENG-5", "fields": map[string]any{"summary": "Sub-task", "status": map[string]any{"statusCategory": map[string]any{"key": "new"}}}}}})
		i["changelog"] = map[string]any{"histories": []any{
			change("2026-11-03T10:00:00.000+0000", map[string]any{"field": "resolution", "to": "10000", "toString": "Done"}),
			change("2026-11-02T10:00:00.000+0000",
				map[string]any{"field": "labels", "fromString": "bug ui", "toString": "bug api"},
				map[string]any{"field": "assignee", "fromString": "Kim", "toString": "Alex"},
				map[string]any{"field": "summary", "fromString": "a", "toString": "b"}),
			change("2026-11-04T10:00:00.000+0000", map[string]any{"field": "resolution", "fromString": "Done"},
				map[string]any{"field": "assignee", "fromString": "Alex"}),
		}}
		return i
	})
	d, err := j.ItemPage(context.Background(), "ENG-3", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.asked[0], "expand=renderedFields%2Cchangelog") && !strings.Contains(f.asked[0], "expand=renderedFields,changelog") {
		t.Fatalf("asked %q", f.asked[0])
	}
	if len(f.asked) != 3 || f.bodies[2]["jql"] != `parent = "ENG-3" ORDER BY created ASC` {
		t.Fatalf("reads %q %v", f.asked, f.bodies)
	}
	site := j.Auth().Site
	want := []Child{{Key: "ENG-5", Title: "Sub-task", URL: site + "/browse/ENG-5", State: "open"},
		{Key: "ENG-6", Title: "Story", URL: site + "/browse/ENG-6", State: "closed"}}
	if !slices.Equal(d.Children, want) {
		t.Fatalf("children %+v", d.Children)
	}
	at := func(day string) string { return normalized("2026-11-0" + day + "T10:00:00.000+0000") }
	events := []Event{
		{Kind: "labeled", Actor: "Alex", At: at("2"), Label: "api"}, {Kind: "unlabeled", Actor: "Alex", At: at("2"), Label: "ui"},
		{Kind: "unassigned", Actor: "Alex", At: at("2"), Assignee: "Kim"}, {Kind: "assigned", Actor: "Alex", At: at("2"), Assignee: "Alex"},
		{Kind: "closed", Actor: "Alex", At: at("3")},
		{Kind: "reopened", Actor: "Alex", At: at("4")}, {Kind: "unassigned", Actor: "Alex", At: at("4"), Assignee: "Alex"},
	}
	if !slices.Equal(d.Events, events) {
		t.Fatalf("events %+v", d.Events)
	}
	// A plan reads its children itself: its epic's read makes no search for them.
	f.asked = nil
	if _, err := j.Plan(context.Background(), "ENG-3"); err != nil {
		t.Fatal(err)
	}
	if n := len(f.asked); n != 3 {
		t.Fatalf("plan reads %q", f.asked)
	}
}
