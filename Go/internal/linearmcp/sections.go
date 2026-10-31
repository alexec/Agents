package linearmcp

import (
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

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
// viewer only. With no control-plane people (#2951), Team is the workspace's members and its
// apps; Others is guests and an issue with no creator (a deleted user). With control-plane
// people, Team is the people and bots on this control plane instead, by their Linear email,
// as the issue's part 4 asks.
func issueSection(i Issue, viewer *Person, people teamMeta) string {
	switch {
	case viewer != nil && viewer.ID != "" && i.AssigneeID == viewer.ID:
		return sectionNeedsYou
	case viewer != nil && viewer.ID != "" && i.Creator != nil && i.Creator.ID == viewer.ID:
		return sectionYours
	}
	if len(people) > 0 {
		if i.Creator == nil {
			return sectionOthers
		}
		if _, on := people[strings.ToLower(i.Creator.Email)]; on {
			return sectionTeam
		}
		return sectionOthers
	}
	if i.Creator != nil && (i.Creator.App || !i.Creator.Guest) {
		return sectionTeam
	}
	return sectionOthers
}

// teamMeta is the control plane's people and bots, by Linear email lowercased (#2951): read
// from the call's _meta, which the host fills in, so this server makes no control-plane
// call of its own. Empty with no control plane, or an older host.
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

// agentOnOf reads _meta's agentOnLinear (#2951): who is on that key (ENG-4), or "".
func agentOnOf(meta mcp.Meta, identifier string) string {
	m, ok := meta["agentOnLinear"].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m[identifier].(string)
	return who
}
