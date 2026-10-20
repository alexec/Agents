package controlplane

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// control.openrpc.json has every method the control plane answers for a client itself, so
// its list, made from that document, is true (#1748).
func TestControlPlaneAnswersItsDocument(t *testing.T) {
	for method := range own {
		// daemon/ping is the home host's, and devices/* the older names of clients/*.
		if _, ok := wire.ControlCapabilities[method]; !ok && method != "daemon/ping" && !strings.HasPrefix(method, "devices/") {
			t.Errorf("%s is answered and not in control.openrpc.json", method)
		}
	}
	list := capabilities()
	for _, c := range []string{wire.CapHosts1, wire.CapControl1} {
		if !slices.Contains(list, c) {
			t.Errorf("%s is not in the control plane's list", c)
		}
	}
}

// control/status says the control plane's list and its required sets; hosts/list says the
// list each host said.
func TestStatusAndHostsSayCapabilities(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	_, window := p.client("Window")
	var status wire.ControlStatus
	json.Unmarshal(call(t, window, "", "control/status", map[string]any{}), &status)
	if !slices.Contains(status.Capabilities, wire.CapHosts1) || status.Required == nil ||
		!slices.Equal(status.Required.Host, []string{wire.CapHostWire1}) || !slices.Equal(status.Required.Client, []string{wire.CapClientWire1}) {
		t.Fatalf("control/status: %+v %+v", status.Capabilities, status.Required)
	}
	// The fake host says no list, as a host older than #1748: none, and nothing missing.
	var hosts []wire.ControlHost
	json.Unmarshal(call(t, window, "", "hosts/list", map[string]any{}), &hosts)
	for _, h := range hosts {
		if string(h.ID) == box.member.Host && (h.Capabilities != nil || h.Missing != nil || h.State != "online") {
			t.Fatalf("an older host: %+v", h)
		}
	}
}

// A host whose list lacks a required capability needs an update, and is online again once
// it says one that has the set.
func TestAHostWithoutTheRequiredSetNeedsAnUpdate(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	hello := func(list []string) {
		params, _ := json.Marshal(wire.HostHello{Version: "0.6.0", Platform: "linux aarch64", MachineID: "MACHINE-2",
			Capabilities: list})
		if _, err := p.s.methods.HostSaid(box.member.Host, "host/hello", params); err != nil {
			t.Fatal(err)
		}
	}
	hello([]string{wire.CapAgents1})
	state, _ := p.s.Router().State(box.member.Host)
	if state.State != "needsUpdate" || state.From != "0.6.0" || state.To != p.s.cfg.Version {
		t.Fatalf("state: %+v", state)
	}
	_, window := p.client("Window")
	var hosts []wire.ControlHost
	json.Unmarshal(call(t, window, "", "hosts/list", map[string]any{}), &hosts)
	found := false
	for _, h := range hosts {
		if string(h.ID) == box.member.Host {
			found = true
			if !slices.Equal(h.Capabilities, []string{wire.CapAgents1}) || !slices.Equal(h.Missing, []string{wire.CapHostWire1}) ||
				h.State != "needsUpdate" {
				t.Fatalf("hosts/list: %+v", h)
			}
		}
	}
	if !found {
		t.Fatal("no row for the host")
	}
	hello([]string{wire.CapAgents1, wire.CapHostWire1})
	if state, _ := p.s.Router().State(box.member.Host); state.State != "online" {
		t.Fatalf("state after an update: %+v", state)
	}
}

// A client whose list lacks a required capability is answered -32008 with what it is
// missing, on each call but control/status; one that says no list is not.
func TestAClientWithoutTheRequiredSetIsToldToUpdate(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	m, err := controllink.PairClient(context.Background(), p.code(false), "Old window")
	if err != nil {
		t.Fatal(err)
	}
	m.Capabilities = []string{"something.else/1"}
	old, err := controllink.DialClient(context.Background(), m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(old.Close)
	e := callError(t, old, "", "hosts/list", map[string]any{})
	if !strings.Contains(e, "-32008") || !strings.Contains(e, wire.CapClientWire1) {
		t.Fatalf("hosts/list: %s", e)
	}
	call(t, old, "", "control/status", map[string]any{})
	if clientRefusal(nil, "0.7.0") != nil {
		t.Fatal("a client that says no list is refused")
	}
	if clientRefusal([]string{wire.CapClientWire1}, "0.7.0") != nil {
		t.Fatal("a client with the required set is refused")
	}
}
