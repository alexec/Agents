package agentsd

import (
	"time"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Velocity (#4595, #4596): velocity/history, the PRs the agents worked on that landed, by
// the hour and the day and by repository, shaped as usage/history is so the clients draw it
// with the same chart code. The PRs are the ones the Multiplier counts, kept in the cost
// ledger as they merge (multiplierMergesLocked): the lineage store keeps 90 days of ended
// work, so this counts from it on each ask and keeps no ledger of its own.

// velocityHistory is velocity/history at now: 168 hours and 90 days, in the host's time zone.
func (d *Daemon) velocityHistory(now time.Time) wire.VelocityHistory {
	h := wire.VelocityHistory{Hours: map[string]map[string]wire.VelocityBucket{},
		Days: map[string]map[string]wire.VelocityBucket{}, Now: hourStamp(now), TimeZone: zoneName()}
	firstHour, firstDay := oldestHour(now, usageHoursKept), oldestDay(now, usageDaysKept)
	lastHour, lastDay := hourStamp(now), dayStamp(now)
	d.workMu.Lock()
	defer d.workMu.Unlock()
	nodes := d.costLedgerLocked().Nodes
	for n, m := range d.multiplierMergesLocked() {
		repo := lineage.RepoOf(n)
		if c, ok := nodes[costKey(n)]; ok && c.Repo != nil {
			repo = *c.Repo
		}
		at := m.At.Time()
		if hour := hourStamp(at); hour >= firstHour && hour <= lastHour {
			addVelocity(h.Hours, hour, repo, m.Reverted)
		}
		if day := dayStamp(at); day >= firstDay && day <= lastDay {
			addVelocity(h.Days, day, repo, m.Reverted)
		}
	}
	return h
}

// addVelocity counts one PR that landed in the bucket at stamp.
func addVelocity(buckets map[string]map[string]wire.VelocityBucket, stamp, repo string, reverted bool) {
	byRepo := buckets[stamp]
	if byRepo == nil {
		byRepo = map[string]wire.VelocityBucket{}
		buckets[stamp] = byRepo
	}
	b := byRepo[repo]
	b.Merged++
	if reverted {
		b.Reverted++
	}
	byRepo[repo] = b
}
