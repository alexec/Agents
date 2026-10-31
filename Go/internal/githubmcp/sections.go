package githubmcp

import (
	"slices"
	"strconv"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
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

// team: with no control-plane people (#2951), the repo's own people (#728's trust words)
// and bots; with them, Team is the people and bots on this control plane instead, by their
// GitHub login, as the issue's part 4 asks.
func (a author) team(people teamMeta) bool {
	if len(people) > 0 {
		_, on := people[strings.ToLower(a.Login)]
		return on
	}
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
func prSection(p BoardPR, viewer string, people teamMeta) string {
	mine := viewer != "" && strings.EqualFold(p.Author, viewer)
	switch {
	case viewer != "" && slices.ContainsFunc(p.ReviewRequested, func(l string) bool { return strings.EqualFold(l, viewer) }):
		return sectionNeedsYou
	case mine && (p.Checks == "failing" || (p.Conflicts != nil && *p.Conflicts) || p.Review == "changes_requested"):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	return otherSection(p.authorInfo, people)
}

// issueSection is an issue's section: Needs you when it is assigned to the viewer.
func issueSection(i ListedIssue, viewer string, people teamMeta) string {
	switch {
	case viewer != "" && slices.ContainsFunc(i.Assignees, func(l string) bool { return strings.EqualFold(l, viewer) }):
		return sectionNeedsYou
	case viewer != "" && strings.EqualFold(i.Author, viewer):
		return sectionYours
	}
	return otherSection(i.authorInfo, people)
}

func otherSection(a author, people teamMeta) string {
	if a.team(people) {
		return sectionTeam
	}
	return sectionOthers
}

// teamMeta is the control plane's people and bots, by GitHub login lowercased (#2951):
// read from the call's _meta, which the host fills in, so this server makes no
// control-plane call of its own. Empty with no control plane, or an older host.
type teamMeta map[string]teamPerson

// teamPerson is one of teamMeta's people, as the control plane knows them.
type teamPerson struct {
	Name string
	Bot  bool
	You  bool
}

// teamMetaOf reads _meta's people (#2951): each with the login for forge, lowercased.
func teamMetaOf(meta mcp.Meta, forge string) teamMeta {
	list, ok := meta["people"].([]any)
	if !ok {
		return nil
	}
	out := teamMeta{}
	for _, item := range list {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		login, _ := row[forge].(string)
		if login == "" {
			continue
		}
		name, _ := row["name"].(string)
		bot, _ := row["bot"].(bool)
		you, _ := row["you"].(bool)
		out[strings.ToLower(login)] = teamPerson{Name: name, Bot: bot, You: you}
	}
	return out
}

// agentOnOf reads _meta's agentOnPR or agentOnIssue (#2951): who is on that number, or "".
func agentOnOf(meta mcp.Meta, key string, number int) string {
	m, ok := meta[key].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m[strconv.Itoa(number)].(string)
	return who
}
