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
	project := filepath.Join(t.TempDir(), "shop")
	branch := "agents/fix-1"
	created := time.Now().Add(-2 * time.Hour)
	a := seeded(t, d, project, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "fix-1", Branch: &branch}
		a.CreatedAt = wire.DateOf(created)
	})

	d.raiseAgentEvent("agent.started", a.ID, "started working.", nil)
	pr := func(name, title, branch, stamp string) {
		payload, _ := json.Marshal(map[string]any{"pr": map[string]any{"number": 1, "title": title, "branch": branch, "url": "u"},
			stamp: time.Now().UTC().Format(time.RFC3339)})
		d.raise(wire.EventDraft{Name: name, At: now(), Scope: projectScope(project), Sentence: "github reported " + name,
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
					if row.Project != "shop" || row.Runtime != "claude" {
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
	b := seeded(t, d, project, nil)
	d.raiseAgentEvent("agent.started", b.ID, "started working.", nil)
	d.sendReport()
	if c := total(); c.Sessions != 2 || c.PrsMerged != 2 {
		t.Fatalf("%+v", c)
	}
}
