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
	events, codes, tombstones, leftovers, dated int
}

func (r sweepReport) total() int { return r.events + r.codes + r.tombstones + r.leftovers }

func (r sweepReport) String() string {
	return fmt.Sprintf("removed %d events, %d code files, %d tombstones, %d leftovers; dated %d tombstones",
		r.events, r.codes, r.tombstones, r.leftovers, r.dated)
}

// sweep is StoreSweep.run: old events, spent and expired codes, old tombstones and a
// folder's leftovers out of the store, at most most deletions a time, so a store never
// swept is caught up over a few hours. Deleting is plain: a race between two copies
// changes nothing.
func sweep(ctx context.Context, rs *records.Records, now time.Time, most int) (sweepReport, error) {
	var report sweepReport
	s := rs.Store
	left := most

	// Events, by the day in their key: the audit's days (#996).
	days := audit.Days(rs.Settings())
	events, err := s.List(ctx, eventsPrefix)
	if err != nil {
		return report, err
	}
	for _, e := range events {
		if left <= 0 {
			break
		}
		if !audit.Expired(e.Key, days, now) {
			continue
		}
		if err := s.Delete(ctx, e.Key); err != nil {
			return report, err
		}
		report.events++
		left--
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

// sweepEveryHour runs the sweep once an hour, the first a minute after start (#174).
func (s *Service) sweepEveryHour() {
	select {
	case <-s.stop:
		return
	case <-time.After(time.Minute):
	}
	t := time.NewTicker(sweepEvery)
	defer t.Stop()
	for {
		// Only while serving: a receiving or forwarding copy leaves the store alone.
		var report sweepReport
		var err error
		if s.phase.now() == phaseServing {
			report, err = sweep(context.Background(), s.records, time.Now(), mostPerSweep)
			s.renewConnected(context.Background())
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
