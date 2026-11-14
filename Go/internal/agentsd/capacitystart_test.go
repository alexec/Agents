package agentsd

import (
	"context"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// While the machine is near capacity an agent's start queues with the reason, though a place
// is free; a person's start goes through; the queue starts it once the level is ok (#4580).
func TestAHelperStartWaitsWhileTheMachineIsNear(t *testing.T) {
	fakeRuntimes(t)
	set := fakeCapacity(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	ctx := context.Background()
	dir := folder(t, c, 1)
	title := "Lead"
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = &title })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)

	set(capacitySample{load1: 2.4})
	d.checkCapacity(ctx)
	text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "Write it"})
	busy := sentenceMachine() + " is near capacity (load 2.4 per core). It starts by itself, oldest first, once the machine has room and this project has a place free."
	if isErr || !strings.HasPrefix(text, "Queued “Write it” (id ") || !strings.Contains(text, "1st in this project's queue: "+busy) {
		t.Fatal(text)
	}
	queued := helperID(text)
	if a := d.Store.Agent(queued); a.State != wire.AgentStateQueued {
		t.Fatalf("%+v", a)
	}
	if n := runtimeNotes(d, queued); len(n) != 1 || n[0] != "Queued by “Lead”: "+thisMachine()+" is near capacity (load 2.4 per core). "+
		"It starts by itself when the machine has room and this project has a place free." {
		t.Fatalf("%q", n)
	}
	// A person is never refused.
	mine := startAgent(t, c, 3, dir, "mine")
	waitFor(t, "the person's start", func() bool { a := d.Store.Agent(mine); return a != nil && a.State != wire.AgentStateQueued })

	// One look under the line keeps it near, and the queue held; the second brings it to ok.
	set(capacitySample{load1: 0.4})
	d.checkCapacity(ctx)
	if d.Store.Agent(queued).State != wire.AgentStateQueued {
		t.Fatal("started while still near")
	}
	if words := d.capacityHold(); words != thisMachine()+" is near capacity (load 0.4 per core, coming down)" {
		t.Fatal(words)
	}
	d.checkCapacity(ctx)
	waitFor(t, "the queue to move", func() bool { return d.Store.Agent(queued).State == wire.AgentStateFinished })
}

// While the machine is ok the queue starts one helper a look above the running limit, up to
// the total (#4580).
func TestTheQueueStartsAboveTheRunningLimitOneALookWhileOK(t *testing.T) {
	fakeRuntimes(t)
	fakeCapacity(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	ctx := context.Background()
	dir := folder(t, c, 1)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": "file://" + dir + "/", "rules": map[string]any{"helpers": map[string]any{"mostRunning": 1}}})
	lead := seeded(t, d, dir, nil)
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	first := helperID(m.mustTool(t, 3, "start_session", map[string]any{"prompt": "wait for me"}))
	waitFor(t, "the first working", func() bool { return d.Store.Agent(first).State == wire.AgentStateRunning })
	var queued []wire.UUID
	for i := range 2 {
		text := m.mustTool(t, 4+i, "start_session", map[string]any{"prompt": "wait for me"})
		if !strings.HasPrefix(text, "Queued ") {
			t.Fatal(text)
		}
		queued = append(queued, helperID(text))
	}
	d.checkCapacity(ctx)
	waitFor(t, "one above the limit", func() bool { return d.Store.Agent(queued[0]).State == wire.AgentStateRunning })
	if s := d.Store.Agent(queued[1]).State; s != wire.AgentStateQueued {
		t.Fatalf("two in one look: %s", s)
	}
	d.checkCapacity(ctx)
	waitFor(t, "the next look's", func() bool { return d.Store.Agent(queued[1]).State == wire.AgentStateRunning })
}

func (m *mcpClient) mustTool(t *testing.T, id int, name string, args map[string]any) string {
	t.Helper()
	text, isErr := m.tool(id, name, args)
	if isErr {
		t.Fatal(text)
	}
	return text
}
