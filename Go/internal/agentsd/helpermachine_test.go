package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// start_session on another machine (#2887): it goes to the control plane as
// machines/startSession, only after the person's yes; list_machines names the person's
// machines; and a session started that way says who started it, from where.

func TestAnAgentStartsASessionOnAnotherMachine(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "fix-login"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	on := map[string]any{"prompt": "Check the Windows bug", "machine": "pc", "folder": "/home/me/app/"}

	if text, isErr := m.tool(2, "start_session", on); !isErr ||
		text != "Nothing was started: this machine isn’t on a control plane, so it has no other machines." {
		t.Fatal(text)
	}

	var mu sync.Mutex
	var starts []wire.MachineSessionStart
	kept := false
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call := params.(wire.MachineWorkspaceCall)
		switch call.Method {
		case "machines/forAgent":
			return json.RawMessage(`{"providers":[],"hosts":[{"name":"pc","state":"online"},{"name":"laptop","state":"offline"}]}`), nil
		case "machines/startSession":
			var s wire.MachineSessionStart
			b, _ := json.Marshal(call.Params)
			json.Unmarshal(b, &s)
			mu.Lock()
			defer mu.Unlock()
			starts = append(starts, s)
			if kept {
				return nil, &controllink.AskError{Code: wire.FailureKept, Message: "pc is starting. This is sent when it connects."}
			}
			return json.RawMessage(`"11111111-2222-3333-4444-555555555555"`), nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})

	if text, _ := m.tool(3, "list_machines", map[string]any{}); !strings.HasSuffix(text,
		"The person's machines, where start_session with machine and folder starts a session once the person says yes:\n  - pc: online\n  - laptop: offline") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "start_session", map[string]any{"prompt": "x", "machine": "pc"}); !isErr ||
		text != "Nothing was started: say which folder on pc, as an absolute path." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "start_session", map[string]any{"prompt": "x", "machine": "pc", "folder": "app"}); !isErr ||
		!strings.HasPrefix(text, "Nothing was started: the folder on pc is an absolute path") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(6, "start_session", map[string]any{"prompt": "x", "machine": "pc", "folder": "/a", "permission_mode": "bypassPermissions"}); !isErr ||
		!strings.HasPrefix(text, "Nothing was started: bypassPermissions would let it do more without asking than you may") {
		t.Fatal(text)
	}

	// The person is asked, on the agent's card, and says no: nothing goes.
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	ask := func(n int, args map[string]any) {
		go func() { text, _ := m.tool(n, "start_session", args); answered <- text }()
	}
	var pending []wire.ElicitationRequest
	card := func(n int) {
		t.Helper()
		waitFor(t, "the card", func() bool {
			json.Unmarshal(c.call(t, n, "elicitations/pending", nil), &pending)
			return len(pending) == 1
		})
	}
	ask(7, on)
	card(1)
	if f := pending[0].Mode.Form.Value; *pending[0].Message != "Claude (fix-login) wants to start a session on pc" ||
		*f.Properties[0].Title != "Start a session on pc, in /home/me/app, to “Check the Windows bug”?" {
		t.Fatalf("%+v", pending[0])
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "no"}})
	if text := <-answered; text != "Nothing was started: the person said no, or didn’t answer." {
		t.Fatal(text)
	}
	mu.Lock()
	if len(starts) != 0 {
		t.Fatal("started without a yes")
	}
	mu.Unlock()

	// A yes: the start goes to the control plane, for the machine and folder it named.
	with := map[string]any{"worktree": "new"}
	for k, v := range on {
		with[k] = v
	}
	ask(8, with)
	card(3)
	c.call(t, 4, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; text != "Started “Check the Windows bug” on pc, in /home/me/app (id 11111111-2222-3333-4444-555555555555). "+
		"list_sessions, read_session, message_session, wait_for_agents, stop_session and archive_session reach it by its id, "+
		"and it counts in this folder's limits until it is archived; the person sees it under pc. This folder now has 1 of 3 running, 1 of 5 not archived." {
		t.Fatal(text)
	}
	mu.Lock()
	s := starts[0]
	mu.Unlock()
	if s.Host != "pc" || s.Start.Cwd != "file:///home/me/app" || s.Start.RuntimeID != "claude" || s.Start.Prompt != "Check the Windows bug" ||
		s.Start.StartedFrom == nil || s.Start.StartedFrom.Agent != a.ID || s.Start.Worktree == nil || s.Start.Worktree.New == nil {
		t.Fatalf("%+v", s)
	}

	// A stopped machine is started, and the start is kept for it.
	mu.Lock()
	kept = true
	mu.Unlock()
	ask(9, on)
	card(5)
	c.call(t, 6, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; !strings.HasPrefix(text, "pc is starting: the session starts in /home/me/app when it connects.") {
		t.Fatal(text)
	}
}

func TestASessionStartedFromAnotherMachineSaysWho(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	var id wire.UUID
	json.Unmarshal(c.call(t, 2, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + dir, "prompt": "Check the Windows bug",
		"labels": []string{"windows"}, "startedFrom": map[string]any{"machine": "Alex's Mac", "agent": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
			"who": "Claude (fix-login)"}}), &id)
	a := d.Store.Agent(id)
	if a == nil || a.StartedByAgent != nil || len(a.Labels) != 1 || a.Labels[0].Owner != wire.SessionLabelOwnerAgent {
		t.Fatalf("%+v", a)
	}
	if n := notes(d, id); len(n) == 0 || n[0] != "Claude (fix-login) on Alex's Mac started this session with start_session." {
		t.Fatalf("%q", n)
	}
}

// With the folder's switch on (#2928), start_session on another machine asks no one; off
// again, it is kept as no choice at all.
func TestTheFolderSwitchStartsOnAnotherMachineWithoutAsking(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	a := seeded(t, d, dir, func(a *wire.Agent) { a.State, a.EndedReason, a.RuntimeID = wire.AgentStateRunning, nil, "claude" })
	var mu sync.Mutex
	starts := 0
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if call, ok := params.(wire.MachineWorkspaceCall); ok && call.Method == "machines/startSession" {
			mu.Lock()
			starts++
			mu.Unlock()
			return json.RawMessage(`"11111111-2222-3333-4444-555555555555"`), nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})
	c.call(t, 2, "folders/setHelperLimits", map[string]any{"folder": "file://" + dir + "/", "limits": map[string]any{"agentsMayStartOnMachines": true}})
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json")); !strings.Contains(string(b), `"agentsMayStartOnMachines" : true`) {
		t.Fatalf("%s", b)
	}

	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	// Not in a turn, so no card could be asked: only the switch lets it through.
	if text, isErr := m.tool(2, "start_session", map[string]any{"prompt": "Check the Windows bug", "machine": "pc", "folder": "/home/me/app"}); isErr ||
		!strings.HasPrefix(text, "Started “Check the Windows bug” on pc, in /home/me/app (id 11111111-2222-3333-4444-555555555555).") {
		t.Fatal(text)
	}
	mu.Lock()
	if starts != 1 {
		t.Fatalf("%d starts", starts)
	}
	mu.Unlock()
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 3, "elicitations/pending", nil), &pending)
	if len(pending) != 0 {
		t.Fatalf("asked anyway: %+v", pending)
	}

	c.call(t, 4, "folders/setHelperLimits", map[string]any{"folder": "file://" + dir + "/", "limits": map[string]any{"agentsMayStartOnMachines": false}})
	if b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json")); strings.Contains(string(b), "agentsMayStartOnMachines") {
		t.Fatalf("off is kept as a choice: %s", b)
	}
	// Off, it asks again: out of a turn, that cannot be done, so nothing goes.
	if text, isErr := m.tool(5, "start_session", map[string]any{"prompt": "x", "machine": "pc", "folder": "/a"}); !isErr ||
		text != "A question can only be asked while this agent is working." {
		t.Fatal(text)
	}
	mu.Lock()
	if starts != 1 {
		t.Fatalf("%d starts", starts)
	}
	mu.Unlock()
}
