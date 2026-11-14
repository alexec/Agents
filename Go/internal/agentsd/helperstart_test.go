package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Ports HelperStartTests and HelperQueueTests: a lead starts a session in its folder; past
// the running limit the next queues, and starts by itself once a place is free.

func TestALeadStartsSessionsAndTheyQueue(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/", "rules": map[string]any{"helpers": map[string]any{"mostRunning": 1}}})
	title := "Lead"
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "  "}); !isErr || text != "Nothing was started: say what the agent is to do." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "start_session", map[string]any{"prompt": "x", "runtime": "nope"}); !isErr || !strings.HasPrefix(text, `Nothing was started: there is no runtime called "nope"`) {
		t.Fatal(text)
	}
	text, _ := m.tool(4, "start_session", map[string]any{"prompt": "wait for me", "labels": []string{"helper"}})
	if !strings.HasPrefix(text, "Started “wait for me” (id ") || !strings.HasSuffix(text, "This project now has 1 of 1 running, 1 of 5 not archived.") {
		t.Fatal(text)
	}
	first := wire.UUID(strings.Fields(text)[5][:36])
	if a := d.Store.Agent(first); a.StartedByAgent == nil || *a.StartedByAgent != lead.ID || a.Labels[0].Owner != wire.SessionLabelOwnerAgent {
		t.Fatalf("%+v", a)
	}
	waitFor(t, "the first working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	text, _ = m.tool(5, "start_session", map[string]any{"prompt": "Write it"})
	if !strings.HasPrefix(text, "Queued “Write it” (id ") || !strings.Contains(text, ", 1st in this project's queue: This project already has 1 of 1 sessions started by sessions running") {
		t.Fatal(text)
	}
	second := wire.UUID(strings.Fields(text)[4][:36])
	if a := d.Store.Agent(second); a.State != wire.AgentStateQueued {
		t.Fatalf("%+v", a)
	}
	if text, _ := m.tool(6, "list_sessions", map[string]any{"started_by": "me"}); !strings.Contains(text, string(second)+": “Write it” — queued (position 1)") ||
		!strings.Contains(text, "Runtimes you can start agents on (your own runtime, claude, if you name none): ") {
		t.Fatal(text)
	}
	// Stopping the first frees its place, and the queue moves.
	if text, _ := m.tool(7, "stop_session", map[string]any{"id": string(first)}); !strings.HasPrefix(text, "Stopped “wait for me”, freeing its running place") {
		t.Fatal(text)
	}
	waitFor(t, "the second out of the queue", func() bool { return d.Store.Agent(second).State == wire.AgentStateFinished })
	if u := userMessages(d, second); len(u) != 1 || u[0] != "Write it" {
		t.Fatalf("%q", u)
	}
}

func TestStartSessionInheritsCallerRuntimeAndMode(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	lead := seeded(t, d, dir, func(a *wire.Agent) {
		a.RuntimeID = "codex"
		cat := "mode"
		value, _ := json.Marshal("plan")
		a.AdvertisedOptions = []wire.ConfigOption{{ID: "mode", Name: "Mode", Type: "select", Category: &cat, CurrentValue: value}}
		a.StartOptions.Values["mode"] = value
	})
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "inherit"})
	if isErr {
		t.Fatal(text)
	}
	if !strings.HasPrefix(text, "Started ") {
		t.Fatal(text)
	}
	id := helperID(text)
	helper := d.Store.Agent(id)
	if helper.RuntimeID != "codex" || string(helper.StartOptions.Values["mode"]) != `"plan"` {
		t.Fatalf("%+v", helper)
	}
	text, isErr = m.tool(3, "start_session", map[string]any{"prompt": "different runtime", "runtime": "grok"})
	if isErr {
		t.Fatal(text)
	}
	id = helperID(text)
	helper = d.Store.Agent(id)
	if helper.RuntimeID != "grok" || string(helper.StartOptions.Values["mode"]) == `"plan"` {
		t.Fatalf("%+v", helper)
	}
}

func TestStartSessionInheritsCallerRuntimeWhenQueued(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/", "rules": map[string]any{"helpers": map[string]any{"mostRunning": 1}}})
	title := "Lead"
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title; a.RuntimeID = "codex" })
	startedBy := lead.ID
	seeded(t, d, dir, func(a *wire.Agent) { a.State = wire.AgentStateRunning; a.StartedByAgent = &startedBy })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "queue"})
	if isErr {
		t.Fatal(text)
	}
	queued := helperID(text)
	a := d.Store.Agent(queued)
	if a.QueuedStart == nil || a.QueuedStart.RuntimeID == nil || *a.QueuedStart.RuntimeID != "codex" {
		t.Fatalf("%+v", a.QueuedStart)
	}
}

func helperID(text string) wire.UUID {
	fields := strings.Fields(text)
	for i, field := range fields {
		if field == "(id" && i+1 < len(fields) {
			return wire.UUID(strings.Trim(fields[i+1], "),."))
		}
	}
	return ""
}

// #5441: start_session takes an effort, by the value or the name the start form shows, and
// refuses one the runtime does not offer, naming the ones it does; a queued helper keeps it.
func TestStartSessionChoosesEffort(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "codex" })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	// Nothing offered yet: the word as written, under the option Auto's table knows.
	text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "untold", "effort": "high"})
	if isErr {
		t.Fatal(text)
	}
	if v := d.Store.Agent(helperID(text)).StartOptions.Values["reasoning_effort"]; string(v) != `"high"` {
		t.Fatalf("%s", v)
	}
	cat := "thought_level"
	d.remember("codex\t/x\t", optionEntry{SavedAt: now(), Options: []wire.ConfigOption{{ID: "reasoning_effort", Name: "Reasoning effort", Type: "select", Category: &cat,
		Options: json.RawMessage(`[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"}]`)}}})
	text, isErr = m.tool(3, "start_session", map[string]any{"prompt": "quick", "effort": "Low"})
	if isErr {
		t.Fatal(text)
	}
	if v := d.Store.Agent(helperID(text)).StartOptions.Values["reasoning_effort"]; string(v) != `"low"` {
		t.Fatalf("%s", v)
	}
	if text, isErr := m.tool(4, "start_session", map[string]any{"prompt": "x", "effort": "max"}); !isErr ||
		text != "Nothing was started: Codex does not offer the effort max. It offers: low, medium, high." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "start_session", map[string]any{"prompt": "x", "runtime": "auto", "effort": "low"}); !isErr ||
		!strings.Contains(text, "on Auto the effort follows the model's level") {
		t.Fatal(text)
	}
	// A queued helper keeps the effort, and starts with it.
	c.call(t, 6, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/", "rules": map[string]any{"helpers": map[string]any{"mostRunning": 1}}})
	startedBy := lead.ID
	busy := seeded(t, d, dir, func(a *wire.Agent) { a.State = wire.AgentStateRunning; a.StartedByAgent = &startedBy })
	text, isErr = m.tool(7, "start_session", map[string]any{"prompt": "later", "effort": "medium"})
	if isErr || !strings.HasPrefix(text, "Queued ") {
		t.Fatal(text)
	}
	queued := helperID(text)
	if s := d.Store.Agent(queued).QueuedStart; s == nil || s.Effort == nil || *s.Effort != "medium" {
		t.Fatalf("%+v", s)
	}
	d.change(busy.ID, func(a *wire.Agent) { a.State = wire.AgentStateFinished })
	d.startFromQueue(dir)
	waitFor(t, "the queued helper started", func() bool { return d.Store.Agent(queued).State != wire.AgentStateQueued })
	if v := d.Store.Agent(queued).StartOptions.Values["reasoning_effort"]; string(v) != `"medium"` {
		t.Fatalf("%s", v)
	}
}
