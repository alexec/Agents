package controlplane

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// required is the least the control plane needs of a peer to route for it (#1748,
// docs/explanation/versions.md). It moves only when an old capability number is removed.
var required = wire.RequiredCapabilities{
	Host:   []string{wire.CapHostWire1},
	Client: []string{wire.CapClientWire1},
}

// wrongProtocolVersion is DaemonAPI.Failure.wrongProtocolVersion.
const wrongProtocolVersion = wire.FailureWrongProtocolVersion

// updateToJoinTeam is DaemonAPI.Failure.updateToJoinTeam (#1763, R14).
const updateToJoinTeam = wire.FailureUpdateToJoinTeam

// requiredNow is required, and on a control plane with more than one person (a team) the
// team capabilities too: a build from before them cannot tell people apart (R14).
func requiredNow(team bool) wire.RequiredCapabilities {
	if !team {
		return required
	}
	return wire.RequiredCapabilities{
		Host:   append(slices.Clone(required.Host), wire.CapHostTeam1),
		Client: append(slices.Clone(required.Client), wire.CapClientTeam1),
	}
}

// joinTeamRefusal is -32074 with what is missing and the version to update to.
func joinTeamRefusal(message, version string, missing []string) *RPCError {
	data, _ := json.Marshal(map[string]any{"missing": missing, "update": version})
	return &RPCError{Code: updateToJoinTeam, Message: message, Data: data}
}

// capabilities is the control plane's own list: it answers every method of
// control.openrpc.json (TestControlPlaneAnswersItsDocument), and declares the rest.
func capabilities() []string {
	return wire.Served(wire.ControlCapabilities, wire.ControlNotifications, func(string) bool { return true },
		wire.DeclaredCapabilities["control"]...)
}

// clientRefusal is what each call of a client without the required set is answered with:
// -32008, with what it is missing and the version to update to. Nil for a client that has
// the set, or that says no list at all, as one older than #1748 does. On a team, a client
// without client.team/1, or with no list, is answered -32074 (#1763, R14).
func clientRefusal(list []string, version string, team bool) *RPCError {
	if list != nil {
		if missing := wire.Missing(list, required.Client); missing != nil {
			data, _ := json.Marshal(map[string]any{"missing": missing, "update": version})
			return &RPCError{Code: wrongProtocolVersion, Message: "This app needs an update to work with this control plane.", Data: data}
		}
	}
	if team && !slices.Contains(list, wire.CapClientTeam1) {
		return joinTeamRefusal("Update Agents to join this team.", version, []string{wire.CapClientTeam1})
	}
	return nil
}

// hostRefusal is what a call to a host from before the team tier is answered with, on a
// team: it would act for every person alike (#1763, R14). Nil for any other host.
func hostRefusal(list []string, version string, team bool) *RPCError {
	if !team || slices.Contains(list, wire.CapHostTeam1) {
		return nil
	}
	return joinTeamRefusal("This host needs an update to join this team.", version, []string{wire.CapHostTeam1})
}

// refusedOld answers a request from a client too old for this control plane (#1748), and
// says so; control/status still goes, so the client can say what to do.
func (r *Router) refusedOld(sessionID, host, msg string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.clients[sessionID]
	if s == nil {
		return false
	}
	refusal := clientRefusal(s.capabilities, r.version, r.team)
	if refusal == nil {
		return false
	}
	m, ok := decode(msg)
	if !ok || !m.isRequest() || m.Method == "control/status" {
		return false
	}
	r.writeLocked(sessionID, wrap(host, replyError(m.ID, refusal)))
	return true
}

// SetNeedsUpdate says a connected host is too old for this control plane, from its version
// to this one's; with from and to empty, that it is not, any more.
func (r *Router) SetNeedsUpdate(host, from, to string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.hosts[host] == nil {
		return
	}
	if from == "" && to == "" {
		if r.states[host].State == "needsUpdate" {
			r.setStateLocked(host, hostState{State: "online"})
		}
		return
	}
	r.setStateLocked(host, hostState{State: "needsUpdate", From: from, To: to})
}

// hostCapabilities is the list a host said in its last host/hello, kept beside the record's
// own fields as its implementation is; nil for a host older than #1748.
func hostCapabilities(h records.MachineRecord) []string {
	raw, ok := h.Extra["capabilities"]
	if !ok {
		return nil
	}
	var list []string
	if json.Unmarshal(raw, &list) != nil {
		return nil
	}
	return list
}

// withCapabilities is the record with the list a host said, or without one when it said none.
func withCapabilities(h records.MachineRecord, list []string) records.MachineRecord {
	extra := records.Extra{}
	for k, v := range h.Extra {
		if k != "capabilities" {
			extra[k] = v
		}
	}
	if list != nil {
		extra["capabilities"], _ = json.Marshal(list)
	}
	if len(extra) == 0 {
		extra = nil
	}
	h.Extra = extra
	return h
}

// noteCapabilities settles a host's state from the list it said: needsUpdate when it lacks
// a required capability, and online again when it no longer does. On a team, a host that
// says no list needs one too (R14).
func (m *Methods) noteCapabilities(host string, list []string, version string) {
	team := m.router.Team()
	m.router.SetHostCapabilities(host, list)
	if list == nil && !team {
		m.router.SetNeedsUpdate(host, "", "")
		return
	}
	if missing := wire.Missing(list, requiredNow(team).Host); missing != nil {
		m.router.SetNeedsUpdate(host, version, m.s.cfg.Version)
		m.s.log("control: host " + host + " needs an update: " + strings.Join(missing, ", "))
		return
	}
	m.router.SetNeedsUpdate(host, "", "")
}

// MARK: A team (#1763, R14)

// isTeam says the control plane has more than one person: bots too, as they are users.
func (s *Service) isTeam() bool {
	n := 0
	for _, p := range s.records.People() {
		if !p.IsRemoved() {
			n++
		}
	}
	return n > 1
}

// noteTeam holds every session here to whether the control plane is a team now: a client
// or host from before the team tier is refused from the moment a second person joins,
// and let in again once only one is left.
func (s *Service) noteTeam() {
	team := s.isTeam()
	was := s.router.SetTeam(team, s.cfg.Version)
	for _, h := range s.records.Hosts() {
		if was != team && s.router.Holds(h.ID) {
			s.methods.noteCapabilities(h.ID, hostCapabilities(h), h.Version)
		} else {
			s.router.SetHostCapabilities(h.ID, hostCapabilities(h))
		}
	}
	if was != team {
		s.log(fmt.Sprintf("control: a team: %v", team))
	}
}

// Team says whether the control plane has more than one person, as last noted.
func (r *Router) Team() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.team
}

// SetTeam says whether the control plane is a team, and the version a build from before
// the team tier is told to update to; it returns what it was.
func (r *Router) SetTeam(team bool, version string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	was := r.team
	r.team, r.version = team, version
	return was
}

// SetHostCapabilities keeps the list a connected host said, for hostRefusal.
func (r *Router) SetHostCapabilities(host string, list []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.hostCapabilities == nil {
		r.hostCapabilities = map[string][]string{}
	}
	r.hostCapabilities[host] = list
}
