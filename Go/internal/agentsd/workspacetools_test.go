package agentsd

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Ports WorkspaceToolsTests (#1444): an agent's workspace tools go to the control plane as
// machine/machines, named for its log; off a control plane they say there are none; making
// one asks the person first, and nothing is made without their yes.

func TestAnAgentsWorkspaceTools(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "fix-login"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	if text, isErr := m.tool(2, "list_machines", map[string]any{}); !isErr || text != "This machine isn’t on a control plane, so it has no machines." {
		t.Fatal(text)
	}

	host := "devbox"
	listed := wire.AgentMachines{Providers: []wire.AgentMachinesProvider{{ID: "do", Name: "DigitalOcean", CanMake: true, CanDelete: true,
		Workspaces: []wire.AgentMachinesMachine{{ID: "w1", Name: "devbox", State: "running", Host: &host, HostState: new("online")}}}}}
	var mu sync.Mutex
	var asked []wire.MachineWorkspaceCall
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallUserSetPolicy.Name {
			// The keeper's layer, saved the first time anything reads it (#2957).
			return json.RawMessage(`{}`), nil
		}
		call := params.(wire.MachineWorkspaceCall)
		mu.Lock()
		asked = append(asked, call)
		mu.Unlock()
		if method != "machine/machines" {
			t.Errorf("method %s", method)
		}
		switch call.Method {
		case "machines/forAgent":
			b, _ := json.Marshal(listed)
			return b, nil
		case "machines/start":
			return json.RawMessage(`{"state":"online"}`), nil
		case "providers/create":
			return json.RawMessage(`{"workspace":{"id":"w2","name":"second"},"joining":true}`), nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})

	text, isErr := m.tool(3, "list_machines", map[string]any{})
	if isErr || !strings.HasPrefix(text, "DigitalOcean (provider do): can make machines (make_machine), can delete them\n  - devbox: running — host devbox, online") {
		t.Fatal(text)
	}
	if text, _ := m.tool(4, "start_machine", map[string]any{"host": "devbox"}); text != "devbox is running already." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "stop_machine", map[string]any{"host": "devbox"}); !isErr || text != "Agents can’t ask that of the control plane." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(6, "make_machine", map[string]any{"provider": "Nobody", "name": "x"}); !isErr ||
		text != "Nothing was made: no provider is called Nobody. There are DigitalOcean." {
		t.Fatal(text)
	}
	mu.Lock()
	if len(asked) == 0 || asked[0].Agent != "Claude (fix-login)" {
		t.Fatalf("%+v", asked)
	}
	mu.Unlock()

	// Making one asks the person, on the agent's card, while it works.
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(7, "make_machine", map[string]any{"provider": "do", "name": "second"})
		answered <- text
	}()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *pending[0].Message != "Claude (fix-login) wants to make a machine" ||
		*f.Properties[0].Title != "Make a new machine, second, at DigitalOcean?" {
		t.Fatalf("%+v", pending[0])
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; text != "Made second. It joins as the host second on its first boot: wait for server.online." {
		t.Fatal(text)
	}

	// With no name, the control plane names it machine-N (#3972).
	go func() { text, _ := m.tool(9, "make_machine", map[string]any{"provider": "do"}); answered <- text }()
	waitFor(t, "the nameless card", func() bool {
		json.Unmarshal(c.call(t, 5, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *f.Properties[0].Title != "Make a new machine at DigitalOcean?" {
		t.Fatalf("%+v", pending[0])
	}
	c.call(t, 6, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	<-answered
	mu.Lock()
	var creates []string
	for _, call := range asked {
		if call.Method == "providers/create" {
			creates = append(creates, string(call.Params))
		}
	}
	mu.Unlock()
	if len(creates) != 2 || creates[0] != `{"id":"do","name":"second"}` || creates[1] != `{"id":"do"}` {
		t.Fatalf("%v", creates)
	}

	go func() { text, _ := m.tool(8, "delete_machine", map[string]any{"host": "devbox"}); answered <- text }()
	waitFor(t, "the second card", func() bool {
		json.Unmarshal(c.call(t, 3, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	c.call(t, 4, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "no"}})
	if text := <-answered; text != "Nothing was deleted: the person said no, or didn’t answer." {
		t.Fatal(text)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, call := range asked {
		if call.Method == "machines/deleteMachine" {
			t.Fatal("deleted without a yes")
		}
	}
}

// A yes that comes after the card's hold (#4261): the call says the card is still open and
// nothing is made yet; the late yes makes the machine and tells the agent, and a late no
// deletes nothing.
func TestAYesAfterTheHoldStillMakesTheMachine(t *testing.T) {
	fakeRuntimes(t)
	_, left := formHolds(t)
	left() // the call must outlast its hold
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "fix-login"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	host := "devbox"
	listed := wire.AgentMachines{Providers: []wire.AgentMachinesProvider{{ID: "do", Name: "DigitalOcean", CanMake: true, CanDelete: true,
		Workspaces: []wire.AgentMachinesMachine{{ID: "w1", Name: "devbox", State: "running", Host: &host, HostState: new("online")}}}}}
	var mu sync.Mutex
	var done []string
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallUserSetPolicy.Name {
			return json.RawMessage(`{}`), nil
		}
		call := params.(wire.MachineWorkspaceCall)
		switch call.Method {
		case "machines/forAgent":
			b, _ := json.Marshal(listed)
			return b, nil
		case "providers/create":
			mu.Lock()
			done = append(done, call.Method+" "+string(call.Params))
			mu.Unlock()
			return json.RawMessage(`{"workspace":{"id":"w2","name":"second"},"joining":true}`), nil
		}
		mu.Lock()
		done = append(done, call.Method)
		mu.Unlock()
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})
	did := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(done)
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	if text, isErr := m.tool(2, "make_machine", map[string]any{"provider": "do", "name": "second"}); isErr || text != yesStillOpen {
		t.Fatal(text)
	}
	if got := did(); len(got) != 0 {
		t.Fatalf("made before the yes: %v", got)
	}
	if text, isErr := m.tool(3, "delete_machine", map[string]any{"host": "devbox"}); isErr || text != yesStillOpen {
		t.Fatal(text)
	}
	l.closeForms(false) // the turn stops; the cards stay
	l.mu.Lock()
	l.inTurn = false
	l.mu.Unlock()
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 2 {
		t.Fatalf("%+v", pending)
	}
	for i, p := range pending {
		answer := "no"
		if *p.Message == "Claude (fix-login) wants to make a machine" {
			answer = "yes"
		}
		c.call(t, 2+i, "elicitations/answer", map[string]any{"requestID": p.ID, "action": "accept", "content": map[string]any{"go": answer}})
	}
	waitFor(t, "both results in its chat", func() bool {
		said := userMessages(d, a.ID)
		return slices.Contains(said, "The person answered your card \"Claude (fix-login) wants to make a machine\". "+
			"Made second. It joins as the host second on its first boot: wait for server.online.") &&
			slices.Contains(said, "The person answered your card \"Claude (fix-login) wants to delete a machine\". "+
				"Nothing was deleted: the person said no, or didn’t answer.")
	})
	if got := did(); len(got) != 1 || got[0] != `providers/create {"id":"do","name":"second"}` {
		t.Fatalf("%v", got)
	}
}

// A make that failed says why in list_machines (#4706), not that it is no host.
func TestAFailedMakeSaysWhyInListMachines(t *testing.T) {
	listed := wire.AgentMachines{Providers: []wire.AgentMachinesProvider{{ID: "cs", Name: "GitHub Codespaces", CanMake: true,
		Workspaces: []wire.AgentMachinesMachine{
			{ID: "failed-machine-21", Name: "machine-21", State: "failed", Reason: new("GitHub said 403: Resource not accessible by integration.")},
			{ID: "c1", Name: "machine-12", State: "stopped"}}}}}
	note := workspacesNote(listed)
	if !strings.Contains(note, "  - machine-21: failed — GitHub said 403: Resource not accessible by integration.\n") {
		t.Errorf("%s", note)
	}
	if !strings.Contains(note, "  - machine-12: stopped — not a host") {
		t.Errorf("%s", note)
	}
}

// A slow list before the card (#4986): the card is held only for what is left of the hold, so
// the call ends inside the tool's limit; a second call shows the same card, not a second one;
// list_machines says the make waits; and a list slower than its patience asks nobody.
func TestASlowListLeavesTheCardTheRestOfTheHold(t *testing.T) {
	fakeRuntimes(t)
	_, left := formHolds(t)
	left()
	formHoldLimit = time.Second
	patience := cardCheckPatience
	t.Cleanup(func() { cardCheckPatience = patience })
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	title := "fix-login"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	listed := wire.AgentMachines{Providers: []wire.AgentMachinesProvider{{ID: "do", Name: "DigitalOcean", CanMake: true}}}
	var mu sync.Mutex
	slow := 700 * time.Millisecond
	d.SetControlAsk(func(ctx context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallUserSetPolicy.Name {
			return json.RawMessage(`{}`), nil
		}
		if call := params.(wire.MachineWorkspaceCall); call.Method == "machines/forAgent" {
			mu.Lock()
			wait := slow
			mu.Unlock()
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			b, _ := json.Marshal(listed)
			return b, nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()

	began := time.Now()
	if text, isErr := m.tool(2, "make_machine", map[string]any{"provider": "do", "name": "second"}); isErr || text != yesStillOpen {
		t.Fatal(text)
	}
	if took := time.Since(began); took > formHoldLimit+400*time.Millisecond {
		t.Fatalf("the call took %s: the hold did not count the list", took)
	}
	if text, isErr := m.tool(3, "make_machine", map[string]any{"provider": "do", "name": "second"}); isErr || text != yesStillOpen {
		t.Fatal(text)
	}
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 1 {
		t.Fatalf("asked %d times: %+v", len(pending), pending)
	}
	text, isErr := m.tool(4, "list_machines", map[string]any{})
	if isErr || !strings.HasSuffix(text, "\nWaiting for the person's yes, on Claude (fix-login)'s card: "+
		"Make a new machine, second, at DigitalOcean? Do not ask again.") {
		t.Fatal(text)
	}

	mu.Lock()
	slow = time.Second
	mu.Unlock()
	cardCheckPatience = 100 * time.Millisecond
	if text, isErr := m.tool(5, "make_machine", map[string]any{"provider": "do", "name": "third"}); !isErr ||
		text != "Nothing was done, and the person was not asked: the control plane did not list the machines within 100ms. Call it again." {
		t.Fatal(text)
	}
	json.Unmarshal(c.call(t, 2, "elicitations/pending", nil), &pending)
	if len(pending) != 1 {
		t.Fatalf("%+v", pending)
	}
}
