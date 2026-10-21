package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Reports (#1811): a turn's cost, tokens and time go into its UTC hour by project and
// runtime, and the hours that changed go to the control plane with their days, once; a
// send that fails is tried again.
func TestUsageGoesToTheControlPlaneByTheHour(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	project := filepath.Join(t.TempDir(), "shop")
	a := seeded(t, d, project, nil)

	d.bankSessionCost(a.ID, wire.Cost{Amount: 0.5, Currency: "USD"})
	d.bankTurnUsage(a.ID, wire.TurnUsage{TotalTokens: 1300, InputTokens: 1000, OutputTokens: 300})
	now := time.Now()
	d.reportTime(a.ID, "claude", []timeSegment{{kind: "agent", start: now.Add(-90 * time.Second), end: now},
		{kind: "person", start: now.Add(-30 * time.Second), end: now}})

	var sent []wire.UsageRollup
	fail := true
	ask := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != wire.CallUsageRollup.Name {
			t.Fatal(method)
		}
		if fail {
			return nil, errors.New("offline")
		}
		sent = append(sent, params.(wire.UsageRollup))
		return json.RawMessage(`{}`), nil
	})
	d.SetControlAsk(ask)
	d.sendReport()
	if len(sent) != 0 || len(d.report.Unsent) == 0 {
		t.Fatalf("%v %v", sent, d.report.Unsent)
	}
	fail = false
	d.sendReport()
	if len(sent) != 1 || len(d.report.Unsent) != 0 {
		t.Fatalf("%+v %v", sent, d.report.Unsent)
	}
	r := sent[0]
	if len(r.Days) == 0 || r.Days[len(r.Days)-1].At != now.UTC().Format("2006-01-02") {
		t.Fatalf("%+v", r.Days)
	}
	var cost, working, waiting float64
	var tokens, turns int64
	for _, h := range r.Hours {
		for _, row := range h.Rows {
			if row.Project != "shop" || row.Runtime != "claude" {
				t.Fatalf("%+v", row)
			}
			cost += row.Cost["USD"]
			tokens += row.InputTokens + row.OutputTokens
			turns += row.Turns
			working += row.WorkingSeconds
			waiting += row.WaitingSeconds
		}
	}
	if cost != 0.5 || tokens != 1300 || turns != 1 || working != 90 || waiting != 30 {
		t.Fatalf("%v %v %v %v %v", cost, tokens, turns, working, waiting)
	}

	// Nothing new, nothing sent; the file keeps what was sent.
	d.sendReport()
	if len(sent) != 1 {
		t.Fatal(len(sent))
	}
	var file reportFile
	readStore(filepath.Join(root, "report-hours.json"), &file, "")
	if len(file.Hours) == 0 || len(file.Unsent) != 0 {
		t.Fatalf("%+v", file)
	}
}

// Hours older than 8 days go, and their days are not sent short.
func TestOldReportHoursGo(t *testing.T) {
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	r := &reportFile{Hours: map[string]map[string]wire.UsageRollupRow{
		utcHour(now.Add(-9 * 24 * time.Hour)): {"a\tclaude": {}},
		utcHour(now.Add(-time.Hour)):          {"a\tclaude": {}},
	}, Unsent: map[string]int64{utcHour(now.Add(-9 * 24 * time.Hour)): 1}}
	pruneReport(r, now)
	if len(r.Hours) != 1 || len(r.Unsent) != 0 {
		t.Fatalf("%+v", r)
	}
}
