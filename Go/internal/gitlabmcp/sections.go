package gitlabmcp

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The lists' sections for a team (#2952, specs/2453-team-lists.md), as the github server
// has them (Go/internal/githubmcp/sections.go): each open merge request and issue is in one,
// by how it relates to the viewer, the username of this server's connection. The pages draw
// them in this order and leave an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// developerAccess is the access level from which a project member is the team's.
const developerAccess = 30

// mrSection is a merge request's section: Needs you when the viewer is one of its reviewers,
// or when the viewer's own has a failed pipeline, a conflict, or a reviewer who asked for
// changes. checks is its pipeline in the github server's words; team says its author is a
// member with Developer access or more.
func mrSection(m mergeRequest, checks, viewer string, team bool, people teamMeta) string {
	mine := viewer != "" && strings.EqualFold(m.Author.Username, viewer)
	conflicts := m.conflicts()
	switch {
	case viewer != "" && slices.ContainsFunc(m.Reviewers, func(u user) bool { return strings.EqualFold(u.Username, viewer) }):
		return sectionNeedsYou
	case mine && (checks == "failing" || (conflicts != nil && *conflicts) || m.changesRequested()):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	return otherSection(m.Author, team, people)
}

// issueSection is an issue's section: Needs you when it is assigned to the viewer.
func issueSection(i issueJSON, viewer string, team bool, people teamMeta) string {
	switch {
	case viewer != "" && slices.ContainsFunc(i.Assignees, func(u user) bool { return strings.EqualFold(u.Username, viewer) }):
		return sectionNeedsYou
	case viewer != "" && strings.EqualFold(i.Author.Username, viewer):
		return sectionYours
	}
	return otherSection(i.Author, team, people)
}

// otherSection: with no control-plane people (#2951), the project's Developers and up, and
// bots, are the team; with them, Team is the people and bots on this control plane
// instead, by their GitLab username, as the issue's part 4 asks.
func otherSection(u user, team bool, people teamMeta) string {
	if len(people) > 0 {
		_, on := people[strings.ToLower(u.Username)]
		return sectionIf(on)
	}
	return sectionIf(team || isBot(u.Username, u.Bot))
}

func sectionIf(team bool) string {
	if team {
		return sectionTeam
	}
	return sectionOthers
}

// teamMeta is the control plane's people and bots, by GitLab username lowercased (#2951):
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

// agentOnOf reads _meta's agentOnMR or agentOnIssue (#2951): who is on that number, or "".
func agentOnOf(meta mcp.Meta, key string, number int) string {
	m, ok := meta[key].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m[strconv.Itoa(number)].(string)
	return who
}

// developers is which of these people are the project's members, directly or through a group,
// with Developer access or more. Who it does not know yet it asks GitLab in one call, and keeps
// each answer as trusted does. When GitLab cannot say, nobody is: the list still shows.
func (g *RealGitLab) developers(ctx context.Context, project string, people []user) map[int]bool {
	out := map[int]bool{}
	var ask []int
	g.mu.Lock()
	for _, u := range people {
		if u.ID == 0 || out[u.ID] || slices.Contains(ask, u.ID) {
			continue
		}
		if kept, ok := g.members[project+"\x00"+strconv.Itoa(u.ID)]; ok && time.Since(kept.at) < memberFor {
			out[u.ID] = kept.level >= developerAccess
		} else {
			ask = append(ask, u.ID)
		}
	}
	g.mu.Unlock()
	if len(ask) == 0 {
		return out
	}
	path := fmt.Sprintf("projects/%s/members/all?per_page=%d", pid(project), perPage)
	for _, id := range ask {
		path += "&user_ids[]=" + strconv.Itoa(id)
	}
	var found []struct {
		ID          int `json:"id"`
		AccessLevel int `json:"access_level"`
	}
	if err := g.get(ctx, path, false, &found); err != nil {
		return out
	}
	levels := map[int]int{}
	for _, m := range found {
		levels[m.ID] = max(levels[m.ID], m.AccessLevel)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.members)+len(ask) > maxMembers {
		g.members = map[string]member{}
	}
	for _, id := range ask {
		g.members[project+"\x00"+strconv.Itoa(id)] = member{time.Now(), levels[id]}
		out[id] = levels[id] >= developerAccess
	}
	return out
}
