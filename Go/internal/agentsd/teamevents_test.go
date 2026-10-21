package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Scoped events on a bot's machine (#2011, FR-035): a machine event runs where it was
// heard, unclaimed; a server's event or a schedule goes to the control plane, which sends it
// once; anything else is claimed as before; and a control plane that does not take it
// leaves the claim. A trigger the control plane sends runs here, unclaimed, when this
// machine has the workflow and its trigger matches.
func TestABotsMachineSendsTeamEventsAndKeepsItsOwn(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	told, _ := json.Marshal(wire.HostUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{}})
	d.toldHostUser(told)

	due := time.Date(2026, 10, 21, 9, 0, 0, 0, time.UTC)
	server := wire.Event{Name: "pr.opened", Details: map[string]string{"server": "github", "subscription": "s1", "mcp_event_id": "e1", "time": "a"}}
	for _, tc := range []struct {
		fr   fireRequest
		want triggerScope
	}{
		{fireRequest{event: &wire.Event{Name: "machine.disk_low"}}, scopeMachine},
		{fireRequest{event: &wire.Event{Name: "dropbox.file_added"}}, scopeMachine},
		{fireRequest{event: &server}, scopeTeam},
		{fireRequest{dueAt: &due}, scopeTeam},
		{fireRequest{event: &wire.Event{Name: "agent.finished"}}, scopeClaimed},
		{fireRequest{event: &wire.Event{Name: "lease.granted", Details: map[string]string{"server": "x"}}}, scopeClaimed},
	} {
		if got := scopeOf(tc.fr); got != tc.want {
			t.Errorf("%+v: %d, want %d", tc.fr.event, got, tc.want)
		}
	}
	// The same server event heard at another time, on another machine, is the same trigger.
	later := server
	later.Details = map[string]string{"server": "github", "subscription": "s1", "mcp_event_id": "e1", "time": "b", "missed_since": "c"}
	if triggerID(fireRequest{}, &server) != triggerID(fireRequest{}, &later) {
		t.Fatal("a server's event is two triggers")
	}

	var mu sync.Mutex
	var methods []string
	taken, failing := true, false
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallWorkflowsTrigger.Name || method == wire.CallWorkflowsClaimRun.Name {
			mu.Lock()
			methods = append(methods, method)
			mu.Unlock()
		}
		if failing {
			return nil, errors.New("method not found")
		}
		if method == wire.CallWorkflowsTrigger.Name {
			return json.Marshal(wire.TeamTriggerSent{Taken: taken})
		}
		return json.Marshal(wire.WorkflowClaimed{Won: true})
	}))
	asked := func() []string {
		mu.Lock()
		defer mu.Unlock()
		out := methods
		methods = nil
		return out
	}
	w := wire.Workflow{RunsOn: []string{"review-bot"}}
	if !d.teamFire(fireRequest{folder: "/w/app", id: "r", event: &wire.Event{Name: "machine.disk_low"}}, w) || len(asked()) != 0 {
		t.Fatal("a machine event is claimed or sent")
	}
	if d.teamFire(fireRequest{folder: "/w/app", id: "r", event: &server}, w) {
		t.Fatal("a taken trigger ran here as well")
	}
	if got := asked(); len(got) != 1 || got[0] != wire.CallWorkflowsTrigger.Name {
		t.Fatal(got)
	}
	taken = false
	if !d.teamFire(fireRequest{folder: "/w/app", id: "r", dueAt: &due}, w) {
		t.Fatal("not taken, not claimed")
	}
	if got := asked(); len(got) != 2 || got[1] != wire.CallWorkflowsClaimRun.Name {
		t.Fatal(got)
	}
	failing = true
	if d.teamFire(fireRequest{folder: "/w/app", id: "r", event: &server}, w) {
		t.Fatal("ran with no control plane to claim from")
	}
	if got := asked(); len(got) != 2 || got[1] != wire.CallWorkflowsClaimRun.Name {
		t.Fatal(got)
	}
	failing = false

	// workflows/fire: run here, unclaimed, when the workflow is here and its trigger matches.
	dir := project(t, c, 1)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non: lease.granted\nruns-on: [review-bot]\n---\nLook.\n"), 0o644)
	approveAll(t, c, store.FolderURL(dir))
	fire := func(workflow string, e wire.Event) bool {
		params, _ := json.Marshal(wire.TeamTrigger{Workflow: workflow, Trigger: "event:x", RunsOn: w.RunsOn, Event: &e})
		out, ok := d.Asked(wire.CallWorkflowsFire.Name, params)
		return ok && out.(wire.TeamTriggerFired).Ran
	}
	if _, ok := d.Asked("git/fill", nil); ok {
		t.Fatal("answered what it does not know")
	}
	other := wire.Event{Name: "lease.granted", Scope: projectScope("/elsewhere/" + filepath.Base(dir)), Details: map[string]string{"resource": "build"}}
	if fire(filepath.Base(dir)+"/missing", other) || fire("nothing", other) || fire(filepath.Base(dir)+"/review", wire.Event{Name: "agent.finished"}) {
		t.Fatal("ran what is not here")
	}
	if !fire(filepath.Base(dir)+"/review", other) {
		t.Fatal("did not run it")
	}
	waitFor(t, "the run", func() bool {
		for _, n := range names(d) {
			if n == "workflow.ran" {
				return true
			}
		}
		return false
	})
	if got := asked(); len(got) != 0 {
		t.Fatalf("a trigger the control plane sent was claimed or sent again: %v", got)
	}
	waitFor(t, "the run over", func() bool {
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		return len(d.recordsLocked().Runs) == 0
	})
}

// A person's machine sends the schedule of a bot's runs-on: workflow to the control plane,
// which starts a machine of the bot's when none is online (#2011, FR-034); it runs nothing
// of it, and a bot's machine sends none of another's.
func TestAPersonsMachineSendsABotsSchedule(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "nightly.md"), []byte("---\nname: Nightly\non:\n  - schedule:\n      at: \":00\"\nruns-on: [review-bot]\n---\nTidy up.\n"), 0o644)
	var mu sync.Mutex
	var sent []wire.TeamTrigger
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallWorkflowsTrigger.Name {
			mu.Lock()
			sent = append(sent, params.(wire.TeamTrigger))
			mu.Unlock()
		}
		return json.Marshal(wire.TeamTriggerSent{Taken: true})
	}))
	hour := time.Date(2026, 10, 21, 11, 0, 0, 0, time.Local)
	d.workflowTickOnce(hour.Add(-time.Minute))
	d.workflowTickOnce(hour.Add(30 * time.Second))
	waitFor(t, "the schedule sent", func() bool { mu.Lock(); defer mu.Unlock(); return len(sent) == 1 })
	mu.Lock()
	got := sent[0]
	mu.Unlock()
	if got.Workflow != filepath.Base(dir)+"/nightly" || got.DueAt == nil || !got.DueAt.Time().Equal(hour) || got.Trigger != "schedule:"+hour.UTC().Format(time.RFC3339) {
		t.Fatalf("%+v", got)
	}
	for _, n := range names(d) {
		if n == "workflow.ran" || n == "workflow.refused" {
			t.Fatalf("%s here", n)
		}
	}

	// A bot's machine, another bot's workflow: nothing sent.
	told, _ := json.Marshal(wire.HostUser{User: "b2", Kind: "bot", Name: "other-bot", Labels: []string{}})
	d.toldHostUser(told)
	d.workflowTickOnce(hour.Add(59 * time.Minute))
	d.workflowTickOnce(hour.Add(60*time.Minute + 30*time.Second))
	time.Sleep(200 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(sent) != 1 {
		t.Fatalf("%+v", sent)
	}
}
