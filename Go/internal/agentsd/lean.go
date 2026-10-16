package agentsd

import (
	"encoding/json"
	"log"
	"reflect"

	"github.com/alexec/agents/Go/wire"
)

// Lean records, as DaemonCore.tellChanged and record send them: an agent's whole record
// and its new transcript entries go only to the connections showing it; every other
// connection gets the record without its lists (Agent.leaned), and no entries.

// entryByteLimit is EntryNotification.entryByteLimit: an entry larger than this is sent as
// a stub, and the client reads it with agents/transcript.
const entryByteLimit = 32 * 1024

// leaned is Agent.leaned: the record without the lists only a page showing it draws.
func leaned(a wire.Agent) wire.Agent {
	t := true
	a.AdvertisedOptions, a.AvailableCommands, a.Plans, a.ListsLeftOut = []wire.ConfigOption{}, []wire.SlashCommand{}, nil, &t
	return a
}

// listsDiffer is Agent.listsDiffer: whether a change moved one of the lists leaned leaves out.
func listsDiffer(a, before *wire.Agent) bool {
	return !reflect.DeepEqual(a.AdvertisedOptions, before.AdvertisedOptions) ||
		!reflect.DeepEqual(a.AvailableCommands, before.AvailableCommands) ||
		!reflect.DeepEqual(a.Plans, before.Plans)
}

// showers is ShowingBox.connections(showing:): the connections whose last presence/report
// shows the agent.
func (d *Daemon) showers(id wire.UUID) map[int64]bool {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	out := map[int64]bool{}
	for c, p := range d.presences {
		if p.shown[id] {
			out[c] = true
		}
	}
	return out
}

// tellChanged sends agent/changed: whole to those showing the agent when its lists moved
// (or it is new), lean to everyone else; lean to all when the lists did not move, as the
// clients keep the lists they hold. A writer agent's record is never sent.
func (d *Daemon) tellChanged(a wire.Agent, before *wire.Agent) {
	if a.Purpose != nil {
		return
	}
	lean := leaned(a)
	showers := d.showers(a.ID)
	if len(showers) == 0 || before != nil && !listsDiffer(&a, before) {
		Broadcast(d, wire.NotifyAgentChanged, lean)
		return
	}
	sendEach(d, wire.NotifyAgentChanged, func(c *Client) (wire.Agent, bool) {
		if showers[c.ID] {
			return a, true
		}
		return lean, true
	})
}

// tellEntry sends agent/entry to the connections showing the agent; an entry over the
// limit goes as a stub that says where it is.
func (d *Daemon) tellEntry(id wire.UUID, e wire.TranscriptEntry, index int) {
	showers := d.showers(id)
	if len(showers) == 0 {
		return
	}
	n := wire.EntryNotification{AgentID: id, Entry: e}
	if b, err := json.Marshal(e); err == nil && len(b) > entryByteLimit {
		size := int64(len(b))
		raw, _ := json.Marshal(map[string]int64{"oversized": size})
		n.Entry = wire.TranscriptEntry{ID: e.ID, At: e.At, Kind: wire.TranscriptEntryKind{Unrecognised: raw}, SubagentID: e.SubagentID}
		n.Oversized = &size
		at := int64(index)
		n.Index = &at
	} else if err != nil {
		log.Printf("agent %s: encode an entry: %v", id, err)
		return
	}
	sendEach(d, wire.NotifyAgentEntry, func(c *Client) (wire.EntryNotification, bool) { return n, showers[c.ID] })
}

// sendEach sends a notification to the clients pick says yes to, each with its own params.
func sendEach[P any](d *Daemon, n wire.Notification[P], pick func(c *Client) (P, bool)) {
	d.mu.Lock()
	cs := make([]*Client, 0, len(d.clients))
	for _, c := range d.clients {
		cs = append(cs, c)
	}
	d.mu.Unlock()
	for _, c := range cs {
		params, ok := pick(c)
		if !ok {
			continue
		}
		p, err := json.Marshal(params)
		if err != nil {
			log.Printf("encode %s: %v", n.Name, err)
			return
		}
		b, _ := json.Marshal(message{JSONRPC: "2.0", Method: n.Name, Params: p})
		_ = c.conn.Write(string(b))
	}
}
