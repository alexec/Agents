package agentsd

import (
	"log"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Archived agents are kept for the person's time in retention.json (#398), then deleted
// (#1554): a sweep at start and every hour, through the same path as a manual delete.

const retentionSweepEvery = time.Hour

// keepFor is retention.json's keepFor. A value this build cannot read is the default,
// never Forever: a file it cannot read must not turn deletion off.
func (d *Daemon) keepFor() wire.RetentionKeepFor {
	var raw struct {
		KeepFor string `json:"keepFor"`
	}
	d.readSetting("retention.json", &raw)
	keep := wire.RetentionKeepFor(raw.KeepFor)
	switch keep {
	case wire.RetentionKeepForDays7, wire.RetentionKeepForDays14, wire.RetentionKeepForDays30, wire.RetentionKeepForDays90,
		wire.RetentionKeepForForever:
		return keep
	}
	return wire.RetentionKeepForDays30
}

// keepDays is how long an archived agent is kept; false for Forever.
func keepDays(keep wire.RetentionKeepFor) (time.Duration, bool) {
	days := map[wire.RetentionKeepFor]int{wire.RetentionKeepForDays7: 7, wire.RetentionKeepForDays14: 14,
		wire.RetentionKeepForDays30: 30, wire.RetentionKeepForDays90: 90}
	n, ok := days[keep]
	return time.Duration(n) * 24 * time.Hour, ok
}

// StartRetention sweeps now, then every hour.
func (d *Daemon) StartRetention() { safe.Go("retention", d.retentionClock) }

func (d *Daemon) retentionClock() {
	d.sweepArchived()
	t := time.NewTicker(retentionSweepEvery)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			d.sweepArchived()
		}
	}
}

// sweepArchived deletes each archived agent archived longer ago than keepFor. A pinned
// agent is kept. An archived record with no archive time (from before it was kept) gets
// the time of this sweep, so it goes keepFor from now (051 R5, legacy).
func (d *Daemon) sweepArchived() (deleted int) {
	keep, ok := keepDays(d.keepFor())
	cutoff := nowFunc().Add(-keep)
	pinned := map[string]map[wire.UUID]bool{}
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateArchived {
			continue
		}
		if a.ArchivedAt == nil {
			d.stampArchived(a.ID)
			continue
		}
		if !ok || !a.ArchivedAt.Time().Before(cutoff) {
			continue
		}
		project := projectFolder(&a)
		if pinned[project] == nil {
			pinned[project] = map[wire.UUID]bool{}
			for _, s := range d.readPins(project).sessions {
				pinned[project][wire.UUID(strings.ToUpper(string(s.Session)))] = true
			}
		}
		if pinned[project][wire.UUID(strings.ToUpper(string(a.ID)))] {
			continue
		}
		// Unarchived since the list was read: kept.
		if cur := d.Store.Agent(a.ID); cur == nil || cur.State != wire.AgentStateArchived {
			continue
		}
		if err := d.deleteArchived(&a, "retention"); err != nil {
			log.Printf("retention: %s: %v", a.ID, err)
			continue
		}
		deleted++
	}
	return deleted
}

// stampArchived gives an archived record with no archive time this one, and leaves its
// last activity as it is.
func (d *Daemon) stampArchived(id wire.UUID) {
	d.agentMu.Lock()
	defer d.agentMu.Unlock()
	a := d.Store.Agent(id)
	if a == nil || a.State != wire.AgentStateArchived || a.ArchivedAt != nil {
		return
	}
	t := now()
	a.ArchivedAt = &t
	if err := d.Store.Save(*a); err != nil {
		log.Printf("retention: %s: %v", id, err)
	}
}
