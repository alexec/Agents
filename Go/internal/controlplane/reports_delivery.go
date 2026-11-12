package controlplane

import (
	"cmp"
	"context"
	"slices"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Reports ▸ Planning's Delivery row (#4555, epic #4551): the delivery figures of the repos a
// scope merged most in, from the scope's machines' nodes (each node once, as reports/value
// reads them) and the release tags' times from their links (the merged copy, #4276), as a
// machine's lineage/figures has them for one repo (#4552). The window is lineage's 4 weeks,
// whatever the page's range. A figure is of a scope, never of a person.

// mostDeliveryRepos bounds the repos reports/value gives delivery figures for.
const mostDeliveryRepos = 3

// deliveryRepos is the repos with a PR merged in the delivery window before now, the most
// merges first, at most mostDeliveryRepos, each in the full form.
func deliveryRepos(nodes []wire.LineageCostNode, now time.Time) []string {
	since := wire.DateOf(now.Add(-lineage.DeliveryWindow))
	count := map[string]int{}
	for _, n := range nodes {
		if n.Node.Kind != lineage.KindPR || n.Repo == nil || n.EndedAt == nil || *n.EndedAt < since || n.Outcome == nil ||
			(*n.Outcome != lineage.OutcomeMerged && *n.Outcome != lineage.OutcomeReverted) {
			continue
		}
		count[lineage.FullRepoText(*n.Repo)]++
	}
	repos := make([]string, 0, len(count))
	for r := range count {
		repos = append(repos, r)
	}
	slices.SortFunc(repos, func(a, b string) int { return cmp.Or(cmp.Compare(count[b], count[a]), cmp.Compare(a, b)) })
	return repos[:min(len(repos), mostDeliveryRepos)]
}

// releaseTimesIn is each release tag's time, by ref, from links: its earliest link's, as a
// machine puts a release's links at its tag's commit time.
func releaseTimesIn(links []wire.LineageLink) map[string]wire.Date {
	out := map[string]wire.Date{}
	for _, l := range links {
		if l.To.Kind != lineage.KindRelease {
			continue
		}
		if t, ok := out[l.To.Ref]; !ok || l.At < t {
			out[l.To.Ref] = l.At
		}
	}
	return out
}

// deliveryOf is the delivery figures of the repos the scope merged most in.
func deliveryOf(nodes []wire.LineageCostNode, links []wire.LineageLink, now time.Time) []wire.ReportDelivery {
	repos := deliveryRepos(nodes, now)
	out := make([]wire.ReportDelivery, 0, len(repos))
	if len(repos) == 0 {
		return out
	}
	releases := releaseTimesIn(links)
	for _, repo := range repos {
		out = append(out, wire.ReportDelivery{Repo: repo, Figures: lineage.DeliveryOf(nodes, repo, releases, now)})
	}
	return out
}

// keptDelivery is the delivery figures of the machines whose people keep says, from their
// nodes.
func (s *Service) keptDelivery(ctx context.Context, keep func(person string) bool, nodes []wire.LineageCostNode,
	now time.Time) ([]wire.ReportDelivery, error) {
	if len(deliveryRepos(nodes, now)) == 0 {
		return []wire.ReportDelivery{}, nil
	}
	g, err := s.keptLineageGraph(ctx, keep)
	if err != nil {
		return nil, err
	}
	return deliveryOf(nodes, g.links, now), nil
}

// deliveryReport is the delivery figures of a scope that user may see: the Read API's
// report=delivery (#4555).
func (s *Service) deliveryReport(ctx context.Context, scope *wire.ReportScope, user string, now time.Time) ([]wire.ReportDelivery, error) {
	_, keep, _, err := s.reportScope(ctx, scope, user, s.isAdmin(user))
	if err != nil {
		return nil, err
	}
	nodes, err := s.scopeLineage(ctx, keep)
	if err != nil {
		return nil, err
	}
	return s.keptDelivery(ctx, keep, nodes, now)
}

// deliveryMetrics are the OTLP gauges of the delivery figures (#4555): each figure's value
// over the 4 weeks to now, by repo; a figure made from none sends no point.
var deliveryMetrics = []struct {
	name, unit, about string
	of                func(wire.LineageDelivery) wire.LineageDeliveryFigure
}{
	{"agents.delivery.lead_time", "s", "Lead time for changes, the median over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.LeadTime }},
	{"agents.delivery.deployment_frequency", "{release}/wk", "Release tags a week over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.DeploymentFrequency }},
	{"agents.delivery.change_failure_rate", "1", "Failures over merged PRs, 0 to 1, over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.ChangeFailureRate }},
	{"agents.delivery.recovery_time", "s", "Failed deployment recovery time, the median over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.RecoveryTime }},
	{"agents.delivery.rework_rate", "1", "The share of merged PRs that change a file merged in the 21 days before, over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.ReworkRate }},
	{"agents.delivery.flow_efficiency", "1", "The agents' working time over the cycle time, the median over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.FlowEfficiency }},
	{"agents.delivery.approval_wait", "s", "How long a PR waited for a person's answer, the median over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.ApprovalWait }},
	{"agents.delivery.ci_time_to_green", "s", "A merged PR's last push to its checks passing, the median over 4 weeks, by repo.",
		func(d wire.LineageDelivery) wire.LineageDeliveryFigure { return d.CiTimeToGreen }},
}

// deliveryGauges is the OTLP metrics of the organisation's delivery figures, as gauges.
func deliveryGauges(all []wire.ReportDelivery, at string) []any {
	var metrics []any
	for _, m := range deliveryMetrics {
		var points []any
		for _, d := range all {
			f := m.of(d.Figures)
			if f.Value == nil {
				continue
			}
			points = append(points, map[string]any{"attributes": otlpAttributes(map[string]string{"repo": d.Repo}),
				"timeUnixNano": at, "asDouble": *f.Value})
		}
		if len(points) > 0 {
			metrics = append(metrics, map[string]any{"name": m.name, "unit": m.unit, "description": m.about,
				"gauge": map[string]any{"dataPoints": points}})
		}
	}
	return metrics
}
