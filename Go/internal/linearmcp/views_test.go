package linearmcp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// The view's reads, over answers in Linear's shape (testdata/OpenIssues.json, Teams.json).

type fakeViews struct{}

// The viewer is alex (u1): ENG-5 is assigned to alex, ENG-6 is by alex, ENG-8 by an app, ENG-9 by a guest.
func (fakeViews) OpenIssues(_ context.Context, team, _, _ string) ([]ListedIssue, *Person, error) {
	alex, sam := &Person{ID: "u1", Name: "alex"}, &Person{ID: "u2", Name: "sam"}
	return []ListedIssue{
		{Issue: Issue{ID: "7d1c", Identifier: "ENG-5", Title: "Crash", Team: team, StateType: "started", AssigneeID: "u1", Creator: sam},
			Priority: "High", UpdatedAt: "2026-10-19T10:00:00.000Z"},
		{Issue: Issue{ID: "7d1d", Identifier: "ENG-6", Title: "Mine", Team: team, Creator: alex}},
		{Issue: Issue{ID: "7d1e", Identifier: "ENG-8", Title: "From Sentry", Team: team, Creator: &Person{Name: "Sentry", App: true}}},
		{Issue: Issue{ID: "7d1f", Identifier: "ENG-9", Title: "From a guest", Team: team, Creator: &Person{ID: "u9", Name: "kim", Guest: true}}},
	}, alex, nil
}

func (fakeViews) Teams(context.Context) ([]Team, error) {
	return []Team{{Key: "ENG", Name: "Engineering"}}, nil
}

func (fakeViews) IssueDetails(_ context.Context, identifier string) (map[string]any, error) {
	return map[string]any{"identifier": identifier, "description": "**Text**", "descriptionHTML": "<p><strong>Text</strong></p>\n"}, nil
}

func TestTheViewListsOpenIssues(t *testing.T) {
	r, l := newRecorded(t)
	list, viewer, err := l.OpenIssues(context.Background(), "ENG", "", "Bug")
	if err != nil || len(list) != 2 {
		t.Fatalf("%v %v", list, err)
	}
	if viewer == nil || viewer.ID != "u1" || viewer.Name != "alex" {
		t.Fatalf("the viewer comes in the same query: %+v", viewer)
	}
	filter, _ := json.Marshal(r.asked[0]["filter"])
	if string(filter) != `{"labels":{"name":{"eq":"Bug"}},"state":{"type":{"nin":["completed","canceled"]}},"team":{"key":{"eq":"ENG"}}}` {
		t.Fatalf("filter %s", filter)
	}
	first := list[0]
	if first.Identifier != "ENG-7" || first.Priority != "Urgent" || first.Comments != 2 || first.StateType != "started" {
		t.Fatalf("newest updated first, with its priority and comments: %+v", first)
	}
	if list[1].Priority != "" || list[1].Assignee != "alex" || list[1].AssigneeID != "u1" || list[1].Creator.ID != "u1" {
		t.Fatalf("no priority is none: %+v", list[1])
	}
	if issueSection(list[1].Issue, viewer, nil) != sectionNeedsYou || issueSection(list[0].Issue, viewer, nil) != sectionTeam {
		t.Fatal("ENG-5 is assigned to the viewer; ENG-7 is by sam, a member")
	}
}

func TestAStateTypeNarrowsTheList(t *testing.T) {
	r, l := newRecorded(t)
	if _, _, err := l.OpenIssues(context.Background(), "", "triage", ""); err != nil {
		t.Fatal(err)
	}
	filter, _ := json.Marshal(r.asked[0]["filter"])
	if string(filter) != `{"state":{"type":{"eq":"triage"}}}` {
		t.Fatalf("filter %s", filter)
	}
}

func TestTeamsAreByKey(t *testing.T) {
	_, l := newRecorded(t)
	teams, err := l.Teams(context.Background())
	if err != nil || len(teams) != 2 || teams[0].Key != "DES" || teams[1].Name != "Engineering" {
		t.Fatalf("%v %v", teams, err)
	}
}

// The bridge, the Lineage section and the styles are the github server's, word for word: one
// host draws both (#2941).
func TestThePageSharesTheGitHubServersBridge(t *testing.T) {
	for _, name := range []string{"bridge.js", "lineage.js", "common.css"} {
		ours, err := pageFiles.ReadFile("pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../githubmcp/pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if string(ours) != string(theirs) {
			t.Errorf("pages/%s is not the github server's: copy it again", name)
		}
	}
	if html := page("issues.html"); strings.Contains(html, "/*lineage.js*/") || !strings.Contains(html, "lineageSection(ui, issue.url)") {
		t.Error("the Issues page has no Lineage section")
	}
}
