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

func (fakeViews) OpenIssues(_ context.Context, team, _, _ string) ([]ListedIssue, error) {
	return []ListedIssue{{Issue: Issue{ID: "7d1c", Identifier: "ENG-5", Title: "Crash", Team: team, StateType: "started"},
		Priority: "High", UpdatedAt: "2026-10-19T10:00:00.000Z"}}, nil
}

func (fakeViews) Teams(context.Context) ([]Team, error) {
	return []Team{{Key: "ENG", Name: "Engineering"}}, nil
}

func (fakeViews) IssueDetails(_ context.Context, identifier string) (map[string]any, error) {
	return map[string]any{"identifier": identifier, "description": "**Text**", "descriptionHTML": "<p><strong>Text</strong></p>\n"}, nil
}

func TestTheViewListsOpenIssues(t *testing.T) {
	r, l := newRecorded(t)
	list, err := l.OpenIssues(context.Background(), "ENG", "", "Bug")
	if err != nil || len(list) != 2 {
		t.Fatalf("%v %v", list, err)
	}
	filter, _ := json.Marshal(r.asked[0]["filter"])
	if string(filter) != `{"labels":{"name":{"eq":"Bug"}},"state":{"type":{"nin":["completed","canceled"]}},"team":{"key":{"eq":"ENG"}}}` {
		t.Fatalf("filter %s", filter)
	}
	first := list[0]
	if first.Identifier != "ENG-7" || first.Priority != "Urgent" || first.Comments != 2 || first.StateType != "started" {
		t.Fatalf("newest updated first, with its priority and comments: %+v", first)
	}
	if list[1].Priority != "" || list[1].Assignee != "alex" {
		t.Fatalf("no priority is none: %+v", list[1])
	}
}

func TestAStateTypeNarrowsTheList(t *testing.T) {
	r, l := newRecorded(t)
	if _, err := l.OpenIssues(context.Background(), "", "triage", ""); err != nil {
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
