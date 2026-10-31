package linearmcp

// The Issues page's sections for a team (#2453, specs/2453-team-lists.md), the github
// server's (Go/internal/githubmcp/sections.go) in Linear's words: each open issue is in one,
// by how it relates to the viewer, the user of this server's API key. The page draws them in
// this order and leaves an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// issueSection is an issue's section. Linear has no review, so Needs you is assigned to the
// viewer only. Team is the workspace's members and its apps; Others is guests and an issue
// with no creator (a deleted user).
func issueSection(i Issue, viewer *Person) string {
	switch {
	case viewer != nil && viewer.ID != "" && i.AssigneeID == viewer.ID:
		return sectionNeedsYou
	case viewer != nil && viewer.ID != "" && i.Creator != nil && i.Creator.ID == viewer.ID:
		return sectionYours
	case i.Creator != nil && (i.Creator.App || !i.Creator.Guest):
		return sectionTeam
	}
	return sectionOthers
}
