package agentsd

import (
	"context"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// sessions is a fake keepAwakeSession: each session's codespace and token, and how many run.
type sessions struct {
	mu      sync.Mutex
	started []string
	running int
}

func fakeSessions(t *testing.T, lease time.Duration) *sessions {
	t.Helper()
	s := &sessions{}
	was, wasLease := keepAwakeSession, keepAwakeLease
	keepAwakeSession = func(ctx context.Context, codespace, token string) error {
		s.mu.Lock()
		s.started = append(s.started, codespace+" "+token)
		s.running++
		s.mu.Unlock()
		<-ctx.Done()
		s.mu.Lock()
		s.running--
		s.mu.Unlock()
		return nil
	}
	keepAwakeLease = lease
	t.Cleanup(func() { keepAwakeSession, keepAwakeLease = was, wasLease })
	return s
}

func (s *sessions) state() ([]string, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.started...), s.running
}

func waitUntil(t *testing.T, ok func() bool) bool {
	t.Helper()
	for start := time.Now(); time.Since(start) < 5*time.Second; time.Sleep(5 * time.Millisecond) {
		if ok() {
			return true
		}
	}
	return false
}

// keepAwake holds one session with the provider's token, however often it is asked; letSleep
// ends it (#4637).
func TestACarriedCodespaceIsKeptAwakeUntilLetSleep(t *testing.T) {
	s := fakeSessions(t, time.Hour)
	d, _ := carriedDaemon(t)
	ask(t, d, wire.CallProvidersKeepSecrets.Name, wire.ProviderSecretsKeep{Provider: "p1",
		Secrets: map[string]string{"GITHUB_TOKEN": "ghp_kept"}})
	for range 3 {
		if out := ask(t, d, wire.CallProvidersSSH.Name, wire.ProviderSSH{Provider: "p1", Op: "keepAwake",
			Destination: "cs.fuzzy.main", Codespace: new("fuzzy")}); out.Error != nil {
			t.Fatal(*out.Error)
		}
	}
	if !waitUntil(t, func() bool { _, running := s.state(); return running == 1 }) {
		t.Fatal("no session")
	}
	if started, _ := s.state(); !reflect.DeepEqual(started, []string{"fuzzy ghp_kept"}) {
		t.Fatalf("%v", started)
	}
	ask(t, d, wire.CallProvidersSSH.Name, wire.ProviderSSH{Provider: "p1", Op: "letSleep",
		Destination: "cs.fuzzy.main", Codespace: new("fuzzy")})
	if !waitUntil(t, func() bool { _, running := s.state(); return running == 0 }) {
		t.Fatal("the session still runs")
	}
	if got := d.carried().awake.holding(); len(got) != 0 {
		t.Errorf("%v", got)
	}
}

// A keepAwake that is not asked again ends with its lease, so a control plane that has gone
// keeps no codespace up; one asked again keeps its session.
func TestAKeepAwakeEndsWithItsLease(t *testing.T) {
	s := fakeSessions(t, 300*time.Millisecond)
	d, _ := carriedDaemon(t)
	ask(t, d, wire.CallProvidersKeepSecrets.Name, wire.ProviderSecretsKeep{Provider: "p1",
		Secrets: map[string]string{"GITHUB_TOKEN": "ghp_kept"}})
	keep := func() {
		ask(t, d, wire.CallProvidersSSH.Name, wire.ProviderSSH{Provider: "p1", Op: "keepAwake",
			Destination: "cs.fuzzy.main", Codespace: new("fuzzy")})
	}
	keep()
	for range 4 {
		time.Sleep(150 * time.Millisecond)
		keep()
	}
	if started, running := s.state(); len(started) != 1 || running != 1 {
		t.Fatalf("renewed: %v, %d running", started, running)
	}
	if !waitUntil(t, func() bool { _, running := s.state(); return running == 0 }) {
		t.Fatal("still running after its lease")
	}
}

// A provider forgotten here ends its sessions; one with no token here starts none.
func TestAForgottenProviderLetsItsCodespacesSleep(t *testing.T) {
	s := fakeSessions(t, time.Hour)
	d, _ := carriedDaemon(t)
	if out := ask(t, d, wire.CallProvidersSSH.Name, wire.ProviderSSH{Provider: "p1", Op: "keepAwake",
		Destination: "cs.fuzzy.main", Codespace: new("fuzzy")}); out.Error == nil {
		t.Fatal("kept awake with no token")
	}
	ask(t, d, wire.CallProvidersKeepSecrets.Name, wire.ProviderSecretsKeep{Provider: "p1",
		Secrets: map[string]string{"GITHUB_TOKEN": "ghp_kept"}})
	ask(t, d, wire.CallProvidersSSH.Name, wire.ProviderSSH{Provider: "p1", Op: "keepAwake",
		Destination: "cs.fuzzy.main", Codespace: new("fuzzy")})
	if !waitUntil(t, func() bool { _, running := s.state(); return running == 1 }) {
		t.Fatal("no session")
	}
	ask(t, d, wire.CallProvidersForget.Name, wire.ProviderForget{Provider: "p1"})
	if !waitUntil(t, func() bool { _, running := s.state(); return running == 0 }) {
		t.Fatal("the session still runs")
	}
}
