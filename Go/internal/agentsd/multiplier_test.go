package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// #3903: a PR an agent opened that merges is told to the window with the new figure and the
// PR; one no agent worked on, and a closed one, count nothing; a merged revert takes one away.
// With no control plane the figure is this machine's; with one, the control plane's.
func TestMultiplierFollowsTheMerges(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	branch := "agents/7-fix"
	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(folder)}
	})
	d.noteLineage(nil, a)
	event := func(name string, n int, branch, title string) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":` + strconv.Itoa(n) +
			`,"branch":"` + branch + `","title":"` + title + `","url":"https://github.com/alexec/Agents/pull/` + strconv.Itoa(n) + `"}}`}}
	}
	state := func(id int) wire.Multiplier {
		t.Helper()
		var m wire.Multiplier
		if err := json.Unmarshal(c.call(t, id, "multiplier/state", map[string]any{}), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	if m := state(1); m.PrsMerged != 0 || m.Multiplier != nil || m.Baseline.Source != "DX 2025" || m.FirstMergeAt != nil {
		t.Fatalf("nothing merged: %+v", m)
	}

	// A person's own PR, merged: no agent worked on it.
	d.lineageEvent(event("pr.opened", 3, "fix-by-hand", "By hand"))
	d.lineageEvent(event("pr.merged", 3, "fix-by-hand", "By hand"))
	d.lineageEvent(event("pr.opened", 9, branch, "Fix it"))
	d.lineageEvent(event("pr.merged", 9, branch, "Fix it"))
	c.until(t, "the merge told", func(m string, p json.RawMessage) bool {
		return m == "multiplier/changed" && strings.Contains(string(p), `"github:alexec/agents#9"`) &&
			strings.Contains(string(p), `"prsMerged":1`)
	})
	if m := state(2); m.PrsMerged != 1 || m.Multiplier == nil || *m.Multiplier != 0.7 || *m.EngineerHours != 29 ||
		m.FirstMergeAt == nil {
		t.Fatalf("one merged: %+v", m)
	}

	// A revert the agent opened, merged: none counted, and never below 0.
	revert := "agents/revert-9"
	b := seeded(t, d, folder, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "revert-9", Branch: &revert, Folder: store.FolderURL(folder)}
	})
	d.noteLineage(nil, b)
	d.lineageEvent(event("pr.opened", 10, revert, "Revert \\\"Fix it\\\""))
	d.lineageEvent(event("pr.merged", 10, revert, "Revert \\\"Fix it\\\""))
	c.until(t, "the revert told", func(m string, p json.RawMessage) bool {
		return m == "multiplier/changed" && strings.Contains(string(p), `"github:alexec/agents#10"`) &&
			strings.Contains(string(p), `"reverts":1`)
	})
	// The page still knows they merged before (#4250).
	if m := state(3); m.PrsMerged != 0 || m.Reverts != 1 || m.Multiplier != nil || m.FirstMergeAt == nil {
		t.Fatalf("one revert: %+v", m)
	}

	// The most at once is the time history's record (#3988), with or without a control plane.
	d.timeMu.Lock()
	d.timeLocked().Records.MostAgents = &wire.TimeRecord{Value: 9, Day: "2026-11-02"}
	d.timeMu.Unlock()

	// With a control plane: its count of the person's machines and best week in this
	// machine's zone, this machine's agents.
	var asked wire.MultiplierCountParams
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallMultiplierCount.Name {
			asked, _ = params.(wire.MultiplierCountParams)
			return json.RawMessage(`{"prsMerged":7,"reverts":0,"multiplier":5,"engineerHours":200,"agentsWorking":0,"since":0,` +
				`"bestWeek":6.4,"baseline":{"prsPerWeek":1.4,"hoursPerWeek":40,"source":"DX 2025"}}`), nil
		}
		return json.RawMessage(`{}`), nil
	}))
	if m := state(4); m.PrsMerged != 7 || *m.Multiplier != 5 || m.BestWeek == nil || *m.BestWeek != 6.4 ||
		m.MostAtOnce == nil || *m.MostAtOnce != 9 {
		t.Fatalf("the control plane's: %+v", m)
	}
	if asked.TimeZone != zoneName() || asked.PrsPerWeek == nil || *asked.PrsPerWeek != 1.4 {
		t.Fatalf("asked in zone %v with %v, want %v with 1.4", asked.TimeZone, asked.PrsPerWeek, zoneName())
	}
	// One that cannot answer: this machine's own.
	d.SetControlAsk(askControl(func(context.Context, string, any) (json.RawMessage, error) {
		return nil, errors.New("offline")
	}))
	// Its merges are an hour old: no best week before 7 days of them.
	if m := state(5); m.PrsMerged != 0 || m.Reverts != 1 || m.BestWeek != nil || m.MostAtOnce == nil {
		t.Fatalf("offline: %+v", m)
	}

	// The person's own baseline (#3991): a change is told at once, and counted with. The
	// notice goes out away from preferences/set, so it can come before the answer, which
	// c.call skips past (#4622): another client, which asks nothing, hears it.
	listener := newConn()
	go d.Accept(listener)
	t.Cleanup(func() { close(listener.in) })
	listener.call(t, 1, "daemon/ping", nil)
	c.call(t, 6, "preferences/set", map[string]any{"multiplierPRsPerWeek": 2.04, "multiplierLine": "My team: 2 a week"})
	listener.until(t, "the baseline told", func(m string, p json.RawMessage) bool {
		return m == "multiplier/changed" && strings.Contains(string(p), `"prsPerWeek":2,`) &&
			strings.Contains(string(p), `"line":"My team: 2 a week"`)
	})
	if m := state(9); m.Baseline.PrsPerWeek != 2 || m.Baseline.Line == nil || *m.Baseline.Line != "My team: 2 a week" {
		t.Fatalf("own baseline: %+v", m.Baseline)
	}
	// Reset: the default figure and line.
	c.call(t, 7, "preferences/set", map[string]any{"multiplierPRsPerWeek": nil, "multiplierLine": nil})
	if m := state(8); m.Baseline.PrsPerWeek != 1.4 || m.Baseline.Line != nil {
		t.Fatalf("reset: %+v", m.Baseline)
	}
}
