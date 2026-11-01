package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/safe"
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
	people := d.cachedTeamPeople(ctx)
	if people == nil {
		return nil
	}
	meta := map[string]any{"people": people}
	prs, issues, linear := d.agentOnIt(folder)
	if len(prs) > 0 {
		meta["agentOnPR"] = prs
	}
	if len(issues) > 0 {
		meta["agentOnIssue"] = issues
	}
	if len(linear) > 0 {
		meta["agentOnLinear"] = linear
	}
	return meta
}

// The people a view call is given are kept for teamPeopleFresh (#3108): a person opens and
// refreshes these views many times a day, and each call asked the control plane and read
// the Keychain before the server was called at all. An answer older than that is still
// given, and a fresh one is asked for behind it; only the first call waits, for at most
// teamPeopleWait. A new control-plane link (join, leave, rejoin) starts again.
const (
	teamPeopleFresh = time.Minute
	teamPeopleWait  = 5 * time.Second
)

// teamPeopleCache is cachedTeamPeople's answer and which control-plane link it came from.
type teamPeopleCache struct {
	teamPeopleMu     sync.Mutex
	teamPeopleAsk    *askControl
	teamPeopleList   []map[string]any
	teamPeopleAt     time.Time
	teamPeopleAsking bool
}

// cachedTeamPeople is teamPeople, kept for teamPeopleFresh.
func (d *Daemon) cachedTeamPeople(ctx context.Context) []map[string]any {
	ask := d.askControl.Load()
	if ask == nil {
		return nil
	}
	d.teamPeopleMu.Lock()
	if d.teamPeopleAsk == ask && d.teamPeopleList != nil {
		list := d.teamPeopleList
		if nowFunc().Sub(d.teamPeopleAt) >= teamPeopleFresh && !d.teamPeopleAsking {
			d.teamPeopleAsking = true
			safe.Go("ask the control plane's people for views", func() {
				ctx, cancel := context.WithTimeout(d.ctx, teamPeopleWait)
				defer cancel()
				d.keepTeamPeople(ask, d.teamPeople(ctx, ask))
			})
		}
		d.teamPeopleMu.Unlock()
		return list
	}
	d.teamPeopleMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, teamPeopleWait)
	defer cancel()
	list := d.teamPeople(ctx, ask)
	d.keepTeamPeople(ask, list)
	return list
}

// keepTeamPeople keeps an answer from ask's link; nil (it could not say) keeps what was
// kept, to be asked again next call.
func (d *Daemon) keepTeamPeople(ask *askControl, list []map[string]any) {
	d.teamPeopleMu.Lock()
	defer d.teamPeopleMu.Unlock()
	d.teamPeopleAsking = false
	if list == nil {
		return
	}
	d.teamPeopleAsk, d.teamPeopleList, d.teamPeopleAt = ask, list, nowFunc()
}

// teamPeople is people/forViews, with the viewer's own entry's blank forge logins filled
// in from this machine's own connection, when it is signed in (#2951's open question).
func (d *Daemon) teamPeople(ctx context.Context, ask *askControl) []map[string]any {
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

// agentOnIt is "An agent is on it" (#2951), from one pass over this machine's own
// sessions (#3108); an archived session is not on it any more.
//   - prs and issues: this folder's repo's own sessions labelled #n or P#n, by number,
//     never another person's machines (this daemon's own Store is this machine's own).
//   - linear: sessions labelled a Linear key (ENG-4), by key, in whichever folder they are
//     in: a Linear issue is not one folder's own.
func (d *Daemon) agentOnIt(folder string) (prs, issues, linear map[string]string) {
	repo := d.folderRepo(folder)
	prs, issues, linear = map[string]string{}, map[string]string{}, map[string]string{}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived {
			continue
		}
		title := "an agent"
		if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
			title = strings.TrimSpace(*a.Title)
		}
		// The folder's repo only when a label could use it.
		inRepo, asked := false, false
		for _, l := range a.Labels {
			if linearLabel.MatchString(l.Value) {
				linear[l.Value] = title
				continue
			}
			if repo.forge == "" {
				continue
			}
			im, pm := issueLabel.FindStringSubmatch(l.Value), prLabel.FindStringSubmatch(l.Value)
			if im == nil && pm == nil {
				continue
			}
			if !asked {
				inRepo, asked = d.folderRepo(folderPath(&a)) == repo, true
			}
			if !inRepo {
				continue
			}
			if im != nil {
				issues[im[1]] = title
			} else {
				prs[pm[1]] = title
			}
		}
	}
	return prs, issues, linear
}
