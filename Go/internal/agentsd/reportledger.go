package agentsd

import (
	"context"
	"log"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// What the control plane adds up across machines (#1811): cost, tokens and time by the
// UTC hour, folder and runtime, in <root>/report-hours.json. The hours are kept 8 days,
// so a UTC day's hours are all here to add up. Each hour, and each time the uplink comes
// back, the hours that changed since they were last sent go to the control plane
// (usage/rollup) with the UTC days they fall in. The control plane keeps hours 7 days and
// days 90; this host keeps no days.
//
// UTC, not the host's own hours (usage-history.json), so that machines in other time
// zones add up into the same hour and day.
//
// The hours are kept in memory and saved at most every reportSaveAfter, after a send and
// at shutdown, not on each usage update under costMu and timeMu (#2052).

const (
	reportHoursKept = 8 * 24
	reportEvery     = time.Hour
	reportPatience  = 30 * time.Second
	// reportMostHours bounds one send: a host offline for a week sends its hours in turns.
	reportMostHours = 48
	reportSaveAfter = 30 * time.Second
)

type reportFile struct {
	// Hours is each UTC hour's rows, by reportKey.
	Hours map[string]map[string]wire.UsageRollupRow `json:"hours"`
	// Unsent is the hours that changed since the control plane last took them, each with
	// the change it was last at.
	Unsent map[string]int64 `json:"unsent,omitempty"`
	Seq    int64            `json:"seq,omitempty"`
	// EventsSeen is the last event log position counted into the hours (#2019).
	EventsSeen int64 `json:"eventsSeen,omitempty"`
}

type reportBook struct {
	reportMu   sync.Mutex
	report     *reportFile
	reportTick sync.Once
	// reportSave is the save to come of hours changed since the last one; nil when the
	// file holds them all.
	reportSave *time.Timer
	// reportClosed is set at shutdown: from then on a change is saved at once.
	reportClosed bool
	// reportSending keeps one send at a time.
	reportSending sync.Mutex
}

func (d *Daemon) reportPath() string { return filepath.Join(d.Store.Loc.Root, "report-hours.json") }

func utcHour(t time.Time) string { return t.UTC().Format("2006-01-02T15") }

// reportKey is a row's key: its folder, runtime and, for a workflow's agents, the workflow
// (#2019), and for an org account's turns its route (#999). The rows before keep their keys.
func reportKey(folder, runtime, workflow, route string) string {
	k := folder + "\t" + runtime
	if workflow != "" {
		k += "\t" + workflow
	}
	if route != "" {
		k += "\troute:" + route
	}
	return k
}

// routeTokensToday is an org account's tokens on this host since the start of today, as the
// relay counted them (#999, D12): the limit tokens of its runtime's rows for its route, in the
// UTC hours since local midnight.
func (d *Daemon) routeTokensToday(runtime, route string, at time.Time) int64 {
	y, m, day := at.Date()
	since := utcHour(time.Date(y, m, day, 0, 0, 0, 0, at.Location()))
	d.reportMu.Lock()
	defer d.reportMu.Unlock()
	var sum int64
	for hour, rows := range d.reportLocked().Hours {
		if hour < since {
			continue
		}
		for _, row := range rows {
			if row.Runtime == runtime && row.Route != nil && *row.Route == route && row.LimitTokens != nil {
				sum += *row.LimitTokens
			}
		}
	}
	return sum
}

// reportRoute is the org route of an agent's account (#999), or "".
func reportRoute(a *wire.Agent) string {
	if a == nil {
		return ""
	}
	return orgRouteOf(a.AccountID)
}

// reportWorkflow is the workflow that started an agent, or "".
func reportWorkflow(a *wire.Agent) string {
	if a == nil || a.StartedByWorkflow == nil {
		return ""
	}
	return *a.StartedByWorkflow
}

// reportFolder is an agent's folder as the reports name it: its folder's name.
func reportFolder(a *wire.Agent) string {
	if a == nil {
		return ""
	}
	f := folderPath(a)
	if f == "" || f == "/" {
		return ""
	}
	return filepath.Base(f)
}

func (d *Daemon) reportLocked() *reportFile {
	if d.report == nil {
		d.report = &reportFile{}
		readStore(d.reportPath(), d.report, "the reports start again from now")
		if d.report.Hours == nil {
			d.report.Hours = map[string]map[string]wire.UsageRollupRow{}
		}
		if d.report.Unsent == nil {
			d.report.Unsent = map[string]int64{}
		}
	}
	return d.report
}

func addRollupRow(r *wire.UsageRollupRow, o wire.UsageRollupRow) {
	if r.Cost == nil {
		r.Cost = map[string]float64{}
	}
	for c, v := range o.Cost {
		r.Cost[c] += v
	}
	r.InputTokens += o.InputTokens
	r.OutputTokens += o.OutputTokens
	// The tokens a limit counts (#998, FR-017), so the control plane adds what a machine does.
	if o.LimitTokens != nil {
		n := *o.LimitTokens
		if r.LimitTokens != nil {
			n += *r.LimitTokens
		}
		r.LimitTokens = &n
	}
	r.ThoughtTokens += o.ThoughtTokens
	r.CachedReadTokens += o.CachedReadTokens
	r.CachedWriteTokens += o.CachedWriteTokens
	r.Turns += o.Turns
	r.UnpricedTurns += o.UnpricedTurns
	r.WorkingSeconds += o.WorkingSeconds
	r.WaitingSeconds += o.WaitingSeconds
	if o.Counts != nil {
		if r.Counts == nil {
			r.Counts = &wire.ReportCounts{}
		}
		addCounts(r.Counts, *o.Counts)
	}
}

// pruneReport keeps the newest reportHoursKept hours, and only unsent hours still kept.
func pruneReport(r *reportFile, now time.Time) {
	oldest := utcHour(now.Add(-reportHoursKept * time.Hour))
	for h := range r.Hours {
		if h < oldest {
			delete(r.Hours, h)
		}
	}
	for h := range r.Unsent {
		if _, ok := r.Hours[h]; !ok {
			delete(r.Unsent, h)
		}
	}
}

// addReport adds to an agent's folder and runtime in the UTC hour at holds.
func (d *Daemon) addReport(a *wire.Agent, runtime string, at time.Time, add wire.UsageRollupRow) {
	d.reportMu.Lock()
	defer d.reportMu.Unlock()
	d.addReportLocked(reportFolder(a), runtime, reportWorkflow(a), reportRoute(a), utcHour(at), add)
	d.reportChangedLocked()
}

func (d *Daemon) addReportLocked(folder, runtime, workflow, route, hour string, add wire.UsageRollupRow) {
	r := d.reportLocked()
	if r.Hours[hour] == nil {
		r.Hours[hour] = map[string]wire.UsageRollupRow{}
	}
	k := reportKey(folder, runtime, workflow, route)
	row := r.Hours[hour][k]
	row.Folder, row.Runtime = folder, runtime
	if workflow != "" {
		row.Workflow = &workflow
	}
	if route != "" {
		row.Route = &route
	}
	addRollupRow(&row, add)
	r.Hours[hour][k] = row
	r.Seq++
	r.Unsent[hour] = r.Seq
}

// reportChangedLocked saves the hours within reportSaveAfter, or at once after shutdown.
func (d *Daemon) reportChangedLocked() {
	if d.reportClosed {
		d.saveReportLocked(time.Now())
		return
	}
	if d.reportSave == nil {
		d.reportSave = time.AfterFunc(reportSaveAfter, d.flushReport)
	}
}

// flushReport saves the hours if any changed since the last save.
func (d *Daemon) flushReport() {
	d.reportMu.Lock()
	defer d.reportMu.Unlock()
	if d.reportSave != nil {
		d.saveReportLocked(time.Now())
	}
}

// closeReport saves what is unsaved at shutdown.
func (d *Daemon) closeReport() {
	d.flushReport()
	d.reportMu.Lock()
	d.reportClosed = true
	d.reportMu.Unlock()
}

func (d *Daemon) saveReportLocked(now time.Time) {
	if d.reportSave != nil {
		d.reportSave.Stop()
		d.reportSave = nil
	}
	r := d.reportLocked()
	pruneReport(r, now)
	if err := writeStore(d.reportPath(), r); err != nil {
		log.Printf("report-hours.json: could not save: %v", err)
	}
}

// reportTime adds a turn's stretches to the hours they fell in: the agent, its tools and
// others are working; the person is waiting.
func (d *Daemon) reportTime(agent wire.UUID, runtime string, segments []timeSegment) {
	if len(segments) == 0 {
		return
	}
	a := d.Store.Agent(agent)
	folder, workflow, route := reportFolder(a), reportWorkflow(a), reportRoute(a)
	// The turn's time on the work the session is on now (#2350).
	work := wire.LineageCost{Cost: map[string]float64{}}
	for _, s := range segments {
		if s.kind == "person" {
			work.WaitingSeconds += s.end.Sub(s.start).Seconds()
		} else {
			work.WorkingSeconds += s.end.Sub(s.start).Seconds()
		}
	}
	d.bankWork(a, work)
	d.reportMu.Lock()
	defer d.reportMu.Unlock()
	for _, s := range segments {
		from := s.start
		for from.Before(s.end) {
			next := from.UTC().Truncate(time.Hour).Add(time.Hour)
			if next.After(s.end) {
				next = s.end
			}
			var add wire.UsageRollupRow
			if s.kind == "person" {
				add.WaitingSeconds = next.Sub(from).Seconds()
				// The wait counts once, in the hour it began, by its whole length (#2019).
				if from.Equal(s.start) {
					add.Counts = waitCounts(s.end.Sub(s.start))
				}
			} else {
				add.WorkingSeconds = next.Sub(from).Seconds()
			}
			d.addReportLocked(folder, runtime, workflow, route, utcHour(from), add)
			from = next
		}
	}
	d.reportChangedLocked()
}

// rows is a period's rows in a steady order.
func rows(m map[string]wire.UsageRollupRow) []wire.UsageRollupRow {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]wire.UsageRollupRow, 0, len(keys))
	for _, k := range keys {
		row := m[k]
		if row.Cost == nil {
			row.Cost = map[string]float64{}
		}
		out = append(out, row)
	}
	return out
}

// rollupLocked is what to send: the oldest unsent hours, at most reportMostHours, and
// each UTC day they fall in, added up from every hour of it this host keeps. It says the
// change each hour was at, to mark them sent.
func (d *Daemon) rollupLocked() (wire.UsageRollup, map[string]int64) {
	r := d.reportLocked()
	out := wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}}
	hours := make([]string, 0, len(r.Unsent))
	for h := range r.Unsent {
		hours = append(hours, h)
	}
	sort.Strings(hours)
	if len(hours) > reportMostHours {
		hours = hours[:reportMostHours]
	}
	sent := map[string]int64{}
	days := map[string]bool{}
	for _, h := range hours {
		sent[h] = r.Unsent[h]
		out.Hours = append(out.Hours, wire.UsageRollupPeriod{At: h, Rows: rows(r.Hours[h])})
		days[h[:10]] = true
	}
	var dayList []string
	for day := range days {
		dayList = append(dayList, day)
	}
	sort.Strings(dayList)
	// A day whose first hours are no longer kept would be sent short: the control plane
	// keeps what it had.
	whole := utcHour(time.Now().Add(-reportHoursKept * time.Hour))[:10]
	for _, day := range dayList {
		if day <= whole {
			continue
		}
		sum := map[string]wire.UsageRollupRow{}
		for h, hr := range r.Hours {
			if !strings.HasPrefix(h, day) {
				continue
			}
			for k, row := range hr {
				s := sum[k]
				s.Folder, s.Runtime, s.Workflow = row.Folder, row.Runtime, row.Workflow
				addRollupRow(&s, row)
				sum[k] = s
			}
		}
		out.Days = append(out.Days, wire.UsageRollupPeriod{At: day, Rows: rows(sum)})
	}
	return out, sent
}

// sendReport sends the unsent hours, if this host has a control plane, until none are
// left or a send fails; a failed send is tried again on the next hour or reconnection.
func (d *Daemon) sendReport() {
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	d.reportSending.Lock()
	defer d.reportSending.Unlock()
	d.countReportEvents()
	// The cost banked on links so far, so it goes with the hours it is in (#2350).
	d.lineageSettle(5 * time.Second)
	for d.ctx.Err() == nil {
		d.reportMu.Lock()
		rollup, sent := d.rollupLocked()
		d.reportMu.Unlock()
		work, workSent := d.unsentCost()
		if len(sent) == 0 && len(work) == 0 {
			return
		}
		if len(work) > 0 {
			rollup.Work = work
		}
		ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
		_, err := (*ask)(ctx, wire.CallUsageRollup.Name, rollup)
		cancel()
		if err != nil {
			log.Printf("usage/rollup: not sent, tried again within the hour: %v", err)
			return
		}
		d.reportMu.Lock()
		r := d.reportLocked()
		for h, seq := range sent {
			// An hour that changed while it was on its way is sent again.
			if r.Unsent[h] == seq {
				delete(r.Unsent, h)
			}
		}
		d.saveReportLocked(time.Now())
		d.reportMu.Unlock()
		d.costSent(workSent)
	}
}

// startReports sends what is unsent now, and starts the hourly send once.
func (d *Daemon) startReports() {
	safe.Go("usage rollup", d.sendReport)
	// What it has from a catalogue (#2019, M5), on the same clock.
	safe.Go("governance report", d.sendGovernanceReport)
	d.reportTick.Do(func() {
		safe.Go("usage rollup clock", func() {
			tick := time.NewTicker(reportEvery)
			defer tick.Stop()
			for {
				select {
				case <-d.ctx.Done():
					return
				case <-tick.C:
					d.sendReport()
					d.sendGovernanceReport()
				}
			}
		})
	})
}
