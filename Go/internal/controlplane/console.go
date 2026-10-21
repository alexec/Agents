package controlplane

import (
	"context"
	"encoding/json"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/wire"
)

// The Console (#1804): the control plane's app for its admins, on the web page beside the
// Workspace and Reports. Its pages read what the control plane keeps already: people,
// machines, and the numbers and events the machines send. Never a conversation.

// consoleMethods are the Console's: an admin's each, naming no machine, so another
// person's machine is never named by one (#994).
var consoleMethods = map[string]bool{"console/fleet": true}

// consoleMethod answers the Console's own calls. Each is an admin's.
func (m *Methods) consoleMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.callerPerson(from)) {
		return nil, fail(notPermitted, "Only an admin can open the Console.")
	}
	switch method {
	case "console/fleet":
		return m.fleet(ctx), nil
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// liveStates are the agent states a machine's list counts as running.
var liveStates = map[string]bool{"starting": true, "running": true, "waitingOnUser": true}

// fleet is console/fleet (M1): every machine, its owner, and how many of its agents were
// running when it last listed them. Offline first, then by owner and name.
func (m *Methods) fleet(ctx context.Context) wire.FleetBoard {
	out := []wire.FleetMachine{}
	for _, h := range m.records.Hosts() {
		owner := m.s.ownerOf(h.ID)
		machine := wire.FleetMachine{Host: m.hostRow(h), OwnerName: m.s.personName(owner), Bot: m.s.isBot(owner)}
		// As the audit names them (actorFor).
		if owner == m.s.localOwner() {
			machine.OwnerName = audit.LocalOwnerName
		}
		if copy := m.s.copies.current(ctx, h.ID); copy != nil && copy.Agents != nil {
			var agents []struct {
				State string `json:"state"`
			}
			if json.Unmarshal(copy.Agents, &agents) == nil {
				var running int64
				for _, a := range agents {
					if liveStates[a.State] {
						running++
					}
				}
				machine.Running = &running
				heard := dateOf(copy.HeardAt.Time)
				machine.HeardAt = &heard
			}
		}
		out = append(out, machine)
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.Host.State == "offline") != (b.Host.State == "offline") {
			return a.Host.State == "offline"
		}
		if a.OwnerName != b.OwnerName {
			return strings.ToLower(a.OwnerName) < strings.ToLower(b.OwnerName)
		}
		return strings.ToLower(a.Host.Name) < strings.ToLower(b.Host.Name)
	})
	return wire.FleetBoard{Machines: out}
}
