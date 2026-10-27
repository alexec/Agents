package controlplane

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Reports (#1811): usage, cost and time by person, folder, machine and runtime, added up
// here from what each machine sends each hour (usage/rollup). One object per machine and
// UTC hour, under v1/usage/hours/<hour>/<host>.json, kept 7 days; and per machine and UTC
// day, under v1/usage/days/<day>/<host>.json, kept 90. A machine sends the whole of a
// period, so a send replaces the one before: only that machine writes its objects.
//
// The person is the machine's owner (#994): each machine is one user's.

const (
	usageHoursPrefix = "v1/usage/hours/"
	usageDaysPrefix  = "v1/usage/days/"
	usageHoursKept   = 7 * 24 * time.Hour
	usageDaysKept    = 90 * 24 * time.Hour
	usageHourLayout  = "2006-01-02T15"
	usageDayLayout   = "2006-01-02"
	// mostRollupRows bounds one period of one machine: folders × runtimes.
	mostRollupRows = 1000
	// mostRollupPeriods bounds one send.
	mostRollupPeriods = 200
)

// storedUsage is one machine's period as the store keeps it.
type storedUsage struct {
	Rows []wire.UsageRollupRow `json:"rows"`
	At   records.Stamp         `json:"at"`
}

func usageKey(prefix, at, host string) string {
	return prefix + at + "/" + strings.ToLower(host) + ".json"
}

// keepRollup is usage/rollup: each period checked, bounded and written over the last.
func (s *Service) keepRollup(ctx context.Context, host string, rollup wire.UsageRollup, now time.Time) error {
	if s.records.Host(host) == nil {
		return fail(noSuchHost, "No machine is called %s.", host)
	}
	if len(rollup.Hours)+len(rollup.Days) > mostRollupPeriods {
		return fail(invalidParams, "Send at most %d hours and days at a time.", mostRollupPeriods)
	}
	type period struct {
		prefix, layout string
		kept           time.Duration
		list           []wire.UsageRollupPeriod
	}
	for _, p := range []period{{usageHoursPrefix, usageHourLayout, usageHoursKept, rollup.Hours}, {usageDaysPrefix, usageDayLayout, usageDaysKept, rollup.Days}} {
		for _, at := range p.list {
			t, err := time.Parse(p.layout, at.At)
			if err != nil {
				return fail(invalidParams, "%q is not a UTC hour or day.", at.At)
			}
			// Too old to keep, or more than a day ahead of this clock: let go.
			if t.Before(now.Add(-p.kept)) || t.After(now.Add(24*time.Hour)) {
				continue
			}
			if len(at.Rows) > mostRollupRows {
				return fail(invalidParams, "At most %d folders and runtimes in one period.", mostRollupRows)
			}
			data, err := records.Encode(storedUsage{Rows: at.Rows, At: records.At(now)})
			if err != nil {
				return err
			}
			// Only this machine writes its own period.
			if _, err := s.cfg.Store.Put(ctx, usageKey(p.prefix, at.At, host), data, store.Always); err != nil {
				return err
			}
		}
	}
	return nil
}

// sweepUsage deletes hours older than 7 days and days older than 90, at most most.
func sweepUsage(ctx context.Context, s store.Store, now time.Time, most int) (int, error) {
	n := 0
	for _, p := range []struct {
		prefix string
		oldest string
	}{{usageHoursPrefix, now.Add(-usageHoursKept).UTC().Format(usageHourLayout)},
		{usageDaysPrefix, now.Add(-usageDaysKept).UTC().Format(usageDayLayout)}} {
		keys, err := s.List(ctx, p.prefix)
		if err != nil {
			return n, err
		}
		for _, k := range keys {
			if n >= most {
				return n, nil
			}
			at, _, _ := strings.Cut(strings.TrimPrefix(k.Key, p.prefix), "/")
			if at >= p.oldest {
				continue
			}
			if err := s.Delete(ctx, k.Key); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}

// reportSpan is a range's unit and its first period: D by the hour, the rest by the day.
func reportSpan(r wire.ReportRange, now time.Time) (prefix, first string, ok bool) {
	now = now.UTC()
	switch r {
	case wire.ReportRangeDay:
		return usageHoursPrefix, now.Add(-23 * time.Hour).Format(usageHourLayout), true
	case wire.ReportRangeWeek:
		return usageDaysPrefix, now.AddDate(0, 0, -6).Format(usageDayLayout), true
	case wire.ReportRangeMonth:
		return usageDaysPrefix, now.AddDate(0, 0, -29).Format(usageDayLayout), true
	case wire.ReportRangeThreeMonths:
		return usageDaysPrefix, now.AddDate(0, 0, -89).Format(usageDayLayout), true
	}
	return "", "", false
}

// report is the range's rows, oldest first, of the people keep says (reports_scope.go).
func (s *Service) report(ctx context.Context, r wire.ReportRange, keep func(person string) bool, now time.Time) ([]wire.ReportRow, error) {
	prefix, first, ok := reportSpan(r, now)
	if !ok {
		return nil, fail(invalidParams, "Say a range: day, week, month or threeMonths.")
	}
	return s.reportFrom(ctx, prefix, first, keep)
}

// monthSpentUSD is what the people keep says spent this calendar month, UTC, in US
// dollars: the budget's figure, so the page need not ask for the month's rows (#2057).
func (s *Service) monthSpentUSD(ctx context.Context, keep func(person string) bool, now time.Time) (float64, error) {
	rows, err := s.reportFrom(ctx, usageDaysPrefix, now.UTC().Format("2006-01")+"-01", keep)
	if err != nil {
		return 0, err
	}
	spent := 0.0
	for _, row := range rows {
		spent += row.Cost["USD"]
	}
	return spent, nil
}

// reportFrom is the rows under prefix from the period first on, oldest first.
func (s *Service) reportFrom(ctx context.Context, prefix, first string, keep func(person string) bool) ([]wire.ReportRow, error) {
	keys, err := s.cfg.Store.List(ctx, prefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	hosts := map[string]records.MachineRecord{}
	for _, h := range s.records.Hosts() {
		hosts[strings.ToLower(h.ID)] = h
	}
	// The keys of the range and the people kept, then their objects, read once each.
	type wanted struct {
		at     string
		person string
		host   records.MachineRecord
	}
	var read []store.Key
	var meta []wanted
	for _, k := range keys {
		at, file, _ := strings.Cut(strings.TrimPrefix(k.Key, prefix), "/")
		if at < first {
			continue
		}
		hostKey := strings.TrimSuffix(file, ".json")
		host, known := hosts[hostKey]
		if !known {
			// A machine removed since: its person is not known, so only an admin sees it.
			host = records.MachineRecord{ID: strings.ToUpper(hostKey), Name: strings.ToUpper(hostKey)}
		}
		person := ""
		if known {
			person = s.ownerOf(host.ID)
		}
		if !keep(person) {
			continue
		}
		read = append(read, k)
		meta = append(meta, wanted{at: at, person: person, host: host})
	}
	objects, err := s.storeReads.read(ctx, s.cfg.Store, prefix, keys, read)
	if err != nil {
		return nil, fail(storeUnavailable, "The reports could not be read: %v", err)
	}
	projectOf := s.reportProjects(ctx)
	out := []wire.ReportRow{}
	for i, data := range objects {
		at, person, host := meta[i].at, meta[i].person, meta[i].host
		if data == nil {
			continue
		}
		var stored storedUsage
		if json.Unmarshal(data, &stored) != nil {
			continue
		}
		// As the audit names them (actorFor).
		name := s.personName(person)
		if person != "" && person == s.localOwner() {
			name = audit.LocalOwnerName
		}
		for _, row := range stored.Rows {
			cost := row.Cost
			if cost == nil {
				cost = map[string]float64{}
			}
			out = append(out, wire.ReportRow{At: at, Person: person, PersonName: name, Host: wire.MachineRef(host.ID),
				HostName: host.Name, Folder: row.Folder, Runtime: row.Runtime, Cost: cost,
				InputTokens: row.InputTokens, OutputTokens: row.OutputTokens, ThoughtTokens: row.ThoughtTokens,
				CachedReadTokens: row.CachedReadTokens, CachedWriteTokens: row.CachedWriteTokens, Turns: row.Turns,
				UnpricedTurns: row.UnpricedTurns, WorkingSeconds: row.WorkingSeconds, WaitingSeconds: row.WaitingSeconds,
				Workflow: row.Workflow, Counts: row.Counts})
			if p := projectOf[strings.ToLower(host.ID)][row.Folder]; p != nil {
				out[len(out)-1].Project, out[len(out)-1].ProjectName = &p.ID, &p.Name
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.At != b.At {
			return a.At < b.At
		}
		if a.HostName != b.HostName {
			return a.HostName < b.HostName
		}
		if a.Folder != b.Folder {
			return a.Folder < b.Folder
		}
		return a.Runtime < b.Runtime
	})
	return out, nil
}

// reportProjects is each machine's folders' projects, by machine and folder name, as the
// machines last reported them (projects/joined, #2670): a report row names its folder by
// its name. Two folders of one name on one machine in different projects name neither.
// Nothing when the store cannot say: the rows still add up, in no project.
func (s *Service) reportProjects(ctx context.Context) map[string]map[string]*records.Project {
	joined, err := s.joinedFolders(ctx)
	if err != nil {
		return nil
	}
	out := map[string]map[string]*records.Project{}
	for host, folders := range joined {
		ids := map[string]string{}
		for _, f := range folders {
			if id, seen := ids[f.Name]; !seen {
				ids[f.Name] = f.Project
			} else if id != f.Project {
				ids[f.Name] = ""
			}
		}
		names := map[string]*records.Project{}
		for name, id := range ids {
			if p := s.records.Project(id); id != "" && p != nil {
				names[name] = p
			}
		}
		out[strings.ToLower(host)] = names
	}
	return out
}

// reportMethod answers reports/usage and reports/export for a scope (#1804), and the
// scopes and their policy. With no scope, a member sees their own machines and an admin
// every person's.
func (m *Methods) reportMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.s.actorFor(from.Client).User
	switch method {
	case "reports/scopes":
		return m.s.reportScopes(ctx, user)
	case "reports/views", "reports/saveView", "reports/deleteView":
		return m.viewMethod(ctx, method, params, user)
	case "reports/policy", "reports/setPolicy":
		if !m.s.isAdmin(user) {
			return nil, fail(notPermitted, "Only an admin can see or change the report policy.")
		}
		if method == "reports/policy" {
			return m.s.reportPolicy(ctx)
		}
		policy, err := require[wire.ReportPolicy](params, "ReportPolicy")
		if err != nil {
			return nil, err
		}
		return m.s.setReportPolicy(ctx, policy)
	}
	request, err := require[wire.ReportQuery](params, "ReportQuery")
	if err != nil {
		return nil, err
	}
	report, err := m.s.scopedReport(ctx, request.Range, request.Scope, user)
	if err != nil {
		return nil, err
	}
	if method == "reports/usage" {
		return report, nil
	}
	rows := report.Rows
	format := wire.ReportFormatCsv
	if request.Format != nil {
		format = *request.Format
	}
	switch format {
	case wire.ReportFormatCsv:
		return wire.ReportExport{Text: reportCSV(rows, report.GroupNames), Count: int64(len(rows)), Format: format}, nil
	case wire.ReportFormatJsonl:
		var b bytes.Buffer
		for _, r := range rows {
			line, err := json.Marshal(r)
			if err != nil {
				continue
			}
			b.Write(line)
			b.WriteByte('\n')
		}
		return wire.ReportExport{Text: b.String(), Count: int64(len(rows)), Format: format}, nil
	}
	return nil, fail(invalidParams, "Export as csv or jsonl.")
}

// reportCSV is the rows as CSV, with a cost column for each currency that any row has, and
// the person's groups by name, as a chargeback wants them (#1804).
func reportCSV(rows []wire.ReportRow, groupNames map[string]string) string {
	currencies := map[string]bool{}
	for _, r := range rows {
		for c := range r.Cost {
			currencies[c] = true
		}
	}
	var codes []string
	for c := range currencies {
		codes = append(codes, c)
	}
	sort.Strings(codes)
	header := []string{"at", "person", "personName", "host", "hostName", "folder", "project", "projectName", "runtime"}
	for _, c := range codes {
		header = append(header, "cost"+c)
	}
	header = append(header, "inputTokens", "outputTokens", "thoughtTokens", "cachedReadTokens",
		"cachedWriteTokens", "turns", "unpricedTurns", "workingSeconds", "waitingSeconds",
		"workflow", "sessions", "failedSessions", "prsOpened", "prsMerged", "prsReverted", "mergeSeconds", "waits",
		"workflowRuns", "workflowFailures", "groups")
	var b bytes.Buffer
	w := csv.NewWriter(&b)
	w.Write(header)
	i := func(n int64) string { return strconv.FormatInt(n, 10) }
	f := func(n float64) string { return strconv.FormatFloat(n, 'f', -1, 64) }
	for _, r := range rows {
		project, projectName := "", ""
		if r.Project != nil && r.ProjectName != nil {
			project, projectName = *r.Project, *r.ProjectName
		}
		line := []string{r.At, r.Person, r.PersonName, string(r.Host), r.HostName, r.Folder, project, projectName, r.Runtime}
		for _, c := range codes {
			line = append(line, f(r.Cost[c]))
		}
		line = append(line, i(r.InputTokens), i(r.OutputTokens), i(r.ThoughtTokens), i(r.CachedReadTokens),
			i(r.CachedWriteTokens), i(r.Turns), i(r.UnpricedTurns), f(r.WorkingSeconds), f(r.WaitingSeconds))
		// What the agents did (#2019), blank from a machine before it.
		workflow := ""
		if r.Workflow != nil {
			workflow = *r.Workflow
		}
		line = append(line, workflow)
		if c := r.Counts; c != nil {
			line = append(line, i(c.Sessions), i(c.FailedSessions), i(c.PrsOpened), i(c.PrsMerged), i(c.PrsReverted),
				f(c.MergeSeconds), i(c.Waits), i(c.WorkflowRuns), i(c.WorkflowFailures))
		} else {
			line = append(line, "", "", "", "", "", "", "", "", "")
		}
		var groups []string
		for _, id := range r.Groups {
			groups = append(groups, groupNames[id])
		}
		line = append(line, strings.Join(groups, "; "))
		w.Write(line)
	}
	w.Flush()
	return b.String()
}
