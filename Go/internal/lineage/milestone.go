package lineage

import (
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// When a milestone lands (#4620), by method H as an epic (specs/4533-forecasting/spec.md):
//
//   - A milestone's items are the store's issues whose kept milestone is its name, in its repo,
//     not epics (an epic lands when its children do, and they are items too).
//   - An item is done when it landed (Landings) or closed; the open ones are the rest.
//   - The share is the median of the closed milestones' shares: a milestone is closed when the
//     store has all its items done. A share is as an epic's (groupShare), from at least
//     ThroughputMinGroups of them.
//   - With less than half of its items done, the forecast says the scope is still growing: a
//     milestone has about a fifth of its final items when its first issue is filed, so its
//     dates are a floor.

// Why a milestone has no landing date, besides an epic's reasons.
const (
	NoForecastNoItems    = "no issues in this milestone"
	NoForecastNoneOpen   = "no open items"
	NoForecastMilestones = "fewer than 5 closed milestones"
)

// milestoneItem is an issue of a milestone, in a repo.
type milestoneItem struct {
	node wire.LineageCostNode
	done bool
}

// milestoneKey is a milestone's group: its repo and its name, any case.
type milestoneKey struct{ repo, name string }

func milestoneKeyOf(repo, name string) milestoneKey {
	return milestoneKey{strings.ToLower(FullRepoText(repo)), strings.ToLower(name)}
}

// milestoneItems is each milestone's items in nodes, given landed (the refs that landed).
func milestoneItems(nodes []wire.LineageCostNode, landed map[string]bool) map[milestoneKey][]milestoneItem {
	parents := map[string]bool{}
	for _, n := range nodes {
		if n.Parent != nil {
			parents[*n.Parent] = true
		}
	}
	out := map[milestoneKey][]milestoneItem{}
	for _, n := range nodes {
		name := deref(n.Milestone)
		if n.Node.Kind != KindIssue || name == "" || parents[n.Node.Ref] || deref(n.Level) == "epic" {
			continue
		}
		done := landed[n.Node.Ref] || n.Resolved != nil && n.Resolved.State != nil && *n.Resolved.State == "closed"
		k := milestoneKeyOf(deref(n.Repo), name)
		out[k] = append(out[k], milestoneItem{node: n, done: done})
	}
	return out
}

// MilestoneShares is the share of each closed milestone in nodes but not: its items' landings
// over all of its repo's landings from its start to its last landing, by the hour.
func MilestoneShares(nodes []wire.LineageCostNode, landings []Landing, not milestoneKey) []float64 {
	landed := map[string]bool{}
	mine := map[milestoneKey][]Landing{}
	for _, l := range landings {
		landed[l.Ref] = true
		if l.Milestone != "" {
			k := milestoneKeyOf(l.Repo, l.Milestone)
			mine[k] = append(mine[k], l)
		}
	}
	groups := milestoneItems(nodes, landed)
	keys := make([]milestoneKey, 0, len(groups))
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		return keys[i].repo < keys[j].repo || keys[i].repo == keys[j].repo && keys[i].name < keys[j].name
	})
	var shares []float64
	for _, k := range keys {
		if k == not || len(mine[k]) == 0 {
			continue
		}
		starts := make([]wire.LineageCostNode, 0, len(groups[k]))
		closed := true
		for _, i := range groups[k] {
			closed = closed && i.done
			starts = append(starts, i.node)
		}
		if !closed {
			continue
		}
		if share, ok := groupShare(mine[k], starts, landings); ok {
			shares = append(shares, share)
		}
	}
	return shares
}

// MilestoneForecastOf is lineage/forecast for the milestone name in repo ("" for the repo its
// items are in, or every repo when they are in more than one) from nodes at now, with w's
// what-if (#4531).
func MilestoneForecastOf(nodes []wire.LineageCostNode, name, repo string, now time.Time, w WhatIf) wire.LineageForecast {
	if repo != "" {
		repo = FullRepoText(repo)
	}
	all := Landings(nodes)
	landed := map[string]bool{}
	for _, l := range all {
		landed[l.Ref] = true
	}
	groups := milestoneItems(nodes, landed)
	if repo == "" {
		for k := range groups {
			if k.name != strings.ToLower(name) {
				continue
			}
			if repo == "" {
				repo = k.repo
			} else if repo != k.repo {
				repo = ""
				break
			}
		}
	}
	var items []milestoneItem
	for k, g := range groups {
		if k.name == strings.ToLower(name) && (repo == "" || k.repo == strings.ToLower(repo)) {
			items = append(items, g...)
		}
	}
	f, bins, enough, wi := forecastIn(nodes, inRepo(all, repo), repo, now, w)
	f.Milestone = &name
	no := func(why string) wire.LineageForecast {
		f.NoForecast = &why
		return f
	}
	var open, closed int64
	for _, i := range items {
		if i.done {
			closed++
		} else {
			open++
		}
	}
	shares := MilestoneShares(nodes, all, milestoneKeyOf(repo, name))
	switch {
	case len(items) == 0:
		return no(NoForecastNoItems)
	case open == 0:
		return no(NoForecastNoneOpen)
	case !enough:
		return no(NoForecastHistory)
	case len(shares) < ThroughputMinGroups:
		return no(NoForecastMilestones)
	case f.Landings == 0:
		return no(NoForecastNoLanding)
	}
	share := median(shares)
	p50, p85, ok := LandsIn(bins, wi.keep, share, int(open), Rng("lands:milestone:"+strings.ToLower(repo)+":"+strings.ToLower(name)))
	if !ok {
		return no(NoForecastTooSlow)
	}
	at := func(h float64) wire.Date { return wire.DateOf(now.Add(time.Duration(h * float64(time.Hour)))) }
	f.Lands = &wire.LineageForecastLands{P50: at(p50), P85: at(p85), Open: open, Closed: closed,
		Share: share, Groups: int64(len(shares)), Growing: new(2*closed < open+closed)}
	return f
}
