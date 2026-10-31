package githubmcp

import (
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The lists' sections (#2453, specs/2453-team-lists.md): one per row, the first that fits.
func TestEachPullRequestIsInTheFirstSectionThatFits(t *testing.T) {
	yes := true
	collaborator := authorOf("sam", "COLLABORATOR", "User")
	for _, c := range []struct {
		name string
		pr   BoardPR
		want string
	}{
		{"a review asked of me", BoardPR{Author: "sam", ReviewRequested: []string{"AlexEC"}, authorInfo: collaborator}, sectionNeedsYou},
		{"mine, failing", BoardPR{Author: "alexec", Checks: "failing"}, sectionNeedsYou},
		{"mine, in conflict", BoardPR{Author: "alexec", Checks: "passing", Conflicts: &yes}, sectionNeedsYou},
		{"mine, changes requested", BoardPR{Author: "alexec", Review: "changes_requested"}, sectionNeedsYou},
		{"mine, fine", BoardPR{Author: "alexec", Checks: "running", Review: "review_required"}, sectionYours},
		{"a collaborator's, failing", BoardPR{Author: "sam", Checks: "failing", authorInfo: collaborator}, sectionTeam},
		{"a member's", BoardPR{Author: "kim", authorInfo: authorOf("kim", "MEMBER", "User")}, sectionTeam},
		{"a bot's", BoardPR{Author: "renovate[bot]", authorInfo: authorOf("renovate[bot]", "NONE", "")}, sectionTeam},
		{"an outside contributor's", BoardPR{Author: "stranger", authorInfo: authorOf("stranger", "CONTRIBUTOR", "User")}, sectionOthers},
		{"a deleted account's", BoardPR{}, sectionOthers},
	} {
		if got := prSection(c.pr, "alexec", nil); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
	// No viewer (the login could not be read): nobody's is mine.
	if got := prSection(BoardPR{Author: "", Checks: "failing"}, "", nil); got != sectionOthers {
		t.Errorf("no viewer: %s", got)
	}
}

func TestEachIssueIsInTheFirstSectionThatFits(t *testing.T) {
	issue := func(by, association string, assignees ...string) ListedIssue {
		return ListedIssue{Issue: Issue{Author: by, Assignees: assignees}, authorInfo: authorOf(by, association, "User")}
	}
	for _, c := range []struct {
		name  string
		issue ListedIssue
		want  string
	}{
		{"assigned to me", issue("stranger", "NONE", "sam", "alexec"), sectionNeedsYou},
		{"mine, assigned to me", issue("alexec", "OWNER", "alexec"), sectionNeedsYou},
		{"mine", issue("alexec", "OWNER", "sam"), sectionYours},
		{"an owner's", issue("kim", "OWNER"), sectionTeam},
		{"a first-timer's", issue("new", "FIRST_TIME_CONTRIBUTOR"), sectionOthers},
	} {
		if got := issueSection(c.issue, "alexec", nil); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

// With the control plane's people (#2951), Team is told from Others by them, not GitHub's
// trust words: a repo collaborator who is not on this control plane is Others, and a
// control-plane person who is not a collaborator is Team.
func TestTeamIsTheControlPlanesPeopleWhenGiven(t *testing.T) {
	people := teamMeta{"alexec": teamPerson{Name: "Alex", You: true}, "buildbot[bot]": teamPerson{Name: "Buildbot", Bot: true}}
	for _, c := range []struct {
		name string
		pr   BoardPR
		want string
	}{
		{"a control-plane person's, no GitHub trust", BoardPR{Author: "someone", authorInfo: authorOf("someone", "NONE", "User")}, sectionOthers},
		{"a collaborator who is not on this control plane", BoardPR{Author: "sam", authorInfo: authorOf("sam", "COLLABORATOR", "User")}, sectionOthers},
		{"the control plane's own bot", BoardPR{Author: "buildbot[bot]", authorInfo: authorOf("buildbot[bot]", "NONE", "Bot")}, sectionTeam},
	} {
		if got := otherSection(c.pr.authorInfo, people); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

func TestTeamMetaOfReadsThePeopleMetaByForge(t *testing.T) {
	meta := mcp.Meta{"people": []any{
		map[string]any{"name": "Alex", "github": "AlexEC", "you": true},
		map[string]any{"name": "Buildbot", "github": "buildbot[bot]", "bot": true},
		map[string]any{"name": "No GitHub login", "linear": "kim"},
	}}
	people := teamMetaOf(meta, "github")
	if len(people) != 2 {
		t.Fatalf("got %d people, want 2", len(people))
	}
	alex, ok := people["alexec"]
	if !ok || alex.Name != "Alex" || !alex.You {
		t.Errorf("alexec: %+v, ok %v", alex, ok)
	}
	if teamMetaOf(nil, "github") != nil {
		t.Error("no _meta: want nil")
	}
}

func TestAgentOnOfReadsTheNumberAsAString(t *testing.T) {
	meta := mcp.Meta{"agentOnPR": map[string]any{"42": "a session"}}
	if got := agentOnOf(meta, "agentOnPR", 42); got != "a session" {
		t.Errorf("got %q", got)
	}
	if got := agentOnOf(meta, "agentOnPR", 7); got != "" {
		t.Errorf("no match: got %q", got)
	}
	if got := agentOnOf(nil, "agentOnPR", 42); got != "" {
		t.Errorf("no _meta: got %q", got)
	}
}
