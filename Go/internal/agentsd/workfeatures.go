package agentsd

import (
	"cmp"
	"context"
	"slices"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Work ▸ Features as a delivery view (#4586, specs/4328-work-look/features-delivery.md): one read
// that gives the page each feature with its open epics, each epic's step of steps, its blockers
// outside the plan, its forecast and its children, and the feature's loose open issues, so an
// open feature's epics draw at once. It is forge/features, forge/plan for each open epic (with
// the forge cache the Plan uses) and work/timeline's forecast for each project of the folders.

// workFeaturesPlans is how many plans are read at once: a page of twenty epics is not twenty
// reads one after another, and not twenty at once against the forge's rate limit.
const workFeaturesPlans = 4

func (d *Daemon) registerWorkFeatures() {
	On(d, wire.CallWorkFeatures, func(ctx context.Context, _ *Client, r wire.WorkFeaturesRequest) (wire.WorkFeatures, error) {
		return d.workFeatures(ctx, r)
	})
}

func (d *Daemon) workFeatures(ctx context.Context, r wire.WorkFeaturesRequest) (wire.WorkFeatures, error) {
	features, items, err := d.forgeFeaturesRead(ctx, wire.ForgeFeaturesRequest(r))
	if err != nil {
		return wire.WorkFeatures{}, Invalid("work/features: %v", strings.TrimPrefix(err.Error(), "forge/features: "))
	}
	out := wire.WorkFeatures{Features: []wire.WorkFeature{}, Approvals: features.Approvals, Errors: features.Errors}
	addError := func(e wire.ForgeListError) {
		if !slices.Contains(out.Errors, e) {
			out.Errors = append(out.Errors, e)
		}
	}

	// Each open epic's plan, a few at once, and each project's timeline beside them.
	var epics []wire.ForgeItem
	for _, f := range features.Features {
		epics = append(epics, items.epics[strings.ToLower(f.Name)]...)
	}
	plans := make([]wire.ForgePlan, len(epics))
	planErrs := make([]error, len(epics))
	var wg sync.WaitGroup
	next := make(chan int)
	for range min(workFeaturesPlans, len(epics)) {
		wg.Go(func() {
			for n := range next {
				plans[n], planErrs[n] = d.forgePlan(ctx, wire.ForgePlanRequest{Node: epics[n].Node})
			}
		})
	}
	var timeline map[string]wire.WorkTimelineEpic
	var timelineErrs []string
	wg.Go(func() { timeline, timelineErrs = d.workFeaturesTimeline(ctx, deref(r.Folder)) })
	for n := range epics {
		next <- n
	}
	close(next)
	wg.Wait()
	for _, e := range timelineErrs {
		addError(wire.ForgeListError{Forge: "github", Message: e})
	}

	planOfEpic := map[string]int{}
	for n, e := range epics {
		planOfEpic[e.Node.Ref] = n
		if planErrs[n] != nil {
			r, _ := lineage.RefOf(e.Node)
			forge := r.Provider
			addError(wire.ForgeListError{Forge: forge, Message: e.Node.Ref + ": " + planErrs[n].Error()})
		}
	}
	for _, f := range features.Features {
		key := strings.ToLower(f.Name)
		wf := wire.WorkFeature{Feature: f, Epics: []wire.WorkFeatureEpic{}, Loose: []wire.WorkTimelineChild{}}
		for _, e := range items.epics[key] {
			n := planOfEpic[e.Node.Ref]
			if planErrs[n] != nil {
				wf.Epics = append(wf.Epics, wire.WorkFeatureEpic{Item: e})
				continue
			}
			wf.Epics = append(wf.Epics, d.workFeatureEpic(e, plans[n], timeline[e.Node.Ref]))
		}
		loose := slices.Clone(items.loose[key])
		slices.SortStableFunc(loose, func(a, b wire.ForgeItem) int { return cmp.Compare(b.UpdatedAt, a.UpdatedAt) })
		for _, i := range loose {
			wf.Loose = append(wf.Loose, d.workFeatureChild(i))
		}
		out.Features = append(out.Features, wf)
	}
	return out, nil
}

// workFeatureEpic is an open epic with where it is in its plan: the first step with an open
// child, the open blockers outside the plan of that step's open children, its forecast from the
// timeline (tl's zero value when the timeline has none) and its children in the plan's order.
func (d *Daemon) workFeatureEpic(epic wire.ForgeItem, plan wire.ForgePlan, tl wire.WorkTimelineEpic) wire.WorkFeatureEpic {
	out := wire.WorkFeatureEpic{Item: epic, Steps: int64(len(plan.Steps)), Forecast: tl.Forecast, Children: []wire.WorkTimelineChild{}}
	fromTimeline := map[string]wire.WorkTimelineChild{}
	for _, c := range tl.Children {
		fromTimeline[c.Item.Node.Ref] = c
	}
	for _, c := range plan.Children {
		if c.Item.State == "open" && (out.Step == nil || c.Step == *out.Step) {
			out.Step = new(c.Step)
			for _, b := range c.BlockedOutside {
				if !slices.Contains(out.BlockedOutside, b) {
					out.BlockedOutside = append(out.BlockedOutside, b)
				}
			}
		}
		// The timeline's child knows when its first pull request opened, and its forecast close.
		if t, ok := fromTimeline[c.Item.Node.Ref]; ok {
			t.Item = c.Item
			out.Children = append(out.Children, t)
			continue
		}
		out.Children = append(out.Children, d.workFeatureChild(c.Item))
	}
	return out
}

// workFeatureChild is an issue as work/timeline says a child, from what a forge list or plan
// gives: its start from lineage (or its close), and whether it waits for a person.
func (d *Daemon) workFeatureChild(i wire.ForgeItem) wire.WorkTimelineChild {
	out := wire.WorkTimelineChild{Item: i, StateReason: i.StateReason, ClosedAt: i.ClosedAt}
	if i.CreatedAt != nil {
		out.CreatedAt = *i.CreatedAt
	}
	out.StartedAt, out.WaitsForPerson = d.childStarted(i.Node, i.ClosedAt, nil), waitsForPerson(i)
	return out
}

// workFeaturesTimeline is the open epics of work/timeline, by ref, for each project of the
// folders (only folder's, when it is set) that is on GitHub: the timeline reads only GitHub's.
func (d *Daemon) workFeaturesTimeline(ctx context.Context, folder string) (map[string]wire.WorkTimelineEpic, []string) {
	out := map[string]wire.WorkTimelineEpic{}
	var errs []string
	var projects []string
	for _, f := range d.folderPaths() {
		if folder != "" && f != folder || d.folderRepo(f).forge != "github" {
			continue
		}
		if p := projectOfFolder(f); p != "" && !slices.Contains(projects, p) {
			projects = append(projects, p)
		}
	}
	now := wire.DateOf(nowFunc())
	for _, p := range projects {
		tl, err := d.workTimeline(ctx, wire.WorkTimelineRequest{Project: p, From: now, To: now})
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		for _, e := range tl.Errors {
			// An epic on another forge is still on the page, with no forecast.
			if !strings.HasSuffix(e, timelineGitHubOnly) && !slices.Contains(errs, e) {
				errs = append(errs, e)
			}
		}
		for _, e := range tl.Epics {
			if e.Item.State == "open" {
				out[e.Item.Node.Ref] = e
			}
		}
	}
	return out, errs
}
