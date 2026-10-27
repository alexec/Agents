package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Reports (#1811): each machine's hours and days, kept as it sends them, added up by
// person, machine, folder and runtime. An admin sees every person; a member their own.
func TestReportsAddUpWhatMachinesSend(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	now := time.Now().UTC()
	hour, day := now.Format(usageHourLayout), now.Format(usageDayLayout)
	row := func(folder string, usd float64, tokens int64) wire.UsageRollupRow {
		return wire.UsageRollupRow{Folder: folder, Runtime: "claude", Cost: map[string]float64{"USD": usd},
			InputTokens: tokens, Turns: 1, WorkingSeconds: 60}
	}
	send := func(host string, rows ...wire.UsageRollupRow) {
		t.Helper()
		r := wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: hour, Rows: rows}}, Days: []wire.UsageRollupPeriod{{At: day, Rows: rows}}}
		params, _ := json.Marshal(r)
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(owner.member.Host, row("agents", 1, 100))
	// A second send of the same hour replaces the first.
	send(owner.member.Host, row("agents", 2, 200), row("site", 0.5, 50))
	send(beas.member.Host, row("agents", 3, 300))

	var day1 wire.UsageReport
	json.Unmarshal(call(t, admin, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeDay}), &day1)
	if !day1.Admin || len(day1.Rows) != 3 {
		t.Fatalf("%+v", day1)
	}
	var total float64
	people := map[string]bool{}
	for _, r := range day1.Rows {
		total += r.Cost["USD"]
		people[r.PersonName] = true
		if r.At != hour || r.HostName == "" {
			t.Fatalf("%+v", r)
		}
	}
	if total != 5.5 || !people["Bea"] || !people["Local owner"] {
		t.Fatalf("%v %v", total, people)
	}

	var month wire.UsageReport
	json.Unmarshal(call(t, bea.window, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeMonth}), &month)
	if month.Admin || len(month.Rows) != 1 || month.Rows[0].At != day || month.Rows[0].Person != bea.id || month.Rows[0].InputTokens != 300 {
		t.Fatalf("%+v", month)
	}

	var csv wire.ReportExport
	json.Unmarshal(call(t, admin, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeWeek}), &csv)
	lines := strings.Split(strings.TrimSpace(csv.Text), "\n")
	if csv.Format != wire.ReportFormatCsv || csv.Count != 3 || len(lines) != 4 ||
		!strings.HasPrefix(lines[0], "at,person,personName,host,hostName,folder,project,projectName,runtime,costUSD,inputTokens") {
		t.Fatalf("%+v", csv)
	}
	jsonl := wire.ReportFormatJsonl
	var lined wire.ReportExport
	json.Unmarshal(call(t, admin, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeThreeMonths, Format: &jsonl}), &lined)
	var first wire.ReportRow
	if lined.Count != 3 || json.Unmarshal([]byte(strings.Split(lined.Text, "\n")[0]), &first) != nil || first.Runtime != "claude" {
		t.Fatalf("%+v", lined)
	}

	if e := callError(t, admin, "", "reports/usage", map[string]any{"range": "year"}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
}

// A machine's period that is too old is let go, a stranger is refused, and the sweep
// keeps hours 7 days and days 90.
func TestReportsAreBounded(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-1")
	now := time.Now().UTC()
	old := wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: now.Add(-8 * 24 * time.Hour).Format(usageHourLayout), Rows: []wire.UsageRollupRow{}}}, Days: []wire.UsageRollupPeriod{}}
	if err := p.s.keepRollup(context.Background(), box.member.Host, old, now); err != nil {
		t.Fatal(err)
	}
	keys, _ := p.s.cfg.Store.List(context.Background(), "v1/usage/")
	if len(keys) != 0 {
		t.Fatalf("%v", keys)
	}
	if err := p.s.keepRollup(context.Background(), "NOBODY", old, now); err == nil {
		t.Fatal("a stranger's rollup was kept")
	}
	if err := p.s.keepRollup(context.Background(), box.member.Host, wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: "yesterday"}}}, now); err == nil {
		t.Fatal("a bad hour was kept")
	}

	ctx, st := context.Background(), p.s.cfg.Store
	for _, k := range []string{
		usageKey(usageHoursPrefix, now.Add(-6*24*time.Hour).Format(usageHourLayout), "h"),
		usageKey(usageHoursPrefix, now.Add(-8*24*time.Hour).Format(usageHourLayout), "h"),
		usageKey(usageDaysPrefix, now.AddDate(0, 0, -89).Format(usageDayLayout), "h"),
		usageKey(usageDaysPrefix, now.AddDate(0, 0, -91).Format(usageDayLayout), "h"),
	} {
		st.Put(ctx, k, []byte(`{"rows":[]}`), store.Always)
	}
	if n, err := sweepUsage(ctx, st, now, 100); err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
	if n, _ := sweepUsage(ctx, st, now, 100); n != 0 {
		t.Fatal(n)
	}
}

// Outcomes and Time (#2019): what the agents did comes through with its row, and in the CSV.
func TestReportsKeepWhatTheAgentsDid(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	hour := time.Now().UTC().Format(usageHourLayout)
	counts := &wire.ReportCounts{Sessions: 2, FailedSessions: 1, PrsOpened: 1, PrsMerged: 1, MergeSeconds: 3600, Waits: 1,
		WaitBuckets: []int64{1, 0, 0, 0, 0, 0}, WorkflowRuns: 3, WorkflowFailures: 1}
	nightly := "nightly"
	rows := []wire.UsageRollupRow{{Folder: "shop", Runtime: "claude", Workflow: &nightly, Cost: map[string]float64{}, Counts: counts},
		{Folder: "site", Runtime: "codex", Cost: map[string]float64{"USD": 1}}}
	params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: hour, Rows: rows}}, Days: []wire.UsageRollupPeriod{}})
	if _, err := p.s.methods.HostSaid(owner.member.Host, "usage/rollup", params); err != nil {
		t.Fatal(err)
	}
	var got wire.UsageReport
	json.Unmarshal(call(t, admin, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeDay}), &got)
	if len(got.Rows) != 2 || got.Rows[0].Counts == nil || got.Rows[0].Counts.PrsMerged != 1 || got.Rows[1].Counts != nil ||
		got.Rows[0].Workflow == nil || *got.Rows[0].Workflow != "nightly" {
		t.Fatalf("%+v", got.Rows)
	}
	var csv wire.ReportExport
	json.Unmarshal(call(t, admin, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeDay}), &csv)
	lines := strings.Split(strings.TrimSpace(csv.Text), "\n")
	if !strings.HasSuffix(lines[0], ",workflow,sessions,failedSessions,prsOpened,prsMerged,prsReverted,mergeSeconds,waits,workflowRuns,workflowFailures,groups") ||
		!strings.HasSuffix(lines[1], ",nightly,2,1,1,1,0,3600,1,3,1,") || !strings.HasSuffix(lines[2], ",,,,,,,,,,,") {
		t.Fatalf("%v", lines)
	}
}

// #2670: each row names the project its folder is in, as its machine last reported it, so
// the same project on two machines adds up as one. A folder in no project names none, and
// so does a name two of one machine's folders in different projects share.
func TestReportRowsNameTheirProject(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	mac := p.host("MAC")
	box := p.host("BOX")
	_, admin := p.client("Owner's window")
	joinFolders(t, p, mac.member.Host, wire.JoinedFolder{Folder: "file:///Users/a/Agents/", Name: "Agents", Project: "p-agents"},
		wire.JoinedFolder{Folder: "file:///Users/a/one/site/", Name: "site", Project: "p-site"},
		wire.JoinedFolder{Folder: "file:///Users/a/two/site/", Name: "site", Project: "p-other"})
	joinFolders(t, p, box.member.Host, wire.JoinedFolder{Folder: "file:///home/a/agents/", Name: "agents", Project: "p-agents"})

	hour := time.Now().UTC().Format(usageHourLayout)
	send := func(host string, folders ...string) {
		t.Helper()
		var rows []wire.UsageRollupRow
		for _, f := range folders {
			rows = append(rows, wire.UsageRollupRow{Folder: f, Runtime: "claude", Cost: map[string]float64{"USD": 1}, Turns: 1})
		}
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{{At: hour, Rows: rows}}, Days: []wire.UsageRollupPeriod{}})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(mac.member.Host, "Agents", "site", "scratch")
	send(box.member.Host, "agents")

	var report wire.UsageReport
	json.Unmarshal(call(t, admin, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeDay}), &report)
	projects := map[string]string{}
	for _, r := range report.Rows {
		name := ""
		if r.Project != nil {
			if *r.Project != "p-agents" || r.ProjectName == nil || *r.ProjectName != "Agents" {
				t.Fatalf("%+v", r)
			}
			name = *r.ProjectName
		}
		projects[r.Folder] = name
	}
	if len(projects) != 4 || projects["Agents"] != "Agents" || projects["agents"] != "Agents" ||
		projects["site"] != "" || projects["scratch"] != "" {
		t.Fatalf("%v", projects)
	}

	var csv wire.ReportExport
	json.Unmarshal(call(t, admin, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeDay}), &csv)
	if !strings.Contains(csv.Text, ",Agents,p-agents,Agents,claude,") {
		t.Fatalf("%s", csv.Text)
	}
}
