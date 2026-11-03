package jiramcp

import (
	"context"
	"os"
	"strings"
	"testing"
)

// The view over a fake (rest_test.go reads a fake site over HTTP).

type fakeViews struct{}

// The viewer is alex (u1): ENG-5 is assigned to alex, ENG-6 is by alex, ENG-8 by an app, ENG-9 by a customer.
func (fakeViews) OpenIssues(_ context.Context, project, _, _ string) ([]ListedIssue, *Person, error) {
	alex, sam := &Person{ID: "u1", Name: "alex"}, &Person{ID: "u2", Name: "sam"}
	return []ListedIssue{
		{Issue: Issue{ID: "10005", Key: "ENG-5", Title: "Crash", Project: project, StatusCategory: "indeterminate", AssigneeID: "u1", Creator: sam},
			Priority: "High", UpdatedAt: "2026-10-19T10:00:00.000+0000"},
		{Issue: Issue{ID: "10006", Key: "ENG-6", Title: "Mine", Project: project, Creator: alex}},
		{Issue: Issue{ID: "10008", Key: "ENG-8", Title: "From Sentry", Project: project, Creator: &Person{Name: "Sentry", App: true}}},
		{Issue: Issue{ID: "10009", Key: "ENG-9", Title: "From a customer", Project: project, Creator: &Person{ID: "u9", Name: "kim", Customer: true}}},
	}, alex, nil
}

func (fakeViews) Projects(context.Context) ([]Project, error) {
	return []Project{{Key: "ENG", Name: "Engineering"}}, nil
}

func (fakeViews) IssueDetails(_ context.Context, key string) (map[string]any, error) {
	return map[string]any{"key": key, "description": "*Text*", "descriptionHTML": "<p><strong>Text</strong></p>\n"}, nil
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
	html := page("issues.html")
	if strings.Contains(html, "/*lineage.js*/") || !strings.Contains(html, "lineageSection(ui, issue.url)") {
		t.Error("the Issues page has no Lineage section")
	}
	raw, _ := pageFiles.ReadFile("pages/issues.html")
	for _, word := range []string{"Linear issue", "mcp.linear.app", "identifier", "stateType", "found.teams"} {
		if strings.Contains(string(raw), word) {
			t.Errorf("the Issues page still says %q", word)
		}
	}
}
