package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
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
	told, _ := json.Marshal(wire.MachineUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{}})
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

	// workflows/fire: run here, unclaimed, when the workflow is here and a server trigger of
	// it matches the server's event; an app event, or a trigger id the event does not name,
	// is not run.
	dir := folder(t, c, 1)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non:\n  - pr.merged:\n      server: ci\nruns-on: [review-bot]\n---\nLook.\n"), 0o644)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "leases.md"), []byte("---\nname: Leases\non: lease.granted\nruns-on: [review-bot]\n---\nLook.\n"), 0o644)
	approveAll(t, c, store.FolderURL(dir))
	sendFire := func(workflow, trigger string, e wire.Event) bool {
		params, _ := json.Marshal(wire.TeamTrigger{Workflow: workflow, Trigger: trigger, RunsOn: w.RunsOn, Event: &e})
		out, ok := d.Asked(wire.CallWorkflowsFire.Name, params)
		return ok && out.(wire.TeamTriggerFired).Ran
	}
	fire := func(workflow string, e wire.Event) bool { return sendFire(workflow, triggerID(fireRequest{}, &e), e) }
	if _, ok := d.Asked("nothing/here", nil); ok {
		t.Fatal("answered what it does not know")
	}
	key := mcpTrigger{event: "pr.merged", arguments: map[string]json.RawMessage{}}.subscriptionKey("ci")
	merged := wire.Event{Name: "pr.merged", Scope: folderScope("/elsewhere/" + filepath.Base(dir)), ChainDepth: 3,
		Details: map[string]string{"server": "ci", "event": "pr.merged", "subscription": key, "mcp_event_id": "e7", "payload": "{}"}}
	lease := wire.Event{Name: "lease.granted", Details: map[string]string{"resource": "build"}}
	if fire(filepath.Base(dir)+"/missing", merged) || fire("nothing", merged) || fire(filepath.Base(dir)+"/review", wire.Event{Name: "agent.finished"}) {
		t.Fatal("ran what is not here")
	}
	if fire(filepath.Base(dir)+"/leases", lease) {
		t.Fatal("ran an app event the control plane sent")
	}
	if sendFire(filepath.Base(dir)+"/review", "event:x", merged) {
		t.Fatal("ran a trigger its event does not name")
	}
	nowDue := wire.DateOf(time.Now().Truncate(15 * time.Minute))
	params, _ := json.Marshal(wire.TeamTrigger{Workflow: filepath.Base(dir) + "/review", Trigger: wire.ScheduleTriggerID(nowDue.Time()), RunsOn: w.RunsOn, DueAt: &nowDue})
	if out, _ := d.Asked(wire.CallWorkflowsFire.Name, params); out.(wire.TeamTriggerFired).Ran {
		t.Fatal("ran a schedule the workflow does not have")
	}
	if !fire(filepath.Base(dir)+"/review", merged) {
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
	dir := folder(t, c, 1)
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
	told, _ := json.Marshal(wire.MachineUser{User: "b2", Kind: "bot", Name: "other-bot", Labels: []string{}})
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

// #2027: a person's machine hears a bot's workflow's server triggers for it, with its own
// servers, only once the person approves it here (the first start's approvals do not), and
// sends each match to the control plane. Nothing of it runs here, by a trigger or by hand.
// A server's event is one trigger whatever each machine's credentials were shown of it.
func TestAPersonsMachineHearsABotsServerEventsAndOnlySendsThem(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "merged.md"), []byte("---\nname: Merged\non:\n  - pr.merged:\n      server: ci\nruns-on: [review-bot]\n---\nTidy up.\n"), 0o644)
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
	sentCount := func() int { mu.Lock(); defer mu.Unlock(); return len(sent) }
	summary := func() *wire.WorkflowSummary {
		var list []wire.WorkflowSummary
		json.Unmarshal(c.call(t, 90, "workflows/list", map[string]any{"folder": folder}), &list)
		for i := range list {
			if list[i].Workflow.WorkflowID == "merged" {
				return &list[i]
			}
		}
		return nil
	}
	key := mcpTrigger{event: "pr.merged", arguments: map[string]json.RawMessage{}}.subscriptionKey("ci")
	merged := func(id string) {
		d.raise(wire.EventDraft{Name: "pr.merged", At: now(), Scope: folderScope(dir), Sentence: "ci reported pr.merged",
			Details: map[string]string{"server": "ci", "event": "pr.merged", "subscription": key, "mcp_event_id": id, "payload": "{}"}})
	}
	// The first start approves every file as it stands, this one too; it is not listed.
	if s := summary(); s != nil {
		t.Fatalf("listed before the bot was named: %+v", s)
	}

	// Told Sam's groups have review-bot: it is listed, heard for the bot, and waits.
	told, _ := json.Marshal(wire.MachineUser{User: "u1", Kind: "person", Name: "Sam", Labels: []string{}, Bots: []string{"Review-Bot"}})
	d.toldHostUser(told)
	s := summary()
	if s == nil || s.HearsFor == nil || *s.HearsFor != "Review-Bot" || s.AwaitingApproval == nil {
		t.Fatalf("%+v", s)
	}
	if len(d.workflowsHearingServers()) != 0 {
		t.Fatal("heard before it was approved")
	}
	if changes := d.waitingWorkflowChanges(dir); len(changes) != 1 || !strings.Contains(d.workflowApproval(dir, changes[0]).Line, "for Review-Bot") {
		t.Fatalf("%+v", changes)
	}
	merged("e1")
	time.Sleep(200 * time.Millisecond)
	if n := sentCount(); n != 0 {
		t.Fatalf("sent %d before it was approved", n)
	}

	c.call(t, 91, "workflows/approve", map[string]any{"folder": folder, "workflowID": "merged", "digest": s.AwaitingApproval.Digest})
	if s := summary(); s.AwaitingApproval != nil || s.DeniedHere != nil {
		t.Fatalf("%+v", s)
	}
	if h := d.workflowsHearingServers(); len(h) != 1 || h[0].id != "merged" {
		t.Fatalf("%+v", h)
	}
	merged("e2")
	waitFor(t, "the match sent", func() bool { return sentCount() == 1 })
	mu.Lock()
	got := sent[0]
	mu.Unlock()
	if got.Workflow != filepath.Base(dir)+"/merged" || got.Event == nil || got.Event.Details["mcp_event_id"] != "e2" || got.DueAt != nil ||
		strings.Join(got.RunsOn, ",") != "review-bot" {
		t.Fatalf("%+v", got)
	}
	// Run now is refused: it runs on the bot's machines.
	if e := c.callError(t, 92, "workflows/run", map[string]any{"folder": folder, "workflowID": "merged"}); !strings.Contains(e.Message, "another computer") {
		t.Fatal(e)
	}
	time.Sleep(200 * time.Millisecond)
	for _, n := range names(d) {
		if n == "workflow.ran" || n == "workflow.refused" {
			t.Fatalf("%s here", n)
		}
	}
	d.workflowMu.Lock()
	runs := len(d.recordsLocked().Runs)
	d.workflowMu.Unlock()
	if runs != 0 || sentCount() != 1 {
		t.Fatalf("%d runs, %d sent", runs, sentCount())
	}

	// The same event, as the bot's credentials were shown it, is the same trigger.
	mine := wire.Event{Name: "pr.merged", Details: map[string]string{"server": "ci", "event": "pr.merged", "subscription": "k", "mcp_event_id": "e2", "payload": "{}"}}
	bots := wire.Event{Name: "pr.merged", Details: map[string]string{"server": "ci", "event": "pr.merged", "subscription": "other", "mcp_event_id": "e2", "payload": `{"private":true}`}}
	if triggerID(fireRequest{}, &mine) != triggerID(fireRequest{}, &bots) {
		t.Fatal("one server event is two triggers")
	}

	// Out of the bot's group: no longer listed or heard, and nothing sent.
	told, _ = json.Marshal(wire.MachineUser{User: "u1", Kind: "person", Name: "Sam", Labels: []string{}})
	d.toldHostUser(told)
	if summary() != nil || len(d.workflowsHearingServers()) != 0 {
		t.Fatal("still heard out of the group")
	}
	merged("e3")
	time.Sleep(200 * time.Millisecond)
	if n := sentCount(); n != 1 {
		t.Fatalf("sent %d", n)
	}
}

// A schedule the control plane sends runs only at a time one of the workflow's schedules
// falls due here, about now, under the trigger id its due time names.
func TestATeamScheduleRunsOnlyWhenItIsDue(t *testing.T) {
	hourly := wire.WorkflowTrigger{Schedule: &wire.WorkflowTriggerStoredSchedule{Value: wire.WorkflowSchedule{Minutes: []int64{0},
		Hours: [2]int64{0, 23}, EndMinute: 59, Days: []wire.Weekday{wire.WeekdaySun, wire.WeekdayMon, wire.WeekdayTue,
			wire.WeekdayWed, wire.WeekdayThu, wire.WeekdayFri, wire.WeekdaySat}}}}
	w := wire.Workflow{RunsOn: []string{"review-bot"}, Triggers: []wire.WorkflowTrigger{hourly}}
	now := time.Date(2026, 10, 21, 9, 10, 0, 0, time.Local)
	at := func(due time.Time, trigger string) bool {
		d := wire.DateOf(due)
		_, ok := matchTeamTrigger("/w/app", "nightly", w, wire.TeamTrigger{Workflow: "app/nightly", Trigger: trigger, DueAt: &d}, now)
		return ok
	}
	nine := time.Date(2026, 10, 21, 9, 0, 0, 0, time.Local)
	if !at(nine, wire.ScheduleTriggerID(nine)) || !at(nine.Add(-5*time.Hour), wire.ScheduleTriggerID(nine.Add(-5*time.Hour))) {
		t.Fatal("a due schedule did not run")
	}
	for name, due := range map[string]time.Time{"not due": nine.Add(-30 * time.Minute), "ahead": nine.Add(time.Hour),
		"two days ago": nine.Add(-48 * time.Hour), "off the half hour": nine.Add(-15 * time.Minute)} {
		if at(due, wire.ScheduleTriggerID(due)) {
			t.Errorf("%s: ran", name)
		}
	}
	if at(nine, "schedule:x") {
		t.Fatal("ran under another id")
	}
}
