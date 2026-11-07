package agentsd

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/lineage"
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

// dueArchived is what a sweep at keep would delete now. The same agents sweepArchived
// keeps are left out: one with no archive time, and a pinned session. Nothing is written.
func (d *Daemon) dueArchived(keep wire.RetentionKeepFor) (count int, bytes int64) {
	days, ok := keepDays(keep)
	if !ok {
		return 0, 0
	}
	cutoff := nowFunc().Add(-days)
	pinned := map[string]map[wire.UUID]bool{}
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateArchived || a.ArchivedAt == nil || !a.ArchivedAt.Time().Before(cutoff) {
			continue
		}
		folder := folderPath(&a)
		if pinned[folder] == nil {
			pinned[folder] = map[wire.UUID]bool{}
			for _, s := range d.readPins(folder).sessions {
				pinned[folder][wire.UUID(strings.ToUpper(string(s.Session)))] = true
			}
		}
		if pinned[folder][wire.UUID(strings.ToUpper(string(a.ID)))] {
			continue
		}
		count++
		bytes += folderBytes(d.Store.Loc.Agent(string(a.ID)))
	}
	return count, bytes
}

// setRetention is retention/set. Unconfirmed, a change that would delete agents now is
// only described. Confirmed, or a change that deletes nothing, is saved and swept.
func (d *Daemon) setRetention(r wire.RetentionSetRequest) (wire.RetentionSetResult, error) {
	keep := r.Settings.KeepFor
	switch keep {
	case wire.RetentionKeepForDays7, wire.RetentionKeepForDays14, wire.RetentionKeepForDays30,
		wire.RetentionKeepForDays90, wire.RetentionKeepForForever:
	default:
		keep = wire.RetentionKeepForDays30
	}
	count, bytes := d.dueArchived(keep)
	if !r.Confirmed && count > 0 {
		return wire.RetentionSetResult{Applied: false, WouldDelete: &wire.DeletePreview{Count: int64(count), Bytes: bytes}}, nil
	}
	if err := d.writeSetting("retention.json", wire.RetentionSettings{KeepFor: keep}); err != nil {
		return wire.RetentionSetResult{}, &Error{Code: wire.FailureCouldNotSave, Message: "retention.json: " + err.Error()}
	}
	d.sweepArchived()
	state := d.retentionState()
	Broadcast(d, wire.NotifyRetentionChanged, state)
	return wire.RetentionSetResult{Applied: true, State: &state}, nil
}

// keepDays is how long an archived agent is kept; false for Forever.
func keepDays(keep wire.RetentionKeepFor) (time.Duration, bool) {
	days := map[wire.RetentionKeepFor]int{wire.RetentionKeepForDays7: 7, wire.RetentionKeepForDays14: 14,
		wire.RetentionKeepForDays30: 30, wire.RetentionKeepForDays90: 90}
	n, ok := days[keep]
	return time.Duration(n) * 24 * time.Hour, ok
}

// StartRetention sweeps now, then every hour: archived agents, then attachments (#1556),
// then the stores whose bound was applied only at start or on next use (#3649). What a
// crash left is swept once, at start.
func (d *Daemon) StartRetention() {
	started := time.Now()
	safe.Go("retention", func() { d.retentionClock(started) })
}

func (d *Daemon) retentionClock(started time.Time) {
	d.sweepCrashLeftovers(started)
	d.sweepHourly()
	t := time.NewTicker(retentionSweepEvery)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			d.sweepHourly()
		}
	}
}

func (d *Daemon) sweepHourly() {
	d.sweepArchived()
	d.sweepAttachments()
	d.sweepOldRuns()
	sweepTransfers(d.outgoingFolder())
	sweepTransfers(d.incomingFolder())
	d.sweepDropboxParts()
	if n := d.lineage().Prune(); n > 0 {
		log.Printf("retention: %d ended lineage links past %v", n, lineage.KeepEnded)
	}
	d.sweepHistories(nowFunc())
	d.sweepSmallStores(nowFunc())
	d.sweepGoneRoots()
}

// sweepGoneRoots removes the cache and log folders of each root that is gone (#3746). A
// root in a temporary folder, a scratch one, leaves the person's folders alone.
func (d *Daemon) sweepGoneRoots() {
	if d.Store.Loc.Cache == filepath.Join(d.Store.Loc.Root, "cache") {
		return
	}
	for _, dir := range store.SweepGoneRoots() {
		log.Printf("retention: removed %s, whose root is gone", dir)
	}
}

// sweepHistories bounds spend, usage, time and features by age (#3686), so a machine
// with no work does not keep old days until its next write. A store is written only when
// a day or an hour went.
func (d *Daemon) sweepHistories(now time.Time) {
	d.costMu.Lock()
	if n := pruneSpend(d.spendLocked(), now); n > 0 {
		d.flushSpendLocked()
	}
	if n := pruneUsage(d.usageLocked(), now); n > 0 {
		if err := writeStore(d.usagePath(), d.usage); err != nil {
			log.Printf("usage-history.json: could not save: %v", err)
		}
	}
	d.costMu.Unlock()
	d.timeMu.Lock()
	if n := pruneTime(d.timeLocked(), now); n > 0 {
		if err := writeStore(d.timePath(), d.timeHeld); err != nil {
			log.Printf("time-history.json: could not save: %v", err)
		}
	}
	d.timeMu.Unlock()
	d.featureMu.Lock()
	if n := pruneFeatures(d.featuresLocked(), now); n > 0 {
		d.featureDirty = true
	}
	d.featureMu.Unlock()
	d.saveFeatures()
}

// sweepCrashLeftovers removes what a run cut off by a crash left (#3649): a restore's
// staging folder, the skill catalog's previews and the browser's output. Only what was
// last changed before this start goes: a restore or a browser begun since is in use.
func (d *Daemon) sweepCrashLeftovers(started time.Time) {
	remove := func(dir string, match func(name string) bool) {
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if info, err := e.Info(); err == nil && match(e.Name()) && info.ModTime().Before(started) {
				os.RemoveAll(filepath.Join(dir, e.Name()))
			}
		}
	}
	remove(d.Store.Loc.Root, func(name string) bool { return strings.HasPrefix(name, ".restore-") })
	every := func(string) bool { return true }
	remove(filepath.Join(d.Store.Loc.Cache, "catalog-staging"), every)
	remove(filepath.Join(d.Store.Loc.Cache, "browser", "output"), every)
}

// sweepArchived deletes each archived agent archived longer ago than keepFor. A pinned
// agent is kept. An archived record with no archive time (from before it was kept) gets
// the time of this sweep, so it goes keepFor from now (051 R5, legacy).
func (d *Daemon) sweepArchived() (deleted int) {
	keep, ok := keepDays(d.keepFor())
	cutoff := nowFunc().Add(-keep)
	pinned := map[string]map[wire.UUID]bool{}
	// The runtime copies are queued in batches, each with one rewrite of the files (#2427).
	var erase []*wire.Agent
	defer func() { d.queueErasures(erase) }()
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
		folder := folderPath(&a)
		if pinned[folder] == nil {
			pinned[folder] = map[wire.UUID]bool{}
			for _, s := range d.readPins(folder).sessions {
				pinned[folder][wire.UUID(strings.ToUpper(string(s.Session)))] = true
			}
		}
		if pinned[folder][wire.UUID(strings.ToUpper(string(a.ID)))] {
			continue
		}
		// Unarchived since the list was read: kept.
		if cur := d.Store.Agent(a.ID); cur == nil || cur.State != wire.AgentStateArchived {
			continue
		}
		if err := d.deleteArchivedThen(&a, "retention", func(a *wire.Agent) { erase = append(erase, a) }); err != nil {
			log.Printf("retention: %s: %v", a.ID, err)
			continue
		}
		deleted++
		if len(erase) >= eraseBatch {
			d.queueErasures(erase)
			erase = nil
		}
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
