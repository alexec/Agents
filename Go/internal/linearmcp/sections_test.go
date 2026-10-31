package linearmcp

import "testing"

// The Issues page's sections (#2453, specs/2453-team-lists.md), in Linear's words.
func TestAnIssuesSection(t *testing.T) {
	viewer := &Person{ID: "u1", Name: "alex"}
	alex, sam := &Person{ID: "u1", Name: "alex"}, &Person{ID: "u2", Name: "sam"}
	for _, c := range []struct {
		what   string
		issue  Issue
		viewer *Person
		want   string
	}{
		{"assigned to the viewer", Issue{AssigneeID: "u1", Creator: sam}, viewer, sectionNeedsYou},
		{"by the viewer and assigned to the viewer", Issue{AssigneeID: "u1", Creator: alex}, viewer, sectionNeedsYou},
		{"by the viewer", Issue{AssigneeID: "u2", Creator: alex}, viewer, sectionYours},
		{"by a member", Issue{Creator: sam}, viewer, sectionTeam},
		{"by an app", Issue{Creator: &Person{Name: "Sentry", App: true}}, viewer, sectionTeam},
		{"by a guest", Issue{Creator: &Person{ID: "u9", Name: "kim", Guest: true}}, viewer, sectionOthers},
		{"by a deleted user", Issue{}, viewer, sectionOthers},
		{"no viewer: not Needs you", Issue{AssigneeID: "u1", Creator: alex}, nil, sectionTeam},
		{"an app with no id is not the viewer", Issue{Creator: &Person{Name: "app", App: true}}, &Person{Name: "app"}, sectionTeam},
	} {
		if got := issueSection(c.issue, c.viewer); got != c.want {
			t.Errorf("%s: %s, want %s", c.what, got, c.want)
		}
	}
}
