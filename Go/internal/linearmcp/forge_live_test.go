//go:build live

package linearmcp

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// The forge's reads, writes and plans on a real Linear workspace (#3412), run by hand, never by CI:
//
//	AGENTS_LIVE_LINEAR_KEY=lin_api_… AGENTS_LIVE_LINEAR_TEAM=AGE go test -tags live -run Live -v ./internal/linearmcp/
//
// The key is a personal API key, or the access token of a Linear sign-in. The test opens an
// epic and two children in the team, the second blocked by the first, and closes all three.

func TestLiveLinearForge(t *testing.T) {
	key, team := os.Getenv("AGENTS_LIVE_LINEAR_KEY"), os.Getenv("AGENTS_LIVE_LINEAR_TEAM")
	if key == "" || team == "" {
		t.Skip("AGENTS_LIVE_LINEAR_KEY and AGENTS_LIVE_LINEAR_TEAM are not set")
	}
	l := NewRealLinear("", func() string { return key })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	stamp := time.Now().UTC().Format("2006-01-02 15:04")
	var opened []string
	t.Cleanup(func() {
		for _, id := range opened {
			if err := l.SetState(context.Background(), id, true); err != nil {
				t.Errorf("close %s: %v", id, err)
			}
		}
	})

	// The plan (#3265, #3271): an epic, two children by Add child, the second blocked by the first.
	var teams struct {
		Teams struct{ Nodes []struct{ ID string } } `json:"teams"`
	}
	if err := l.query(ctx, `query($key: String!) { teams(filter: {key: {eq: $key}}) { nodes { id } } }`,
		map[string]any{"key": team}, &teams); err != nil || len(teams.Teams.Nodes) != 1 {
		t.Fatalf("team %s: %+v, %v", team, teams, err)
	}
	var made struct {
		IssueCreate struct {
			Issue struct{ Identifier, URL string } `json:"issue"`
		} `json:"issueCreate"`
	}
	if err := l.query(ctx, `mutation($team: String!, $title: String!) { issueCreate(input: {teamId: $team, title: $title}) { issue { identifier url } } }`,
		map[string]any{"team": teams.Teams.Nodes[0].ID, "title": "Live #3412: an epic (" + stamp + ")"}, &made); err != nil {
		t.Fatalf("create the epic: %v", err)
	}
	epic := made.IssueCreate.Issue.Identifier
	opened = append(opened, epic)
	t.Logf("epic %s", made.IssueCreate.Issue.URL)
	var kids []string
	for _, name := range []string{"first", "second"} {
		id, _, err := l.AddChild(ctx, epic, "Live #3412: the "+name+" child ("+stamp+")", nil)
		if err != nil {
			t.Fatalf("add a child: %v", err)
		}
		opened = append(opened, id)
		kids = append(kids, id)
	}
	if err := l.SetBlockedBy(ctx, kids[1], kids[0], true); err != nil {
		t.Fatalf("blocked by: %v", err)
	}
	plan, err := l.Plan(ctx, epic)
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	if len(plan.Children) != 2 {
		t.Fatalf("the plan's children = %+v, want %v", plan.Children, kids)
	}
	second := slices.IndexFunc(plan.Children, func(c PlanChild) bool { return c.Identifier == kids[1] })
	if second < 0 || len(plan.Children[second].BlockedBy) != 1 || plan.Children[second].BlockedBy[0].Identifier != kids[0] {
		t.Fatalf("the plan = %+v, want %s blocked by %s", plan.Children, kids[1], kids[0])
	}
	if err := l.SetBlockedBy(ctx, kids[1], kids[0], false); err != nil {
		t.Fatalf("not blocked by: %v", err)
	}

	// The writes (#3130) on the epic: a comment, labels (the first the team has), close and reopen.
	if _, err := l.Comment(ctx, epic, "A comment from the forge's live test (#3412)."); err != nil {
		t.Fatalf("comment: %v", err)
	}
	labels, _, err := l.Labels(ctx, epic)
	if err != nil {
		t.Fatalf("labels: %v", err)
	}
	if len(labels) > 0 {
		if err := l.SetLabels(ctx, epic, labels[:1], nil); err != nil {
			t.Fatalf("set labels: %v", err)
		}
	}
	if err := l.SetState(ctx, epic, true); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := l.SetState(ctx, epic, false); err != nil {
		t.Fatalf("reopen: %v", err)
	}

	// The reads (#3129, #3209): the epic in the team's list, and its own page with the comment.
	page, err := l.Search(ctx, []string{team}, SearchFilter{Query: "Live #3412: an epic (" + stamp + ")"}, "", 20)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !slices.ContainsFunc(page.Items, func(i Item) bool { return i.Identifier == epic }) {
		t.Fatalf("the list found %+v, not %s", page.Items, epic)
	}
	item, err := l.ItemPage(ctx, epic, "")
	if err != nil {
		t.Fatalf("the epic's page: %v", err)
	}
	if item.State != "open" || item.SubTotal != 2 ||
		!slices.ContainsFunc(item.Thread, func(c Comment) bool { return strings.Contains(c.Body, "live test (#3412)") }) {
		t.Fatalf("the epic's page = %+v", item)
	}
}
