package agentsd

import (
	"context"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// A caller's role is what it may ask for (ConnectionRole): a stranger learns only that the
// host is there, Agents Host's window reads what it counts, and neither hears what the
// host says to the windows.
func TestARoleIsWhatACallerMayAsk(t *testing.T) {
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Shutdown()
	stranger, hostApp := newConn(), newConn()
	go d.AcceptAs(stranger, RoleStranger)
	go d.AcceptAs(hostApp, RoleHostApp)
	defer close(stranger.in)
	defer close(hostApp.in)

	stranger.call(t, 1, "daemon/ping", nil)
	if e := stranger.callError(t, 2, "agents/list", map[string]any{}); e.Code != CodeNotPermitted ||
		!strings.Contains(e.Message, "agents/list is not open to this connection (stranger)") {
		t.Fatalf("%+v", e)
	}
	hostApp.call(t, 3, "agents/list", map[string]any{})
	if e := hostApp.callError(t, 4, "agents/delete", map[string]any{}); e.Code != CodeNotPermitted {
		t.Fatalf("%+v", e)
	}

	Broadcast(d, wire.NotifyProjectChanged, wire.ProjectSummary{})
	for _, c := range []*conn{stranger, hostApp} {
		select {
		case line := <-c.out:
			t.Fatalf("a notification reached a caller that does not hear them: %s", line)
		default:
		}
	}
}

func TestSignedIdentifiersAreSwiftsRoles(t *testing.T) {
	for id, want := range map[string]Role{"com.alexecollins.agents": RoleControl, "com.alexecollins.agents.bridge": RoleControl,
		"agentsd": RoleAgent, "com.alexecollins.agents.host": RoleHostApp, "com.example.other": RoleStranger, "": RoleStranger} {
		if got := RoleForSignedIdentifier(id); got != want {
			t.Fatalf("%q: %s, want %s", id, got, want)
		}
	}
	if !RoleAgent.Allows("agents/askForm") || RoleAgent.Allows("agents/delete") || !RoleStranger.Allows("git/credential") {
		t.Fatal("the agent's and the stranger's methods are not Swift's")
	}
}
