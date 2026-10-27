package wire

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"time"
)

// Trigger ids (#2011): written by hand, as every machine that hears a trigger names it and
// the control plane checks the name a machine sent.

// ScheduleTriggerID is a schedule's trigger: its due time.
func ScheduleTriggerID(due time.Time) string {
	return "schedule:" + due.UTC().Format(time.RFC3339)
}

// EventTriggerID is an event's trigger: its name and details. A server's event is the same
// on every machine by its server, event and id: when it was heard, what was missed before
// it, its subscription and what each machine's credentials were shown of it (a bot's, a
// person's heard for it, #2027) are each machine's own.
func EventTriggerID(name string, details map[string]string) string {
	keys := make([]string, 0, len(details))
	for k := range details {
		if details["mcp_event_id"] != "" && k != "server" && k != "event" && k != "mcp_event_id" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	h := sha256.New()
	h.Write([]byte(name))
	for _, k := range keys {
		h.Write([]byte{0})
		h.Write([]byte(k + "=" + details[k]))
	}
	return "event:" + name + ":" + hex.EncodeToString(h.Sum(nil))[:24]
}
