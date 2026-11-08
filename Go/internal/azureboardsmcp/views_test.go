package azureboardsmcp

import (
	"os"
	"strings"
	"testing"
)

// The Azure Boards page (#3826) through the front, over the fake Azure DevOps.

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
	for _, word := range []string{"Jira", "atlassian", "found.projects", `"indeterminate"`} {
		if strings.Contains(string(raw), word) {
			t.Errorf("the Issues page still says %q", word)
		}
	}
}

func issueKeys(r map[string]any) []string {
	var out []string
	for _, w := range r["issues"].([]any) {
		out = append(out, w.(map[string]any)["key"].(string))
	}
	return out
}

func TestShowIssuesListsOpenWorkItemsInSections(t *testing.T) {
	f := newFake(t)
	f.item(1, "Assigned to me", "Bug", "Active", dev, 1, obj{fieldAssigned: alex, fieldTags: "ui"})
	f.item(2, "Mine", "User Story", "New", alex, 2, nil)
	f.item(3, "A build's", "Bug", "New", builder, 3, nil)
	f.item(4, "Done", "Bug", "Closed", dev, 4, nil)
	f.item(5, "Someone else's", "Bug", "Resolved", dev, 5, obj{fieldAssigned: dev})
	c := serve(t, f)

	r, ok := c.tool("show_issues", map[string]any{})
	if !ok {
		t.Fatalf("show_issues: %v", r)
	}
	same(t, issueKeys(r), []string{"AB#5", "AB#3", "AB#2", "AB#1"})
	if r["count"] != float64(4) || r["attention"] != float64(1) || r["truncated"] != false {
		t.Fatalf("count %v, attention %v, truncated %v", r["count"], r["attention"], r["truncated"])
	}
	equal(t, r["types"], []any{"Bug", "User Story"})
	equal(t, r["categories"], []any{"Proposed", "InProgress", "Resolved"})
	sections := map[string]string{}
	for _, w := range r["issues"].([]any) {
		w := w.(map[string]any)
		sections[w["key"].(string)] = w["section"].(string)
	}
	equal(t, sections, map[string]string{"AB#1": "needs_you", "AB#2": "yours", "AB#3": "team", "AB#5": "team"})
	one := r["issues"].([]any)[3].(map[string]any)
	if one["id"] != float64(1) || one["type"] != "Bug" || one["status"] != "Active" || one["statusCategory"] != "InProgress" ||
		one["updatedAt"] != "2026-11-06T12:01:00.000Z" || one["assignee"] != "alex@acme.test" ||
		one["url"] != f.server.URL+"/acme/Web%20App/_workitems/edit/1" {
		t.Fatalf("a row: %v", one)
	}
	if build := r["issues"].([]any)[1].(map[string]any); build["authorBot"] != true {
		t.Fatalf("a build's: %v", build)
	}

	// A state category and a type narrow it; a tag too.
	narrowed, ok := c.tool("show_issues", map[string]any{"category": "Proposed", "type": "Bug", "label": "ui"})
	if !ok {
		t.Fatalf("narrowed: %v", narrowed)
	}
	q := f.lastQuery()
	for _, want := range []string{"[System.State] NOT IN ('Closed', 'Removed')", "[System.State] IN ('New')",
		"[System.WorkItemType] = 'Bug'", "[System.Tags] CONTAINS 'ui'"} {
		if !strings.Contains(q, want) {
			t.Fatalf("WIQL %s, want %s", q, want)
		}
	}
	proposed, _ := c.tool("show_issues", map[string]any{"category": "Proposed"})
	same(t, issueKeys(proposed), []string{"AB#3", "AB#2"})
	if _, ok := c.tool("show_issues", map[string]any{"category": "Completed"}); ok {
		t.Fatal("category Completed worked")
	}
}

// An agent on one of the viewer's own work items says so, from the host's _meta (#2951).
func TestShowIssuesSaysAnAgentIsOnIt(t *testing.T) {
	f := newFake(t)
	f.item(1, "Assigned to me", "Bug", "Active", dev, 1, obj{fieldAssigned: alex})
	f.item(2, "Someone else's", "Bug", "Active", dev, 2, nil)
	c := serve(t, f)
	result := c.call("tools/call", map[string]any{"name": "show_issues", "arguments": map[string]any{},
		"_meta": map[string]any{"agentOnBoards": map[string]any{"AB#1": "Fix the crash", "AB#2": "Other"}}})["result"].(map[string]any)
	issues := result["structuredContent"].(map[string]any)["issues"].([]any)
	if mine := issues[1].(map[string]any); mine["key"] != "AB#1" || mine["agentOn"] != "Fix the crash" {
		t.Fatalf("mine: %v", mine)
	}
	if theirs := issues[0].(map[string]any); theirs["agentOn"] != nil {
		t.Fatalf("a Team row: %v", theirs)
	}
}

// With the control plane's people in _meta (#3853), Team is those people and bots by their
// Azure DevOps login, its sign-in email or display name, named as the control plane knows
// them; everyone else is Others.
func TestShowIssuesTellsTeamFromOthersByTheAzureDevOpsLogin(t *testing.T) {
	f := newFake(t)
	sam := obj{"id": "s4", "displayName": "Sam Smith", "uniqueName": "sam@acme.test", "descriptor": "aad.c2Ft"}
	f.item(1, "Dev's", "Bug", "Active", dev, 1, nil)
	f.item(2, "Sam's", "Bug", "Active", sam, 2, nil)
	f.item(3, "A build's", "Bug", "New", builder, 3, nil)
	f.item(4, "Mine", "Bug", "New", alex, 4, nil)
	c := serve(t, f)
	result := c.call("tools/call", map[string]any{"name": "show_issues", "arguments": map[string]any{},
		"_meta": map[string]any{"people": []any{
			map[string]any{"name": "Alex", "you": true, "azuredevops": "Alex"},
			map[string]any{"name": "Dev Person", "azuredevops": "DEV@acme.test"},
			map[string]any{"name": "Sam", "github": "sam"},
		}}})["result"].(map[string]any)
	sections, names := map[string]string{}, map[string]any{}
	for _, w := range result["structuredContent"].(map[string]any)["issues"].([]any) {
		w := w.(map[string]any)
		sections[w["key"].(string)], names[w["key"].(string)] = w["section"].(string), w["authorName"]
	}
	equal(t, sections, map[string]string{"AB#1": "team", "AB#2": "others", "AB#3": "others", "AB#4": "yours"})
	if names["AB#1"] != "Dev Person" || names["AB#2"] != nil || names["AB#4"] != "Alex" {
		t.Fatalf("names: %v", names)
	}
}

func TestShowIssueDetailsMakesTheDescriptionSafe(t *testing.T) {
	f := newFake(t)
	f.item(1, "Bug", "Bug", "Active", dev, 1, obj{fieldDesc: `<p>It <b>fails</b>.</p><script>alert(1)</script><a href="javascript:x">x</a>`})
	c := serve(t, f)
	r, ok := c.tool("show_issue_details", map[string]any{"id": 1})
	if !ok {
		t.Fatalf("show_issue_details: %v", r)
	}
	html := r["descriptionHTML"].(string)
	if r["key"] != "AB#1" || !strings.Contains(html, "<b>fails</b>") || strings.Contains(html, "script") || strings.Contains(html, "javascript") {
		t.Fatalf("details: %v", r)
	}
	for _, req := range f.requests {
		if strings.HasSuffix(req, "/comments") {
			t.Fatalf("the details read the comments: %s", req)
		}
	}
	if _, ok := c.tool("show_issue_details", map[string]any{"id": 0}); ok {
		t.Fatal("id 0 worked")
	}
}
