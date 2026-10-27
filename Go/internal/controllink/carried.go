package controllink

import (
	"encoding/json"

	"github.com/alexec/agents/Go/wire"
)

// Carried is what the control plane tells a host that carries a page from its loopback
// listener (#1480), on the line right after the page's ok, when that host may answer the
// page's calls itself (#1970): the page is a browser of the host's own person. Actor is who
// the page is, for the events its calls raise (#996); Up are the methods that still go
// through the control plane, which keeps them in the audit and holds its checks on them.
// The host takes it, and never passes it to the page. No line means the host answers
// nothing itself.
type Carried struct {
	Actor wire.AuditActor `json:"actor"`
	Up    []string        `json:"up"`
}

// Line is {"carried":{…}}.
func (c Carried) Line() string {
	b, _ := json.Marshal(map[string]Carried{"carried": c})
	return string(b)
}

// ParseCarried reads a Carried line, or says the line is not one.
func ParseCarried(line string) (Carried, bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &m) != nil || len(m) != 1 || m["carried"] == nil {
		return Carried{}, false
	}
	var c Carried
	if json.Unmarshal(m["carried"], &c) != nil || c.Actor.User == "" {
		return Carried{}, false
	}
	return c, true
}
