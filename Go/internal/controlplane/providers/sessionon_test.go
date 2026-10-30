package providers

import (
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// start_session on another machine (#2887): machines/startSession goes to that machine's
// own agents/start, found by its name, saying in the control plane's words which agent on
// which machine asked; a stopped workspace keeps it; another person's machine is not there.

func sessionOn(host string) map[string]any {
	return map[string]any{"host": host, "start": map[string]any{"runtimeID": "claude", "cwd": "file:///home/me/app", "prompt": "Check it",
		"attachments": []any{}, "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []any{}},
		"additionalDirectories": []any{}, "mcpServers": []any{}, "labels": []any{},
		"startedFrom": map[string]any{"machine": "a lie", "agent": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "who": "a lie"}}}
}

func TestAnAgentStartsASessionOnAnotherMachineByItsName(t *testing.T) {
	h := newHarness(t)
	made := records.NewUUID()
	h.router.mu.Lock()
	h.router.answer = func(host, method string, params json.RawMessage) *Reply { return &Reply{Result: rawOf(made)} }
	h.router.mu.Unlock()
	h.router.setOnline(devbox, true)

	listed, err := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if hosts := listed.(AgentMachines).Hosts; err != nil || len(hosts) != 2 || hosts[0].Name != "devbox" || hosts[0].State != "online" {
		t.Fatalf("%v %+v", err, listed)
	}

	out, err := h.agentCall(MethodSessionOnMachine, sessionOn("DEVBOX"))
	if err != nil || string(out.(wire.UUID)) != made {
		t.Fatalf("%v %+v", err, out)
	}
	sent := h.router.deliveries()
	if len(sent) != 1 || sent[0].host != devbox || sent[0].method != MethodAgentsStart {
		t.Fatalf("%+v", sent)
	}
	var start wire.StartRequest
	if err := json.Unmarshal(sent[0].params, &start); err != nil {
		t.Fatal(err)
	}
	if f := start.StartedFrom; f == nil || f.Machine != "other" || f.Who != "Claude (fix-login)" || f.Agent != "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" ||
		start.Cwd != "file:///home/me/app" {
		t.Fatalf("%+v", start)
	}

	// The host says no, in its own words.
	h.router.mu.Lock()
	h.router.answer = func(string, string, json.RawMessage) *Reply {
		return &Reply{Error: &Failure{Code: -32004, Message: "/home/me/app is not there any more."}}
	}
	h.router.mu.Unlock()
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Message != "/home/me/app is not there any more." {
		t.Fatalf("%v", err)
	}

	// Offline, with no workspace to start: not sent.
	h.router.setOnline(devbox, false)
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Code != CodeHostOffline {
		t.Fatalf("%v", err)
	}
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("nowhere")); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
}

func TestASessionOnAStoppedWorkspaceIsKept(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.keeper()
	_, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox"))
	if s := keptSummary(t, failureOf(err)); s.Kind != "start" {
		t.Fatalf("%+v", s)
	}
}

func TestAnAgentCannotStartASessionOnAnotherPersonsMachine(t *testing.T) {
	h := newHarness(t)
	h.providers.hooks.OwnerOf = func(host string) string {
		if host == devbox {
			return "kim"
		}
		return "lee"
	}
	h.router.setOnline(devbox, true)
	if _, err := h.agentCall(MethodSessionOnMachine, sessionOn("devbox")); failureOf(err) == nil || failureOf(err).Code != CodeNoSuchHost {
		t.Fatalf("%v", err)
	}
	listed, _ := h.agentCall(MethodWorkspacesAgent, map[string]any{})
	if hosts := listed.(AgentMachines).Hosts; len(hosts) != 1 || hosts[0].Name != "other" {
		t.Fatalf("%+v", hosts)
	}
	if len(h.router.deliveries()) != 0 {
		t.Fatal("sent")
	}
}
