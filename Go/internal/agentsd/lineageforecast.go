package agentsd

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/internal/safe"
	"github.com/agentloops-dev/agents/Go/wire"
)

// lineage/forecast (#4526): when an epic lands, its estimate to complete, the spend and the
// service levels from this machine's totals (lineage.ForecastOf), and each weekly allowance's
// burn from allowances.json. An epic's first landing forecast is kept on its node, so a report
// can score it when the epic lands. A milestone (#4620) is forecast from the store's issues
// in it, in its folder's repo; nothing is kept for it, since a milestone has no node, but
// a P85 date past its due date is told once (milestonenotice.go, #4654). A what-if (#4531)
// takes the window's runtime mix from the usage and time histories, and is never kept or
// told.

// allowanceWeek is how long a weekly allowance's window is.
const allowanceWeek = 7 * 24 * time.Hour

func (d *Daemon) lineageForecast(ctx context.Context, r wire.LineageForecastRequest) (wire.LineageForecast, error) {
	if milestone := deref(r.Milestone); milestone != "" {
		if r.Node != nil {
			return wire.LineageForecast{}, errors.New("lineage/forecast: a node or a milestone, not both")
		}
		return d.milestoneForecast(milestone, deref(r.Folder), d.whatIfOf(r.WhatIf)), nil
	}
	var children []lineage.EpicChild
	isEpic := false
	if r.Node != nil {
		plan, err := d.forgePlan(ctx, wire.ForgePlanRequest{Node: *r.Node})
		if err != nil {
			return wire.LineageForecast{}, err
		}
		isEpic = len(plan.Children) > 0 || lineage.LevelOf(forgeLabelNames(plan.Item.Labels)) == "epic"
		for _, c := range plan.Children {
			children = append(children, lineage.EpicChild{Node: c.Item.Node, Labels: forgeLabelNames(c.Item.Labels), Step: c.Step,
				Open: c.Item.State != "closed" && c.Item.State != "merged"})
		}
	}
	now := nowFunc()
	nodes := d.forecastNodes()
	f := lineage.ForecastOf(nodes, r.Node, isEpic, children, now, d.whatIfOf(r.WhatIf))
	// The overhead, loaded into the cost as "about $165 all in" (#4524).
	lineage.LoadForecast(&f, lineage.Overhead(nodes, now))
	if r.Node != nil && f.WhatIf == nil {
		f.Kept = d.keepForecast(costKey(*r.Node), lineage.KeepForecast(f))
	}
	f.Burn = d.forecastBurn(f, now)
	return f, nil
}

// whatIfOf is the request's what-if, with the window's runtime mix (#4531).
func (d *Daemon) whatIfOf(r *wire.LineageForecastWhatIf) lineage.WhatIf {
	w := lineage.WhatIf{Runtimes: d.runtimeMix(nowFunc())}
	if r != nil {
		if r.Lanes != nil {
			w.Lanes = int(*r.Lanes)
		}
		w.Mix = r.Mix
	}
	return w
}

// forecastBurn is each allowance's burn at f's what-if's pace for its runtime.
func (d *Daemon) forecastBurn(f wire.LineageForecast, now time.Time) []wire.LineageForecastBurn {
	return d.allowanceBurn(now, func(key string) float64 { return lineage.BurnPace(f, burnRuntime(key)) })
}

// burnRuntime is the runtime of an allowance's credential key: the part before the colon.
func burnRuntime(key string) string {
	runtime, _, _ := strings.Cut(key, ":")
	return runtime
}

// runtimeMix is the window's runtime mix (#4531): each runtime's working hours (the agent, its
// tools and others) from time-history.json and its cost from usage-history.json, over the days
// of the last lineage.ThroughputWindow.
func (d *Daemon) runtimeMix(now time.Time) []wire.LineageForecastRuntime {
	first := dayStamp(now.Add(-lineage.ThroughputWindow + 24*time.Hour))
	hours := map[string]float64{}
	d.timeMu.Lock()
	for day, by := range d.timeLocked().Days {
		if day < first {
			continue
		}
		for runtime, b := range by {
			hours[runtime] += (b.Agent + b.Tools + b.Others) / 3600
		}
	}
	d.timeMu.Unlock()
	cost := map[string]map[string]float64{}
	d.costMu.Lock()
	for day, by := range d.usageLocked().Days {
		if day < first {
			continue
		}
		for runtime, b := range by {
			for currency, v := range b.Cost {
				if cost[runtime] == nil {
					cost[runtime] = map[string]float64{}
				}
				cost[runtime][currency] += v
			}
		}
	}
	d.costMu.Unlock()
	return lineage.RuntimesOf(hours, cost)
}

// milestoneForecast is when the milestone named lands, in folder's repo (any for none), with
// w's what-if. With a repo and no what-if, a P85 date past its due date tells the person (#4654).
func (d *Daemon) milestoneForecast(milestone, folder string, w lineage.WhatIf) wire.LineageForecast {
	repo := ""
	if folder != "" {
		if r := d.folderRepo(folder); r.forge != "" {
			repo = r.forge + ":" + r.path
		}
	}
	f := d.milestoneForecastIn(milestone, repo, w)
	if repo != "" && f.WhatIf == nil {
		safe.Go("milestone due date", func() { d.tellMilestoneLate(milestoneOf{repo, milestone}, f) })
	}
	return f
}

// milestoneForecastIn is when the milestone named lands, in repo (any for ""), with w's what-if.
func (d *Daemon) milestoneForecastIn(milestone, repo string, w lineage.WhatIf) wire.LineageForecast {
	now := nowFunc()
	nodes := d.forecastNodes()
	f := lineage.MilestoneForecastOf(nodes, milestone, repo, now, w)
	lineage.LoadForecast(&f, lineage.Overhead(nodes, now))
	f.Burn = d.forecastBurn(f, now)
	return f
}

// forecastNodes is the store's nodes, with the links, the resolved labels and the estimates
// brought up to date first.
func (d *Daemon) forecastNodes() []wire.LineageCostNode {
	d.lineageSettle(2 * time.Second)
	d.workMu.Lock()
	defer d.workMu.Unlock()
	d.refreshCostLinksLocked()
	d.refreshCostResolvedLocked()
	d.keepEstimatesLocked()
	return ledgerNodes(d.costLedgerLocked())
}

// keepForecast keeps kept on the node at k when it has none yet, marking it unsent, and is
// what the node keeps; nil when the store has no such node.
func (d *Daemon) keepForecast(k string, kept *wire.LineageForecastKept) *wire.LineageForecastKept {
	d.workMu.Lock()
	defer d.workMu.Unlock()
	ledger := d.costLedgerLocked()
	own, ok := ledger.Nodes[k]
	if !ok {
		return nil
	}
	if own.Forecast == nil && kept != nil {
		own.Forecast = kept
		ledger.Nodes[k] = own
		ledger.Seq++
		ledger.Unsent[k] = ledger.Seq
		d.costChangedLocked()
	}
	return own.Forecast
}

// allowanceBurn is each credential's weekly allowance at the pace of its last reading of the
// week now running, times pace's for its key (a what-if's, #4531): when it runs out, or that
// it lasts to the reset.
func (d *Daemon) allowanceBurn(now time.Time, pace func(key string) float64) []wire.LineageForecastBurn {
	d.allowMu.Lock()
	defer d.allowMu.Unlock()
	out := []wire.LineageForecastBurn{}
	for key, s := range d.allowancesLocked() {
		if b, ok := burnOf(key, s, now, pace(key)); ok {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CredentialKey < out[j].CredentialKey })
	return out
}

// burnOf is a credential's burn from its latest weekly reading whose week has not reset, at
// pace times the pace of the week so far (1 as it ran; 0 never runs out).
func burnOf(key string, s wire.AllowanceState, now time.Time, pace float64) (wire.LineageForecastBurn, bool) {
	var latest *wire.AllowanceReading
	readings := append([]wire.AllowanceReading{}, s.Weeks...)
	if s.Reading != nil {
		readings = append(readings, *s.Reading)
	}
	for i, r := range readings {
		if !isWeekly(r.Window) || r.ResetsAt == nil || r.Used == nil || !r.ResetsAt.Time().After(now) {
			continue
		}
		if latest == nil || r.At > latest.At {
			latest = &readings[i]
		}
	}
	if latest == nil {
		return wire.LineageForecastBurn{}, false
	}
	used, at, resets := min(max(*latest.Used, 0), 1), latest.At.Time(), latest.ResetsAt.Time()
	b := wire.LineageForecastBurn{CredentialKey: key, Window: *latest.Window, Used: used, At: latest.At, ResetsAt: *latest.ResetsAt, Lasts: true}
	elapsed := at.Sub(resets.Add(-allowanceWeek))
	if used >= 1 {
		b.RunsOutAt, b.Lasts = &b.At, false
	} else if used > 0 && elapsed > 0 && pace > 0 {
		out := at.Add(time.Duration(float64(elapsed) * (1 - used) / used / pace))
		if out.Before(resets) {
			when := wire.DateOf(out)
			b.RunsOutAt, b.Lasts = &when, false
		}
	}
	return b, true
}
