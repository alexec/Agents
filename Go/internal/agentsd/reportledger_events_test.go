package agentsd

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Outcomes and Time (#2019): sessions, the pull requests of this host's agents' branches
// and the waits for the person go into their hours, once each, beside the cost.
func TestOutcomesGoIntoTheHours(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	folder := filepath.Join(t.TempDir(), "shop")
	branch := "agents/fix-1"
	created := time.Now().Add(-2 * time.Hour)
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "fix-1", Branch: &branch}
		a.CreatedAt = wire.DateOf(created)
	})

	d.raiseAgentEvent("agent.started", a.ID, "started working.", nil)
	pr := func(name, title, branch, stamp string) {
		payload, _ := json.Marshal(map[string]any{"pr": map[string]any{"number": 1, "title": title, "branch": branch, "url": "u"},
			stamp: time.Now().UTC().Format(time.RFC3339)})
		d.raise(wire.EventDraft{Name: name, At: now(), Scope: folderScope(folder), Sentence: "github reported " + name,
			Details: map[string]string{"server": "github", "payload": string(payload), "mcp_event_id": name + title + branch}})
	}
	pr("pr.opened", "Fix it", branch, "openedAt")
	pr("pr.merged", "Fix it", branch, "mergedAt")
	pr("pr.merged", "Revert \"Fix it\"", branch, "mergedAt")
	// A person's own branch is not the agents'.
	pr("pr.merged", "Mine", "alex/mine", "mergedAt")
	t0 := time.Now()
	d.reportTime(a.ID, "claude", []timeSegment{{kind: "person", start: t0.Add(-10 * time.Minute), end: t0},
		{kind: "person", start: t0.Add(-20 * time.Second), end: t0}})

	var sent []wire.UsageRollup
	d.SetControlAsk(askControl(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		sent = append(sent, params.(wire.UsageRollup))
		return json.RawMessage(`{}`), nil
	}))
	total := func() wire.ReportCounts {
		c := *blankCounts()
		for _, h := range sent[len(sent)-1].Hours {
			for _, row := range h.Rows {
				if row.Counts != nil {
					if row.Folder != "shop" || row.Runtime != "claude" {
						t.Fatalf("%+v", row)
					}
					addCounts(&c, *row.Counts)
				}
			}
		}
		return c
	}
	d.sendReport()
	c := total()
	if c.Sessions != 1 || c.PrsOpened != 1 || c.PrsMerged != 2 || c.PrsReverted != 1 || c.Waits != 2 {
		t.Fatalf("%+v", c)
	}
	if c.WaitBuckets[0] != 1 || c.WaitBuckets[2] != 1 {
		t.Fatalf("%v", c.WaitBuckets)
	}
	if c.MergeSeconds < 2*2*3600-60 || c.MergeSeconds > 2*2*3600+60 {
		t.Fatal(c.MergeSeconds)
	}

	// Counted once: a later send counts only what is new.
	b := seeded(t, d, folder, nil)
	d.raiseAgentEvent("agent.started", b.ID, "started working.", nil)
	d.sendReport()
	if c := total(); c.Sessions != 2 || c.PrsMerged != 2 {
		t.Fatalf("%+v", c)
	}
}

// Runtimes and Workflows (#2019): a workflow's agents have rows of their own, with its runs
// and the runs that failed; any agent's failure counts.
func TestWorkflowRunsAndFailuresGoIntoTheHours(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	folder := filepath.Join(t.TempDir(), "shop")
	nightly := "nightly"
	run := seeded(t, d, folder, func(a *wire.Agent) { a.StartedByWorkflow = &nightly })
	mine := seeded(t, d, folder, nil)
	d.raise(wire.EventDraft{Name: "workflow.ran", At: now(), Scope: folderScope(folder), Sentence: "Workflow nightly started it.",
		Details: map[string]string{"workflow": nightly, "agent": string(run.ID)}})
	d.raiseAgentEvent("agent.failed", run.ID, "ended in an error.", map[string]string{"reason": "runtime_error"})
	d.raiseAgentEvent("agent.failed", mine.ID, "ended in an error.", map[string]string{"reason": "runtime_error"})
	d.bankSessionCost(run.ID, wire.Cost{Amount: 0.25, Currency: "USD"})

	var sent []wire.UsageRollup
	d.SetControlAsk(askControl(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		sent = append(sent, params.(wire.UsageRollup))
		return json.RawMessage(`{}`), nil
	}))
	d.sendReport()
	byWorkflow := map[string]wire.ReportCounts{}
	cost := map[string]float64{}
	for _, h := range sent[0].Hours {
		for _, row := range h.Rows {
			w := ""
			if row.Workflow != nil {
				w = *row.Workflow
			}
			c := byWorkflow[w]
			if row.Counts != nil {
				addCounts(&c, *row.Counts)
			}
			byWorkflow[w] = c
			cost[w] += row.Cost["USD"]
		}
	}
	if c := byWorkflow[nightly]; c.WorkflowRuns != 1 || c.WorkflowFailures != 1 || c.FailedSessions != 1 || cost[nightly] != 0.25 {
		t.Fatalf("%+v %v", byWorkflow, cost)
	}
	if c := byWorkflow[""]; c.FailedSessions != 1 || c.WorkflowFailures != 0 {
		t.Fatalf("%+v", byWorkflow)
	}
}
