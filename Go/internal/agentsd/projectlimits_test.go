package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The helper limits count across the project (#3281): in every folder of it on this
// machine, and on the person's other machines through the control plane; a lead does not
// count, and a machine the control plane does not answer counts alone and says so.

func TestHelperLimitsCountAcrossTheProject(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	mine, clone, other := projectFolder(t, "p-agents"), projectFolder(t, "p-agents"), projectFolder(t, "p-other")
	me := seeded(t, d, mine, func(a *wire.Agent) {
		a.State, a.EndedReason, a.Title = wire.AgentStateRunning, nil, new("Plans lead")
		a.Labels = []wire.SessionLabel{{Value: "lead", Owner: wire.SessionLabelOwnerPerson, AddedAt: now()}}
	})
	helper := func(dir, title string, state wire.AgentState, labels ...string) wire.Agent {
		return seeded(t, d, dir, func(a *wire.Agent) {
			a.State, a.EndedReason, a.Title, a.StartedByAgent = state, nil, &title, &me.ID
			for _, l := range labels {
				a.Labels = append(a.Labels, wire.SessionLabel{Value: l, Owner: wire.SessionLabelOwnerAgent, AddedAt: now()})
			}
		})
	}
	helper(clone, "lane in the clone", wire.AgentStateRunning)
	// A lead started by another session does not count; another project's helper neither.
	helper(clone, "a second lead", wire.AgentStateRunning, "lead")
	helper(other, "another project's", wire.AgentStateRunning)

	// No control plane: this machine's folders of the project, and no words about it.
	if p := d.helperPlaces(mine); p != "1 of 3 running, 1 of 5 not archived" {
		t.Fatal(p)
	}
	if p := d.helperPlaces(other); p != "1 of 3 running, 1 of 5 not archived" {
		t.Fatal(p)
	}

	// On a control plane: the other machines' helpers count too.
	d.SetMember(&controllink.Membership{Host: "h-mac"})
	var mu sync.Mutex
	down, asked := false, 0
	pcLane := wire.Agent{ID: there, Title: new("lane on the pc"), RuntimeID: "claude", State: wire.AgentStateRunning, StartedByAgent: &me.ID,
		Cwd: "file:///home/me/agents"}
	pcQueued := wire.Agent{ID: "22222222-3333-4444-5555-666666666666", Title: new("queued on the pc"), RuntimeID: "claude",
		State: wire.AgentStateQueued, StartedByAgent: &me.ID, Cwd: "file:///home/me/agents"}
	pcLead := wire.Agent{ID: "33333333-4444-5555-6666-777777777777", Title: new("lead on the pc"), RuntimeID: "claude",
		State: wire.AgentStateRunning, StartedByAgent: &me.ID, Cwd: "file:///home/me/agents",
		Labels: []wire.SessionLabel{{Value: "lead", Owner: wire.SessionLabelOwnerAgent, AddedAt: now()}}}
	persons := wire.Agent{ID: "44444444-5555-6666-7777-888888888888", Title: new("the person's own"), RuntimeID: "claude",
		State: wire.AgentStateRunning, Cwd: "file:///home/me/agents"}
	d.SetControlAsk(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		call, _ := params.(wire.MachineWorkspaceCall)
		if call.Method != "machines/projectSessions" {
			return nil, &controllink.AskError{Code: -32010, Message: "Agent Loops can’t ask that of the control plane."}
		}
		mu.Lock()
		defer mu.Unlock()
		asked++
		if down {
			return nil, errors.New("the control plane is not connected")
		}
		return json.Marshal(wire.ProjectSessions{
			Sessions: []wire.ProjectSession{{Machine: "h-pc", MachineName: "pc", Session: pcLane},
				{Machine: "h-pc", MachineName: "pc", Session: pcQueued}, {Machine: "h-pc", MachineName: "pc", Session: pcLead},
				{Machine: "h-pc", MachineName: "pc", Session: persons},
				{Machine: "h-mac", MachineName: "mac", Session: *d.Store.Agent(me.ID)}},
			Unreached: []wire.ProjectMachine{{Machine: "h-laptop", MachineName: "laptop"}}})
	})
	d.countProject(mine)
	d.countProject(clone) // the same project: the count is fresh, so not asked again
	if p := d.helperPlaces(mine); p != "2 of 3 running, 2 of 5 not archived, 1 of 5 queued (laptop did not answer, so its helpers are not in it)" {
		t.Fatal(p)
	}
	if asked != 1 {
		t.Fatalf("asked %d times", asked)
	}
	if p := d.helperPlaces(other); p != "1 of 3 running, 1 of 5 not archived" {
		t.Fatal(p)
	}

	// A start past the limit queues, and says it is the project's.
	helper(mine, "lane here", wire.AgentStateRunning)
	m := appClient(t, d, me.ID)
	m.post("initialize", map[string]any{}, 1)
	text, _ := m.tool(2, "start_session", map[string]any{"prompt": "One more"})
	if !strings.HasPrefix(text, "Queued “One more” (id ") || !strings.Contains(text, ", 1st in this project's queue: This project already has 3 of 3 sessions started by sessions running") ||
		!strings.Contains(text, "“lane on the pc (on pc)”") || !strings.HasSuffix(text, "This project now has 3 of 3 running, 3 of 5 not archived, 2 of 5 queued "+
		"(laptop did not answer, so its helpers are not in it).") {
		t.Fatal(text)
	}

	// The control plane gone: this machine counts alone, and says so. The queue check
	// that queueing started first ends (#3849): run after the control plane goes, it
	// counts this machine alone, finds a place free and starts "One more".
	if !d.waitAfterTurns(10 * time.Second) {
		t.Fatal("the queue check did not end")
	}
	mu.Lock()
	down = true
	mu.Unlock()
	d.projectCounts.mu.Lock()
	delete(d.projectCounts.last, "p-agents")
	d.projectCounts.mu.Unlock()
	d.countProject(mine)
	if p := d.helperPlaces(mine); p != "2 of 3 running, 2 of 5 not archived, 1 of 5 queued (counted on this machine only: "+
		"the control plane did not answer, so the project's other machines are not in it)" {
		t.Fatal(p)
	}
}

// A folder in no project counts on its own, as before, also on a control plane.
func TestHelperLimitsOfAFolderInNoProject(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir, near := t.TempDir(), t.TempDir()
	me := seeded(t, d, dir, nil)
	seeded(t, d, near, func(a *wire.Agent) { a.State, a.EndedReason, a.StartedByAgent = wire.AgentStateRunning, nil, &me.ID })
	d.SetMember(&controllink.Membership{Host: "h-mac"})
	d.SetControlAsk(func(_ context.Context, _ string, params any) (json.RawMessage, error) {
		if call, _ := params.(wire.MachineWorkspaceCall); call.Method == "machines/projectSessions" {
			t.Error("a folder in no project asked for its project's sessions")
		}
		return nil, errors.New("no")
	})
	d.countProject(dir)
	if p := d.helperPlaces(dir); p != "0 of 3 running, 0 of 5 not archived" {
		t.Fatal(p)
	}
	if w := scopeTitle(dir); w != "This folder" {
		t.Fatal(w)
	}
}
