package githubmcp

import (
	"slices"
	"strings"
)

// The lists' sections for a team (#2453, specs/2453-team-lists.md): each open pull request
// and issue is in one, by how it relates to the viewer, the login of this server's
// connection. The pages draw them in this order and leave an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// author is who opened a pull request or an issue, as the sections need it.
type author struct {
	Login, Association string
	Bot                bool
}

// team: the repo's own people (#728's trust words), and bots.
func (a author) team() bool {
	switch strings.ToUpper(a.Association) {
	case "OWNER", "MEMBER", "COLLABORATOR":
		return true
	}
	return a.Bot
}

func authorOf(login, association, typ string) author {
	return author{Login: login, Association: association, Bot: typ == "Bot" || strings.HasSuffix(login, "[bot]")}
}

// prSection is a pull request's section: Needs you when a review is asked of the viewer, or
// when the viewer's own has failing checks, a conflict or changes requested.
func prSection(p BoardPR, viewer string) string {
	mine := viewer != "" && strings.EqualFold(p.Author, viewer)
	switch {
	case viewer != "" && slices.ContainsFunc(p.ReviewRequested, func(l string) bool { return strings.EqualFold(l, viewer) }):
		return sectionNeedsYou
	case mine && (p.Checks == "failing" || (p.Conflicts != nil && *p.Conflicts) || p.Review == "changes_requested"):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	return otherSection(p.authorInfo)
}

// issueSection is an issue's section: Needs you when it is assigned to the viewer.
func issueSection(i ListedIssue, viewer string) string {
	switch {
	case viewer != "" && slices.ContainsFunc(i.Assignees, func(l string) bool { return strings.EqualFold(l, viewer) }):
		return sectionNeedsYou
	case viewer != "" && strings.EqualFold(i.Author, viewer):
		return sectionYours
	}
	return otherSection(i.authorInfo)
}

func otherSection(a author) string {
	if a.team() {
		return sectionTeam
	}
	return sectionOthers
}
