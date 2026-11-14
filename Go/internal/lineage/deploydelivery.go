package lineage

import (
	"slices"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The DORA figures of one target (#5245, spec 5239-deploy-model, "What it gives us"): a
// component in one environment, from its deploys, over a range.
//
//   - Deployment frequency: the deploys that succeeded, a week.
//   - Lead time for changes: a PR's merge to the first succeeded deploy that brings it. The
//     median, and p90.
//   - Change failure rate: the failed deploys and the rollbacks, over the deploys that ended
//     (succeeded or failed; a cancelled one is neither).
//   - Failed deployment recovery time: a failed deploy's end, or a health signal seen in a
//     deploy, to the next deploy that succeeded. The median.
//
// Each is counted at the deploy's end, with a series of 7-day weeks back from at, and DORA
// 2024's band, as DeliveryOf's are.

// DeployFact is one deploy of a target, as the figures need it.
type DeployFact struct {
	State wire.DeployState
	// At is when it ended: its finish, else its start.
	At wire.Date
	// Rollback is a succeeded deploy that put an older version back.
	Rollback bool
	// Merges are the merge times of the PRs it brings, for a succeeded deploy.
	Merges []wire.Date
	// Health are the times health signals were seen in it.
	Health []wire.Date
}

// DeployFigures is a target's four figures.
type DeployFigures struct {
	Ended, Failed, Rollbacks                                      int
	DeploymentFrequency, LeadTime, ChangeFailureRate, RecoveryTime wire.LineageDeliveryFigure
}

// DeployFiguresOf is the four figures of one target's deploys, over [since, at].
func DeployFiguresOf(deploys []DeployFact, since, at wire.Date) DeployFigures {
	ds := slices.Clone(deploys)
	slices.SortFunc(ds, func(a, b DeployFact) int {
		switch {
		case a.At < b.At:
			return -1
		case a.At > b.At:
			return 1
		}
		return 0
	})
	in := func(t wire.Date) bool { return t >= since && t <= at }
	var out DeployFigures
	var went, lead, failures, recovery []sample
	// nextGood is the first deploy that succeeded after t, at its end.
	nextGood := func(t wire.Date) (wire.Date, bool) {
		for _, d := range ds {
			if d.State == wire.DeployStateSucceeded && d.At > t {
				return d.At, true
			}
		}
		return 0, false
	}
	for _, d := range ds {
		if d.State == wire.DeployStateSucceeded || d.State == wire.DeployStateFailed {
			if in(d.At) {
				out.Ended++
				failed := d.State == wire.DeployStateFailed
				if failed {
					out.Failed++
				}
				if d.Rollback && !failed {
					out.Rollbacks++
				}
				v := 0.0
				if failed || d.Rollback {
					v = 1
				}
				failures = append(failures, sample{d.At, v})
			}
		}
		if d.State == wire.DeployStateFailed {
			if good, ok := nextGood(d.At); ok && in(good) {
				recovery = append(recovery, sample{good, float64(good - d.At)})
			}
		}
		for _, h := range d.Health {
			if good, ok := nextGood(h); ok && in(good) {
				recovery = append(recovery, sample{good, float64(good - h)})
			}
		}
		if d.State != wire.DeployStateSucceeded || !in(d.At) {
			continue
		}
		went = append(went, sample{d.At, 1})
		for _, m := range d.Merges {
			if m <= d.At {
				lead = append(lead, sample{d.At, float64(d.At - m)})
			}
		}
	}

	out.DeploymentFrequency = figureOf(went, since, at, func(v []float64) float64 { return float64(len(v)) })
	if weeks := float64(len(out.DeploymentFrequency.Weeks)); weeks > 0 {
		perWeek := float64(out.DeploymentFrequency.Count) / weeks
		out.DeploymentFrequency.Value = &perWeek
		out.DeploymentFrequency.Band = band(&perWeek, frequencyBand)
	}
	for i, w := range out.DeploymentFrequency.Weeks {
		v := float64(w.Count)
		out.DeploymentFrequency.Weeks[i].Value = &v
	}
	out.LeadTime = figureOf(lead, since, at, median)
	if v := valuesIn(lead, since, at+1); len(v) > 0 {
		p := percentile(v, 0.9)
		out.LeadTime.P90 = &p
	}
	out.LeadTime.Band = band(out.LeadTime.Value, leadBand)
	out.ChangeFailureRate = figureOf(failures, since, at, mean)
	out.ChangeFailureRate.Band = band(out.ChangeFailureRate.Value, failureBand)
	out.RecoveryTime = figureOf(recovery, since, at, median)
	out.RecoveryTime.Band = band(out.RecoveryTime.Value, recoveryBand)
	return out
}
