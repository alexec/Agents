package gitlabmcp

import "testing"

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
		if got := mrSection(c.mr, c.checks, "alex", c.team); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
	// No viewer: nobody's is mine.
	if got := mrSection(mergeRequest{}, "failing", "", false); got != sectionOthers {
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
		if got := issueSection(c.issue, "alex", c.team); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}
