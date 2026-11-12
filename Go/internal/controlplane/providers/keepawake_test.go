package providers

import (
	"testing"
	"time"
)

// A carried codespace's machine that works is kept awake by the machine that carries its
// provider, asked again each keepAwakeRenew, and let sleep when it goes idle or offline
// (#4637). A doctl workspace is never kept awake.
func TestACarriedCodespaceIsKeptAwakeWhileItsMachineWorks(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.workspaces = []MachineInfo{{ID: "fuzzy-space", Name: "fuzzy", State: "running", SSH: new("cs.fuzzy-space.main")}}
	})
	out := h.must(MethodProvidersAdd, map[string]any{"name": "Codespaces", "kind": "commands",
		"commands": map[string]any{"preset": "codespaces-api"}, "secrets": map[string]string{"GITHUB_TOKEN": "ghp_test"}})
	id := out.(ProviderSummary).ID
	h.link(string(id), devbox, "fuzzy-space")
	h.router.setOnline(devbox, true)

	h.providers.Heard(devbox, MachineStatus{Idle: true})
	if got := sshAsks(h, "keepAwake"); len(got) != 0 {
		t.Fatalf("an idle machine was kept awake: %v", got)
	}
	h.providers.Heard(devbox, MachineStatus{Idle: false, Running: []string{"a1"}})
	if !eventually(t, func() bool { return len(sshAsks(h, "keepAwake")) == 1 }) {
		t.Fatalf("asks %v", h.router.asks())
	}
	ask := sshAsks(h, "keepAwake")[0]
	if ask.Provider != id || deref(ask.Codespace) != "fuzzy-space" || ask.Destination != "cs.fuzzy-space.main" {
		t.Errorf("%+v", ask)
	}
	// Within keepAwakeRenew: not asked again; after it: asked again.
	h.providers.keepAwake(time.Now().Add(time.Minute))
	h.providers.keepAwake(time.Now().Add(keepAwakeRenew + time.Second))
	if !eventually(t, func() bool { return len(sshAsks(h, "keepAwake")) == 2 }) {
		t.Fatalf("not renewed: %v", sshAsks(h, "keepAwake"))
	}
	time.Sleep(20 * time.Millisecond)
	if got := sshAsks(h, "keepAwake"); len(got) != 2 {
		t.Fatalf("asked %d times", len(got))
	}
	// Idle: let sleep, once.
	h.providers.Heard(devbox, MachineStatus{Idle: true})
	h.providers.keepAwake(time.Now())
	if !eventually(t, func() bool { return len(sshAsks(h, "letSleep")) == 1 }) {
		t.Fatalf("asks %v", h.router.asks())
	}
	// Working again, then offline: let sleep.
	h.providers.Heard(devbox, MachineStatus{Idle: false, Running: []string{"a1"}})
	if !eventually(t, func() bool { return len(sshAsks(h, "keepAwake")) == 3 }) {
		t.Fatalf("asks %v", sshAsks(h, "keepAwake"))
	}
	h.router.setOnline(devbox, false)
	h.providers.keepAwake(time.Now())
	if !eventually(t, func() bool { return len(sshAsks(h, "letSleep")) == 2 }) {
		t.Fatalf("asks %v", sshAsks(h, "letSleep"))
	}
	time.Sleep(20 * time.Millisecond)
	if got := len(sshAsks(h, "letSleep")); got != 2 {
		t.Errorf("let sleep %d times", got)
	}
}

func TestADoctlWorkspaceIsNotKeptAwake(t *testing.T) {
	h := newHarness(t, func(o *harnessOptions) {
		o.workspaces = []MachineInfo{{ID: "ws-1", Name: "ws-1", State: "running", SSH: new("cs.ws-1.main")}}
	})
	h.link(h.add(), devbox, "ws-1")
	h.router.setOnline(devbox, true)
	h.providers.Heard(devbox, MachineStatus{Idle: false, Running: []string{"a1"}})
	h.providers.keepAwake(time.Now())
	time.Sleep(20 * time.Millisecond)
	if got := sshAsks(h, "keepAwake"); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}
