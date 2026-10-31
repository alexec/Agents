package githubmcp

import "testing"

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
		if got := prSection(c.pr, "alexec"); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
	// No viewer (the login could not be read): nobody's is mine.
	if got := prSection(BoardPR{Author: "", Checks: "failing"}, ""); got != sectionOthers {
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
		if got := issueSection(c.issue, "alexec"); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}
