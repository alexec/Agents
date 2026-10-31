package agentsd

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// The control plane's people, in a feeding tool's _meta (#2951, specs/2453-team-lists.md
// part 4): callFromView and readViewCount give show_pull_requests, show_issues and
// show_merge_requests the control plane's people and bots, with their GitHub, GitLab and
// Linear logins and which is the viewer's own, so a row can be named as the control plane
// knows the person, Team can be told from Others, and the viewer's own rows can say an
// agent is on it. The github, gitlab and linear servers read it off the call; they make no
// control-plane call of their own.

// teamFeedingTools are the github, gitlab and linear servers' feeding tools that take the
// control plane's people in their call's _meta (#2951).
var teamFeedingTools = map[string]bool{"show_pull_requests": true, "show_issues": true, "show_merge_requests": true}

// teamMeta is the feeding tool's _meta: nil with no control plane, or it could not say.
func (d *Daemon) teamMeta(ctx context.Context, folder string) map[string]any {
	people := d.teamPeople(ctx)
	if people == nil {
		return nil
	}
	meta := map[string]any{"people": people}
	if prs, issues := d.agentOnByNumber(folder); len(prs) > 0 || len(issues) > 0 {
		if len(prs) > 0 {
			meta["agentOnPR"] = prs
		}
		if len(issues) > 0 {
			meta["agentOnIssue"] = issues
		}
	}
	// A Linear key (ENG-4) is not a folder's repo's own: any of this machine's own sessions
	// labelled one is on it, whichever folder it is in.
	if linear := d.agentOnByLinearKey(); len(linear) > 0 {
		meta["agentOnLinear"] = linear
	}
	return meta
}

// teamPeople is people/forViews, with the viewer's own entry's blank forge logins filled
// in from this machine's own connection, when it is signed in (#2951's open question).
func (d *Daemon) teamPeople(ctx context.Context) []map[string]any {
	ask := d.askControl.Load()
	if ask == nil {
		return nil
	}
	raw, err := (*ask)(ctx, wire.CallPeopleForViews.Name, wire.Empty{})
	if err != nil {
		return nil
	}
	var list wire.PeopleForViews
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	conns, _ := d.connectionStore()
	out := make([]map[string]any, 0, len(list.People))
	for _, p := range list.People {
		you := p.You != nil && *p.You
		github, gitlab, linear := optstr(p.GithubLogin), optstr(p.GitlabLogin), optstr(p.LinearLogin)
		if you && conns != nil {
			if github == "" {
				github = connectionLogin(conns, connections.GitHub)
			}
			if gitlab == "" {
				gitlab = connectionLogin(conns, connections.GitLab)
			}
			if linear == "" {
				linear = connectionLogin(conns, connections.Linear)
			}
		}
		row := map[string]any{"name": p.Name}
		if p.Kind == "bot" {
			row["bot"] = true
		}
		if github != "" {
			row["github"] = github
		}
		if gitlab != "" {
			row["gitlab"] = gitlab
		}
		if linear != "" {
			row["linear"] = linear
		}
		if you {
			row["you"] = true
		}
		out = append(out, row)
	}
	return out
}

func optstr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// connectionLogin is a usable connection's login, or "".
func connectionLogin(s connections.Store, provider string) string {
	c, ok, err := s.Get(provider)
	if err != nil || !ok || !c.Usable(nowFunc()) {
		return ""
	}
	return c.Login
}

// agentOnByNumber is "An agent is on it" (#2951): this folder's repo's own sessions
// labelled #n or P#n, by number, never another person's machines (this daemon's own Store
// is this machine's own). An archived session is not on it any more.
func (d *Daemon) agentOnByNumber(folder string) (prs, issues map[string]string) {
	repo := d.folderRepo(folder)
	if repo.forge == "" {
		return nil, nil
	}
	prs, issues = map[string]string{}, map[string]string{}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived {
			continue
		}
		if d.folderRepo(folderPath(&a)) != repo {
			continue
		}
		title := "an agent"
		if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
			title = strings.TrimSpace(*a.Title)
		}
		for _, l := range a.Labels {
			if m := issueLabel.FindStringSubmatch(l.Value); m != nil {
				issues[m[1]] = title
			} else if m := prLabel.FindStringSubmatch(l.Value); m != nil {
				prs[m[1]] = title
			}
		}
	}
	return prs, issues
}

// agentOnByLinearKey is "An agent is on it" for Linear (#2951): this machine's own
// sessions labelled a Linear key (ENG-4), by key, in whichever folder they are in: a Linear
// issue is not one folder's own. An archived session is not on it any more.
func (d *Daemon) agentOnByLinearKey() map[string]string {
	out := map[string]string{}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived {
			continue
		}
		title := "an agent"
		if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
			title = strings.TrimSpace(*a.Title)
		}
		for _, l := range a.Labels {
			if linearLabel.MatchString(l.Value) {
				out[l.Value] = title
			}
		}
	}
	return out
}
