package agentsd

import (
	"slices"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The host's list is what its handlers make (#1748): a capability is in it when every method
// that names it is registered, and the ones a host declares are in it.
func TestCapabilitiesAreWhatTheHostServes(t *testing.T) {
	d, _ := start(t, t.TempDir())
	list := d.Capabilities()
	for _, c := range wire.DeclaredCapabilities["host"] {
		if !slices.Contains(list, c) {
			t.Errorf("%s is declared by a host and not in its list", c)
		}
	}
	for method, c := range wire.HostCapabilities {
		if _, served := d.handlers[method]; !served && !wire.HostNotifications[method] && slices.Contains(list, c) {
			t.Errorf("%s is in the list, and %s, one of its methods, is not served", c, method)
		}
	}
	for _, c := range []string{wire.CapAgents1, wire.CapChatBranch1, wire.CapAgentsFind1} {
		if !slices.Contains(list, c) {
			t.Errorf("%s is not in the list", c)
		}
	}
	t.Setenv("AGENTS_TEST_DROP_CAPABILITIES", wire.CapChatBranch1)
	if slices.Contains(d.Capabilities(), wire.CapChatBranch1) {
		t.Error("AGENTS_TEST_DROP_CAPABILITIES did not take chat.branch/1 out")
	}
}
