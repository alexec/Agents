package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Ports WorkspaceToolsTests (#1444): an agent's workspace tools go to the control plane as
// host/workspaces, named for its log; off a control plane they say there are none; making
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

	if text, isErr := m.tool(2, "list_workspaces", map[string]any{}); !isErr || text != "This machine isn’t on a control plane, so it has no workspaces." {
		t.Fatal(text)
	}

	host := "devbox"
	listed := wire.AgentWorkspaces{Providers: []wire.AgentWorkspacesProvider{{ID: "do", Name: "DigitalOcean", CanMake: true, CanDelete: true,
		Workspaces: []wire.AgentWorkspacesWorkspace{{ID: "w1", Name: "devbox", State: "running", Host: &host, HostState: new("online")}}}}}
	var mu sync.Mutex
	var asked []wire.HostWorkspaceCall
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call := params.(wire.HostWorkspaceCall)
		mu.Lock()
		asked = append(asked, call)
		mu.Unlock()
		if method != "host/workspaces" {
			t.Errorf("method %s", method)
		}
		switch call.Method {
		case "workspaces/forAgent":
			b, _ := json.Marshal(listed)
			return b, nil
		case "hosts/start":
			return json.RawMessage(`{"state":"online"}`), nil
		case "providers/create":
			return json.RawMessage(`{"workspace":{"id":"w2","name":"second"},"joining":true}`), nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})

	text, isErr := m.tool(3, "list_workspaces", map[string]any{})
	if isErr || !strings.HasPrefix(text, "DigitalOcean (provider do): can make workspaces (make_workspace), can delete them\n  - devbox: running — host devbox, online") {
		t.Fatal(text)
	}
	if text, _ := m.tool(4, "start_workspace", map[string]any{"host": "devbox"}); text != "devbox is running already." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "stop_workspace", map[string]any{"host": "devbox"}); !isErr || text != "Agents can’t ask that of the control plane." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(6, "make_workspace", map[string]any{"provider": "Nobody", "name": "x"}); !isErr ||
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
	go func() { text, _ := m.tool(7, "make_workspace", map[string]any{"provider": "do", "name": "second"}); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *pending[0].Message != "Claude (fix-login) wants to make a workspace" ||
		*f.Properties[0].Title != "Make a new workspace, second, at DigitalOcean?" {
		t.Fatalf("%+v", pending[0])
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; text != "Made second. It joins as the host second on its first boot: wait for server.online." {
		t.Fatal(text)
	}

	go func() { text, _ := m.tool(8, "delete_workspace", map[string]any{"host": "devbox"}); answered <- text }()
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
		if call.Method == "hosts/deleteWorkspace" {
			t.Fatal("deleted without a yes")
		}
	}
}
