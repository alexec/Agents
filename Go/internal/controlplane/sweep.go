package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// What the store keeps, and for how long (StoreSweep, #174, contracts/store.md rule 11).
// Events are the audit (#996), kept for control.json's auditDays.
const (
	codesKeptAfterExpiry = 24 * time.Hour
	tombstonesKept       = 7 * 24 * time.Hour
	leftoversKept        = time.Hour
	sweepEvery           = time.Hour
	mostPerSweep         = 1000
	eventsPrefix         = "v1/events/"
	codesPrefix          = "v1/codes/"
	sweptDayLayout       = "2006-01-02"

	tombstoneDatedWarning = ""
)

// sweepReport is StoreSweep.Report.
type sweepReport struct {
	events, codes, tombstones, leftovers, dated, usage int
}

func (r sweepReport) total() int { return r.events + r.codes + r.tombstones + r.leftovers + r.usage }

func (r sweepReport) String() string {
	return fmt.Sprintf("removed %d events, %d code files, %d tombstones, %d leftovers, %d usage periods; dated %d tombstones",
		r.events, r.codes, r.tombstones, r.leftovers, r.usage, r.dated)
}

// sweep is StoreSweep.run: old events, spent and expired codes, old tombstones and a
// folder's leftovers out of the store, at most most deletions a time, so a store never
// swept is caught up over a few hours. Deleting is plain: a race between two copies
// changes nothing.
// events is where the last sweep left the audit; nil sweeps as the first does.
func sweep(ctx context.Context, rs *records.Records, now time.Time, most int, events *eventSweep) (sweepReport, error) {
	var report sweepReport
	if events == nil {
		events = &eventSweep{}
	}
	s := rs.Store
	left := most

	// Events, by the day in their key: the audit's days (#996), or the days before a
	// shorter time for a day after it (#2067).
	cutoff := audit.Cutoff(audit.SweepDays(rs.Settings(), now), now)
	n, err := events.sweep(ctx, s, cutoff, left)
	report.events += n
	left -= n
	if err != nil {
		return report, err
	}
	// The audit chain's seals (#1001), a day's each, go with their day's entries.
	n, err = audit.SweepSeals(ctx, s, cutoff)
	report.events += n
	left -= n
	if err != nil {
		return report, err
	}

	// Codes, by their expiry; a .spent whose code is gone goes too.
	codes, err := s.List(ctx, codesPrefix)
	if err != nil {
		return report, err
	}
	named := map[string]bool{}
	for _, c := range codes {
		named[c.Key] = true
	}
	expiredBefore := now.Add(-codesKeptAfterExpiry)
	for _, c := range codes {
		// Two left at least: a code may go with its .spent.
		if left <= 1 {
			break
		}
		if strings.HasSuffix(c.Key, ".spent") {
			if named[strings.TrimSuffix(c.Key, ".spent")+".json"] {
				continue
			}
		} else {
			object, err := s.Get(ctx, c.Key)
			if err != nil {
				return report, err
			}
			var stored storedCode
			if object == nil || json.Unmarshal(object.Data, &stored) != nil || !stored.Expires.Before(expiredBefore) {
				continue
			}
			spentKey := strings.TrimSuffix(c.Key, ".json") + ".spent"
			if named[spentKey] {
				if err := s.Delete(ctx, spentKey); err != nil {
					return report, err
				}
				report.codes++
				left--
			}
		}
		if err := s.Delete(ctx, c.Key); err != nil {
			return report, err
		}
		report.codes++
		left--
	}

	// Tombstones, as the records found them.
	forgottenBefore := now.Add(-tombstonesKept)
	for _, key := range rs.TombstoneKeys() {
		if left <= 0 {
			break
		}
		object, err := s.Get(ctx, key)
		if err != nil {
			return report, err
		}
		var mark struct {
			Forgotten   *bool          `json:"forgotten"`
			ForgottenAt *records.Stamp `json:"forgottenAt"`
		}
		if object == nil || json.Unmarshal(object.Data, &mark) != nil || mark.Forgotten == nil || !*mark.Forgotten {
			continue
		}
		if mark.ForgottenAt == nil {
			// One written before forgottenAt was kept is given today's, so it goes a week on.
			if dated, err := dateTombstone(ctx, s, key, object, now); err != nil {
				return report, err
			} else if dated {
				report.dated++
			}
			continue
		}
		if !mark.ForgottenAt.Before(forgottenBefore) {
			continue
		}
		// Read again just before: a record written over it since is not a tombstone.
		again, err := s.Get(ctx, key)
		if err != nil {
			return report, err
		}
		if again == nil || again.ETag != object.ETag {
			continue
		}
		if err := s.Delete(ctx, key); err != nil {
			return report, err
		}
		report.tombstones++
		left--
	}

	// The reports' hours and days (#1811).
	usage, err := sweepUsage(ctx, s, now, left)
	report.usage = usage
	if err != nil {
		return report, err
	}
	// Bots' run claims (#1761), counted with the usage periods.
	runs, err := sweepRuns(ctx, s, now, left-usage)
	report.usage += runs
	if err != nil {
		return report, err
	}

	if folder, ok := s.(*store.Folder); ok {
		report.leftovers = folder.RemoveLeftovers(now.Add(-leftoversKept))
	}
	// The records forget the tombstones that went, and see the dated ones.
	if report.tombstones+report.dated > 0 {
		if err := rs.Load(ctx); err != nil {
			return report, err
		}
	}
	return report, nil
}

// dateTombstone gives a tombstone from before forgottenAt today's date, against the
// version read.
func dateTombstone(ctx context.Context, s store.Store, key string, object *store.Object, now time.Time) (bool, error) {
	var data []byte
	var err error
	at := records.At(now)
	if strings.HasPrefix(key, records.ClientsPrefix) {
		var r records.ClientRecord
		if json.Unmarshal(object.Data, &r) != nil {
			return false, nil
		}
		r.ForgottenAt, r.Rev = &at, r.Rev+1
		data, err = records.Encode(r)
	} else {
		var r records.HostRecord
		if json.Unmarshal(object.Data, &r) != nil {
			return false, nil
		}
		r.ForgottenAt, r.Rev = &at, r.Rev+1
		data, err = records.Encode(r)
	}
	if err != nil {
		return false, err
	}
	if _, err := s.Put(ctx, key, data, store.Matching(object.ETag)); err != nil {
		if store.IsConflict(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// eventSweep is the oldest day that may still hold events, so a sweep lists only the
// days that have expired, a day each, not every day the audit keeps (#2053). The first
// sweep finds it from one list of every event.
type eventSweep struct{ oldest string }

// sweep deletes, at most most, the events of each day before cutoff, from the oldest,
// and says how many it deleted.
func (e *eventSweep) sweep(ctx context.Context, s store.Store, cutoff string, most int) (int, error) {
	if e.oldest == "" {
		all, err := s.List(ctx, eventsPrefix)
		if err != nil {
			return 0, err
		}
		e.oldest = cutoff
		for _, k := range all {
			// Sorted, so the first that names a day names the oldest.
			if day := audit.KeyDay(k.Key); audit.NextDay(day) != "" {
				e.oldest = min(day, cutoff)
				break
			}
		}
	}
	deleted := 0
	for e.oldest < cutoff && deleted < most {
		keys, err := s.List(ctx, audit.DayFolder(e.oldest))
		if err != nil {
			return deleted, err
		}
		for _, k := range keys {
			if deleted >= most {
				return deleted, nil
			}
			if err := s.Delete(ctx, k.Key); err != nil {
				return deleted, err
			}
			deleted++
		}
		e.oldest = audit.NextDay(e.oldest)
	}
	return deleted, nil
}

// sweepEveryHour runs the sweep once an hour, the first a minute after start (#174).
func (s *Service) sweepEveryHour() {
	select {
	case <-s.stop:
		return
	case <-time.After(time.Minute):
	}
	t := time.NewTicker(sweepEvery)
	defer t.Stop()
	var events eventSweep
	for {
		// Only while serving: a receiving or forwarding copy leaves the store alone.
		var report sweepReport
		var err error
		if s.phase.now() == phaseServing {
			// Today's head of this copy's audit chain, sealed (#1001).
			if err := s.auditChain.Seal(context.Background(), s.cfg.Store, time.Now()); err != nil {
				s.log("audit: could not seal the chain: " + err.Error())
			}
			report, err = sweep(context.Background(), s.records, time.Now(), mostPerSweep, &events)
			s.renewConnected(context.Background())
			s.dropPreviousKey(context.Background())
		}
		switch {
		case err != nil:
			s.log("store: sweep stopped: " + err.Error())
		case report.total()+report.dated > 0:
			s.log("store: swept; " + report.String())
		}
		select {
		case <-s.stop:
			return
		case <-t.C:
		}
	}
}
