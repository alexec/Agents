package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// What the store keeps, and for how long (StoreSweep, #174, contracts/store.md rule 11).
// Events are the audit (#996), kept for control.json's auditDays.
const (
	codesKeptAfterExpiry = 24 * time.Hour
	tombstonesKept       = 7 * 24 * time.Hour
	// A removed person goes once every code they made has run out (FR-029, #3126).
	removedPeopleKept = inviteLifetime + tombstonesKept
	leftoversKept     = time.Hour
	sweepEvery        = time.Hour
	mostPerSweep      = 1000
	// Between two rounds of one hour's sweep, while a round stops at mostPerSweep (#2291).
	sweepPause     = 5 * time.Second
	eventsPrefix   = "v1/events/"
	codesPrefix    = "v1/codes/"
	sweptDayLayout = "2006-01-02"
)

// Copies' change events (#3648): only for a copy that missed one, so a day is plenty.
const (
	meshEventsPrefix = "v1/mesh/events/"
	meshEventsKept   = 24 * time.Hour
)

// What a copy leaves outside v1/ when it stops part way (#3748): a start-up probe, and a
// move's check mark. A folder store deletes its probes as leftovers; a bucket has no
// time on a key, so the sweep goes by when it first saw one.
var straysPrefixes = []string{"probe/", "handover/mark-"}

// sweepReport is StoreSweep.Report.
type sweepReport struct {
	events, codes, tombstones, leftovers, dated, usage int
	// Leases of hosts that were removed, and org routes' tombstones (#2293).
	orphans int
	// Removed people cut to their tombstone (#3647).
	cut int
}

func (r sweepReport) total() int {
	return r.events + r.codes + r.tombstones + r.leftovers + r.usage + r.orphans + r.cut
}

// full says whether a sweep of at most most deletions stopped at that bound, so more may
// wait. The codes keep one deletion back (a code goes with its .spent), so most-1 is full.
func (r sweepReport) full(most int) bool { return r.total()-r.leftovers >= most-1 }

func (r sweepReport) add(o sweepReport) sweepReport {
	return sweepReport{
		events: r.events + o.events, codes: r.codes + o.codes, tombstones: r.tombstones + o.tombstones,
		leftovers: r.leftovers + o.leftovers, dated: r.dated + o.dated, usage: r.usage + o.usage,
		orphans: r.orphans + o.orphans, cut: r.cut + o.cut,
	}
}

func (r sweepReport) String() string {
	return fmt.Sprintf("removed %d events, %d code files, %d tombstones, %d leftovers, %d usage periods, %d orphans; dated %d tombstones; cut %d removed people",
		r.events, r.codes, r.tombstones, r.leftovers, r.usage, r.orphans, r.dated, r.cut)
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

	// Copies' change events, by the day in their key.
	n, err = sweepMeshEvents(ctx, s, now, left)
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
			Removed     *bool          `json:"removed"`
			RemovedAt   *records.Stamp `json:"removedAt"`
			SignIns     []any          `json:"signIns"`
		}
		if object == nil || json.Unmarshal(object.Data, &mark) != nil {
			continue
		}
		before := forgottenBefore
		if strings.HasPrefix(key, records.ProjectsPrefix) || strings.HasPrefix(key, records.GroupsPrefix) ||
			strings.HasPrefix(key, records.PeoplePrefix) {
			// A removed project (#2711), group or person (#3126): removing one always gives
			// it removedAt.
			if mark.Removed == nil || !*mark.Removed || mark.RemovedAt == nil {
				continue
			}
			if strings.HasPrefix(key, records.PeoplePrefix) {
				// A person's sign-ins stay refused while the record is kept.
				if len(mark.SignIns) > 0 {
					continue
				}
				before = now.Add(-removedPeopleKept)
			}
			mark.Forgotten, mark.ForgottenAt = mark.Removed, mark.RemovedAt
		}
		if mark.Forgotten == nil || !*mark.Forgotten {
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
		if !mark.ForgottenAt.Before(before) {
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

	// Removed providers' tombstones (#3748), as a client's.
	n, dated, err := sweepProviders(ctx, s, now, left)
	report.tombstones += n
	report.dated += dated
	left -= n
	if err != nil {
		return report, err
	}

	// Removed people kept whole from before removal cut them to a tombstone (#3647).
	n, err = sweepRemovedPeople(ctx, rs, now, left)
	report.cut = n
	left -= n
	if err != nil {
		return report, err
	}

	// What outlived what it belonged to (#2293).
	n, err = sweepOrphans(ctx, rs, now, left)
	report.orphans = n
	left -= n
	if err != nil {
		return report, err
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
	// A removed machine's cost on links (#2350), counted with them too.
	work, err := sweepLineage(ctx, s, rs, now, left-report.usage)
	report.usage += work
	if err != nil {
		return report, err
	}
	// The merged copy of lineage (#4275): old links and states, and a removed machine's.
	graph, err := sweepLineageGraph(ctx, s, rs, now, left-report.usage)
	report.usage += graph
	if err != nil {
		return report, err
	}

	if folder, ok := s.(*store.Folder); ok {
		report.leftovers = folder.RemoveLeftovers(now.Add(-leftoversKept))
	}
	// Probes and marks an hour after the sweep first saw them, on any store (#3748).
	n, err = events.sweepStrays(ctx, s, now, left-report.usage)
	report.leftovers += n
	if err != nil {
		return report, err
	}
	// The records forget the tombstones that went, and see the dated ones.
	if report.tombstones+report.dated > 0 {
		if err := rs.Load(ctx); err != nil {
			return report, err
		}
	}
	return report, nil
}

// sweepOrphans deletes, at most most, what outlived what it belonged to (#2293): the lease
// of a host that has no record, once it has run out (an expired lease fences no copy),
// a host's folder list once its record is gone from the store too (#3125), and an org
// route's tombstone, with its secret, that its removal could not delete.
func sweepOrphans(ctx context.Context, rs *records.Records, now time.Time, most int) (int, error) {
	s := rs.Store
	deleted := 0
	leases, err := s.List(ctx, leasesPrefix)
	if err != nil {
		return 0, err
	}
	for _, k := range leases {
		if deleted >= most {
			return deleted, nil
		}
		host, ok := strings.CutSuffix(strings.TrimPrefix(k.Key, leasesPrefix), ".json")
		if !ok || rs.Host(host) != nil {
			continue
		}
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return deleted, err
		}
		var lease hostLease
		if object == nil || (json.Unmarshal(object.Data, &lease) == nil && lease.Expires.After(now)) {
			continue
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return deleted, err
		}
		deleted++
	}
	folders, err := s.List(ctx, projectFoldersPrefix)
	if err != nil {
		return deleted, err
	}
	for _, k := range folders {
		if deleted >= most {
			return deleted, nil
		}
		host := joinedHost(k.Key)
		if rs.Host(host) != nil {
			continue
		}
		// A machine that joined at another copy has a record this one has not read yet,
		// and a removed one keeps its tombstone a while: either keeps its list.
		if record, err := s.Get(ctx, records.HostKey(host)); err != nil {
			return deleted, err
		} else if record != nil {
			continue
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return deleted, err
		}
		deleted++
	}
	routes, err := s.List(ctx, orgRoutesPrefix)
	if err != nil {
		return deleted, err
	}
	for _, k := range routes {
		if deleted >= most-1 {
			return deleted, nil
		}
		id, ok := strings.CutSuffix(strings.TrimPrefix(k.Key, orgRoutesPrefix), ".json")
		if !ok || strings.HasSuffix(k.Key, orgSecretSuffix) {
			continue
		}
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return deleted, err
		}
		var mark struct {
			Removed bool `json:"removed"`
		}
		if object == nil || json.Unmarshal(object.Data, &mark) != nil || !mark.Removed {
			continue
		}
		if err := s.Delete(ctx, orgSecretKey(id)); err != nil {
			return deleted, err
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return deleted, err
		}
		deleted++
	}
	return deleted, nil
}

// sweepRequests reads each request store, so the ended requests go within the hour
// (#3649), not only when someone next lists them: each list deletes what is past its
// own bound on the way (joins, lock joins and sign-ins an hour after they end, link
// requests a day after, budget requests the next day, decided governance requests after
// 30 days, and a removed person's or machine's at once), and the governance approvals of
// a person or group that is gone (#3748).
func (s *Service) sweepRequests(ctx context.Context, now time.Time) {
	failed := func(what string, err error) {
		if err != nil {
			s.log("store: " + what + " not swept: " + err.Error())
		}
	}
	_, err := s.joins.all(ctx)
	failed("joins", err)
	_, err = s.lockJoins.all(ctx)
	failed("lock joins", err)
	_, err = s.signInApprovals.all(ctx)
	failed("sign-in requests", err)
	s.links.readAgain()
	_, err = s.links.all(ctx)
	failed("link requests", err)
	_, err = s.budgetRequests(ctx, now)
	failed("budget requests", err)
	_, err = s.governanceUsage(ctx)
	failed("governance reports", err)
	_, err = s.governanceRequests(ctx, now)
	failed("governance requests", err)
	failed("governance approvals", s.sweepApprovals(ctx))
	_, err = s.removeRequests(ctx)
	failed("remove requests", err)
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
		var r records.MachineRecord
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

// eventSweep is what one sweep leaves the next. oldest is the oldest day that may still
// hold events, so a sweep lists only the days that have expired, a day each, not every
// day the audit keeps (#2053); the first sweep finds it from one list of every event.
// strays is when the sweep first saw each probe and mark (#3748), only those still there.
type eventSweep struct {
	oldest string
	strays map[string]time.Time
}

// sweepStrays deletes, at most most, the probes and move marks the sweep first saw
// leftoversKept ago or more: each lives for seconds, so one an hour old was left by a copy
// that stopped part way. A copy started again since forgets what it saw, and waits an
// hour more.
func (e *eventSweep) sweepStrays(ctx context.Context, s store.Store, now time.Time, most int) (int, error) {
	seen := map[string]time.Time{}
	deleted := 0
	for _, prefix := range straysPrefixes {
		keys, err := s.List(ctx, prefix)
		if err != nil {
			return deleted, err
		}
		for _, k := range keys {
			first, ok := e.strays[k.Key]
			if !ok {
				first = now
			}
			if deleted < most && now.Sub(first) >= leftoversKept {
				if err := s.Delete(ctx, k.Key); err != nil {
					return deleted, err
				}
				deleted++
				continue
			}
			seen[k.Key] = first
		}
	}
	e.strays = seen
	return deleted, nil
}

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

// sweepMeshEvents deletes, at most most, copies' change events from the days before
// meshEventsKept ago. They are a day or two of changes, so one list holds them.
func sweepMeshEvents(ctx context.Context, s store.Store, now time.Time, most int) (int, error) {
	cutoff := now.UTC().Add(-meshEventsKept).Format(sweptDayLayout)
	keys, err := s.List(ctx, meshEventsPrefix)
	if err != nil {
		return 0, err
	}
	deleted := 0
	for _, k := range keys {
		day, _, _ := strings.Cut(strings.TrimPrefix(k.Key, meshEventsPrefix), "/")
		if deleted >= most || day >= cutoff {
			break
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return deleted, err
		}
		deleted++
	}
	return deleted, nil
}

// sweepProviders deletes, at most most, removed machine providers' tombstones a week
// after their removal (#3748), and dates one written before forgottenAt was kept, so it
// goes a week on. It says how many it deleted, and how many it dated.
func sweepProviders(ctx context.Context, s store.Store, now time.Time, most int) (int, int, error) {
	keys, err := s.List(ctx, providers.ProvidersPrefix)
	if err != nil {
		return 0, 0, err
	}
	deleted, dated := 0, 0
	for _, k := range keys {
		if deleted >= most {
			break
		}
		object, err := s.Get(ctx, k.Key)
		if err != nil {
			return deleted, dated, err
		}
		var record providers.ProviderRecord
		if object == nil || json.Unmarshal(object.Data, &record) != nil || record.Forgotten == nil || !*record.Forgotten {
			continue
		}
		if record.ForgottenAt == nil {
			at := records.At(now)
			record.ForgottenAt, record.Rev = &at, record.Rev+1
			data, err := records.Encode(record)
			if err != nil {
				return deleted, dated, err
			}
			if _, err := s.Put(ctx, k.Key, data, store.Matching(object.ETag)); err == nil {
				dated++
			} else if !store.IsConflict(err) {
				return deleted, dated, err
			}
			continue
		}
		if !record.ForgottenAt.Before(now.Add(-tombstonesKept)) {
			continue
		}
		if err := s.Delete(ctx, k.Key); err != nil {
			return deleted, dated, err
		}
		deleted++
	}
	return deleted, dated, nil
}

// sweepRemovedPeople cuts at most most removed people to their tombstone (#3647): each was
// removed before removal did it, and still holds their name, emails and logins.
func sweepRemovedPeople(ctx context.Context, rs *records.Records, now time.Time, most int) (int, error) {
	ids := rs.RemovedToCut()
	if len(ids) == 0 || most <= 0 {
		return 0, nil
	}
	ids = ids[:min(len(ids), most)]
	cut := 0
	err := rs.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		var out []records.Person
		for _, id := range ids {
			if p, ok := all[id]; ok && p.IsRemoved() && !p.IsTombstone() {
				out = append(out, p.Tombstone(records.At(now)))
			}
		}
		cut = len(out)
		return out, nil
	})
	return cut, err
}

// sweepRounds is one hour's sweep (#2291): a round of at most most deletions, then, while a
// round stops at that bound, another after pause, until nothing more has expired, the hour
// is over, or wait says to stop. So when more expires in an hour than one round deletes
// (the audit at scale, usage of many machines), the store still comes back to its bound.
// It says what all the rounds removed, and how many there were.
func sweepRounds(ctx context.Context, rs *records.Records, now func() time.Time, most int, events *eventSweep,
	pause time.Duration, wait func(time.Duration) bool,
) (sweepReport, int, error) {
	start := now()
	var report sweepReport
	for rounds := 1; ; rounds++ {
		round, err := sweep(ctx, rs, now(), most, events)
		report = report.add(round)
		if err != nil || !round.full(most) || now().Sub(start)+pause >= sweepEvery || !wait(pause) {
			return report, rounds, err
		}
	}
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
	backupsSwept := ""
	for {
		// Only while serving: a receiving or forwarding copy leaves the store alone.
		var report sweepReport
		var err error
		if s.phase.now() == phaseServing {
			// Today's head of this copy's audit chain, sealed (#1001).
			if err := s.auditChain.Seal(context.Background(), s.cfg.Store, time.Now()); err != nil {
				s.log("audit: could not seal the chain: " + err.Error())
			}
			report, _, err = sweepRounds(context.Background(), s.records, time.Now, mostPerSweep, &events, sweepPause,
				func(pause time.Duration) bool {
					select {
					case <-s.stop:
						return false
					case <-time.After(pause):
						return s.phase.now() == phaseServing
					}
				})
			// Once a day, the backups no host of their owner prunes any more (#2293).
			if day := time.Now().UTC().Format(sweptDayLayout); err == nil && s.backups != nil && day != backupsSwept {
				if err := s.backups.pruneOrphans(context.Background()); err != nil {
					s.log("store: backups not swept: " + err.Error())
				} else {
					backupsSwept = day
				}
			}
			s.sweepRequests(context.Background(), time.Now())
			// Kept requests not sent for a week, with their attachments (#3647).
			if s.providers != nil {
				if kept := s.providers.Kept(); kept != nil {
					kept.Expire(time.Now())
				}
			}
			s.renewConnected(context.Background())
			s.forgetExpired(context.Background(), time.Now(), mostPerSweep)
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
