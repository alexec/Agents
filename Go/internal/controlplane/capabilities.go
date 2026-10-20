package controlplane

import (
	"encoding/json"
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

// capabilities is the control plane's own list: it answers every method of
// control.openrpc.json (TestControlPlaneAnswersItsDocument), and declares the rest.
func capabilities() []string {
	return wire.Served(wire.ControlCapabilities, wire.ControlNotifications, func(string) bool { return true },
		wire.DeclaredCapabilities["control"]...)
}

// clientRefusal is what each call of a client without the required set is answered with:
// -32008, with what it is missing and the version to update to. Nil for a client that has
// the set, or that says no list at all, as one older than #1748 does.
func clientRefusal(list []string, version string) *RPCError {
	if list == nil {
		return nil
	}
	missing := wire.Missing(list, required.Client)
	if missing == nil {
		return nil
	}
	data, _ := json.Marshal(map[string]any{"missing": missing, "update": version})
	return &RPCError{Code: wrongProtocolVersion, Message: "This app needs an update to work with this control plane.", Data: data}
}

// refusedOld answers a request from a client too old for this control plane (#1748), and
// says so; control/status still goes, so the client can say what to do.
func (r *Router) refusedOld(sessionID, host, msg string, kind int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.clients[sessionID]
	if s == nil || s.refusal == nil {
		return false
	}
	m, ok := decode(msg)
	if !ok || !m.isRequest() || m.Method == "control/status" {
		return false
	}
	e := replyError(m.ID, s.refusal)
	if kind != frameLegacy {
		e = wrap(host, e)
	}
	r.writeLocked(sessionID, e)
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
func hostCapabilities(h records.HostRecord) []string {
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
func withCapabilities(h records.HostRecord, list []string) records.HostRecord {
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
// a required capability, and online again when it no longer does.
func (m *Methods) noteCapabilities(host string, hello wire.HostHello) {
	if hello.Capabilities == nil {
		return
	}
	if missing := wire.Missing(hello.Capabilities, required.Host); missing != nil {
		m.router.SetNeedsUpdate(host, hello.Version, m.s.cfg.Version)
		m.s.log("control: host " + host + " needs an update: " + strings.Join(missing, ", "))
		return
	}
	m.router.SetNeedsUpdate(host, "", "")
}
