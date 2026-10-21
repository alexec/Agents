package controlplane

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Console ▸ Machines (#1804, M1): an admin sees every machine with its owner; a member is
// refused the Console.
func TestConsoleFleetIsEveryMachineForAnAdmin(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	var board wire.FleetBoard
	json.Unmarshal(call(t, admin, "", "console/fleet", map[string]any{}), &board)
	if len(board.Machines) != 2 {
		t.Fatalf("%+v", board)
	}
	owners := map[wire.HostID]string{}
	for _, m := range board.Machines {
		owners[m.Host.ID] = m.OwnerName
		if m.Bot || m.Host.State == "" {
			t.Fatalf("%+v", m)
		}
	}
	if owners[wire.HostID(owner.member.Host)] != "Local owner" || owners[wire.HostID(beas.member.Host)] != "Bea" {
		t.Fatalf("%v", owners)
	}

	if e := callError(t, bea.window, "", "console/fleet", map[string]any{}); !strings.Contains(e, "admin") {
		t.Fatal(e)
	}
}

// Every Console method is an admin's and names no machine (as TestEveryClientMethodChecksTheOwner
// has it for the others), and none is in the other lists.
func TestConsoleMethodsAreAdminsOnly(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	for method := range consoleMethods {
		if own[method] || workspaceMethods[method] || hostNamingMethods[method] || !p.s.methods.Handles(method) {
			t.Errorf("%s: a Console method is the Console's alone", method)
		}
		if e := callError(t, bea.window, "", method, map[string]any{}); !strings.Contains(e, "Only an admin") {
			t.Errorf("%s: %s", method, e)
		}
	}
}
