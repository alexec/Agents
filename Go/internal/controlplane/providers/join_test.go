package providers

import (
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A click on a stopped machine that never joined starts it with its provider before the
// install joins it, and says so (#4978); a running one, or none named, is left alone.
func TestStartToJoinStartsAStoppedWorkspaceFirst(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.providers.Refresh(id)
	provider, workspace, name := wire.ProviderID(id), "agents-devbox", "devbox"
	request := wire.MachineInstall{Destination: "alex@127.0.0.1 -p 2222", Name: &name, Provider: &provider, Workspace: &workspace}
	if err := h.providers.StartToJoin(request, "alex"); err != nil {
		t.Fatal(err)
	}
	if h.provider.starts != 1 {
		t.Fatalf("started %d times", h.provider.starts)
	}
	if w := h.providers.workspace(WorkspaceLink{Provider: id, Workspace: workspace}); w == nil || w.State != "running" {
		t.Fatalf("not listed running: %+v", w)
	}
	if !h.router.heard(`"step":"start"`) || !h.router.heard(`"name":"devbox"`) {
		t.Errorf("no start step said: %v", h.router.broadcasts)
	}
	// Running now: a second click starts nothing.
	if err := h.providers.StartToJoin(request, "alex"); err != nil || h.provider.starts != 1 {
		t.Errorf("%v, %d starts", err, h.provider.starts)
	}
	if err := h.providers.StartToJoin(wire.MachineInstall{Destination: "x"}, "alex"); err != nil || h.provider.starts != 1 {
		t.Errorf("%v, %d starts", err, h.provider.starts)
	}
}

// A start the provider refuses fails the join, in the provider's words (#4978).
func TestStartToJoinSaysWhyTheStartFailed(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.providers.Refresh(id)
	h.provider.set("", "The droplet is locked.", 0)
	provider, workspace := wire.ProviderID(id), "agents-devbox"
	err := h.providers.StartToJoin(wire.MachineInstall{Destination: "alex@127.0.0.1", Provider: &provider, Workspace: &workspace}, "alex")
	if err == nil || !strings.Contains(err.Error(), "The droplet is locked.") {
		t.Fatalf("%v", err)
	}
}
