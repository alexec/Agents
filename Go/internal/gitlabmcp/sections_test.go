package gitlabmcp

import (
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The lists' sections (#2952, specs/2453-team-lists.md): one per row, the first that fits.
func TestEachMergeRequestIsInTheFirstSectionThatFits(t *testing.T) {
	me, sam := user{ID: 1, Username: "alex"}, user{ID: 2, Username: "sam"}
	for _, c := range []struct {
		name   string
		mr     mergeRequest
		checks string
		team   bool
		want   string
	}{
		{"I am a reviewer", mergeRequest{Author: sam, Reviewers: []user{{Username: "Alex"}}}, "passing", true, sectionNeedsYou},
		{"mine, failing", mergeRequest{Author: me}, "failing", false, sectionNeedsYou},
		{"mine, in conflict", mergeRequest{Author: me, DetailedMergeStatus: "conflict"}, "passing", false, sectionNeedsYou},
		{"mine, changes requested", mergeRequest{Author: me, DetailedMergeStatus: "requested_changes"}, "passing", false, sectionNeedsYou},
		{"mine, still checking", mergeRequest{Author: me, DetailedMergeStatus: "checking"}, "running", false, sectionYours},
		{"mine, fine", mergeRequest{Author: me, DetailedMergeStatus: "not_approved"}, "running", false, sectionYours},
		{"a Developer's, failing", mergeRequest{Author: sam}, "failing", true, sectionTeam},
		{"a token bot's", mergeRequest{Author: user{ID: 4, Username: "project_7_bot_0a1b"}}, "none", false, sectionTeam},
		{"a bot account's", mergeRequest{Author: user{ID: 6, Username: "renovate", Bot: true}}, "none", false, sectionTeam},
		{"an outsider's", mergeRequest{Author: user{ID: 3, Username: "stranger"}}, "none", false, sectionOthers},
	} {
		if got := mrSection(c.mr, c.checks, "alex", c.team, nil); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
	// No viewer: nobody's is mine.
	if got := mrSection(mergeRequest{}, "failing", "", false, nil); got != sectionOthers {
		t.Errorf("no viewer: %s", got)
	}
}

func TestEachIssueIsInTheFirstSectionThatFits(t *testing.T) {
	issue := func(by string, assignees ...string) issueJSON {
		i := issueJSON{Author: user{Username: by}}
		for _, a := range assignees {
			i.Assignees = append(i.Assignees, user{Username: a})
		}
		return i
	}
	for _, c := range []struct {
		name  string
		issue issueJSON
		team  bool
		want  string
	}{
		{"assigned to me", issue("stranger", "sam", "ALEX"), false, sectionNeedsYou},
		{"mine, assigned to me", issue("alex", "alex"), true, sectionNeedsYou},
		{"mine", issue("alex", "sam"), true, sectionYours},
		{"a Developer's", issue("kim"), true, sectionTeam},
		{"a Reporter's", issue("guest"), false, sectionOthers},
	} {
		if got := issueSection(c.issue, "alex", c.team, nil); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

// With the control plane's people (#2951), Team is told from Others by them, not GitLab's
// Developer access: a Developer who is not on this control plane is Others, and a
// control-plane person who is not a Developer is Team.
func TestTeamIsTheControlPlanesPeopleWhenGiven(t *testing.T) {
	people := teamMeta{"alex": teamPerson{Name: "Alex", You: true}, "buildbot": teamPerson{Name: "Buildbot", Bot: true}}
	for _, c := range []struct {
		name string
		u    user
		team bool
		want string
	}{
		{"a Developer who is not on this control plane", user{Username: "sam"}, true, sectionOthers},
		{"the control plane's own bot, not a Developer", user{Username: "buildbot"}, false, sectionTeam},
		{"an outsider's", user{Username: "stranger"}, false, sectionOthers},
	} {
		if got := otherSection(c.u, c.team, people); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

func TestTeamMetaOfReadsThePeopleMetaByForge(t *testing.T) {
	meta := mcp.Meta{"people": []any{
		map[string]any{"name": "Alex", "gitlab": "Alex", "you": true},
		map[string]any{"name": "No GitLab login", "github": "kim"},
	}}
	people := teamMetaOf(meta, "gitlab")
	if len(people) != 1 {
		t.Fatalf("got %d people, want 1", len(people))
	}
	if alex, ok := people["alex"]; !ok || alex.Name != "Alex" || !alex.You {
		t.Errorf("alex: %+v, ok %v", alex, ok)
	}
	if teamMetaOf(nil, "gitlab") != nil {
		t.Error("no _meta: want nil")
	}
}

func TestAgentOnOfReadsTheNumberAsAString(t *testing.T) {
	meta := mcp.Meta{"agentOnPR": map[string]any{"42": "a session"}}
	if got := agentOnOf(meta, "agentOnPR", 42); got != "a session" {
		t.Errorf("got %q", got)
	}
	if got := agentOnOf(nil, "agentOnPR", 42); got != "" {
		t.Errorf("no _meta: got %q", got)
	}
}
