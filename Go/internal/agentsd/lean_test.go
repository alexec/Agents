package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports LeanRecordsTests: the whole record and new entries go to the window showing the
// agent; every other window gets the record lean, and no entries; a large entry is a stub.

// heard pings the connection and gives the notifications that came before the answer.
func heard(t *testing.T, c *conn, id int) map[string][]json.RawMessage {
	t.Helper()
	c.in <- `{"jsonrpc":"2.0","id":` + string(mustJSON(id)) + `,"method":"daemon/ping"}`
	out := map[string][]json.RawMessage{}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method == "" && string(m.ID) == string(mustJSON(id)) {
				return out
			}
			out[m.Method] = append(out[m.Method], m.Params)
		case <-deadline:
			t.Fatal("no answer to the ping")
		}
	}
}

func TestOnlyTheWindowShowingAnAgentGetsItWhole(t *testing.T) {
	d, showing := start(t, t.TempDir())
	defer d.Shutdown()
	other := newConn()
	go d.Accept(other)
	t.Cleanup(func() { close(other.in) })
	a := seeded(t, d, t.TempDir(), nil)
	showing.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	other.call(t, 1, "presence/report", map[string]any{"active": true})

	// The lists move: whole to the window showing it, lean to the other.
	d.change(a.ID, func(a *wire.Agent) { a.AvailableCommands = []wire.SlashCommand{{Name: "review"}} })
	var got wire.Agent
	h := heard(t, showing, 2)
	json.Unmarshal(h["agent/changed"][0], &got)
	if len(got.AvailableCommands) != 1 || got.ListsLeftOut != nil {
		t.Fatalf("%+v", got)
	}
	got = wire.Agent{}
	h = heard(t, other, 2)
	json.Unmarshal(h["agent/changed"][0], &got)
	if len(got.AvailableCommands) != 0 || got.ListsLeftOut == nil || !*got.ListsLeftOut {
		t.Fatalf("%+v", got)
	}
	// They did not move: lean to both.
	d.change(a.ID, func(a *wire.Agent) { a.IsUnread = new(bool) })
	got = wire.Agent{}
	json.Unmarshal(heard(t, showing, 3)["agent/changed"][0], &got)
	if got.ListsLeftOut == nil {
		t.Fatalf("%+v", got)
	}
	heard(t, other, 3)

	// An entry goes to the window showing it only, and a large one as a stub.
	d.record(a.ID, runtimeNote("small"))
	d.record(a.ID, runtimeNote(strings.Repeat("x", entryByteLimit)))
	entries := heard(t, showing, 4)["agent/entry"]
	if len(entries) != 2 {
		t.Fatalf("%d entries", len(entries))
	}
	var small, big wire.EntryNotification
	json.Unmarshal(entries[0], &small)
	json.Unmarshal(entries[1], &big)
	if small.Index != nil || small.Oversized != nil || big.Oversized == nil || *big.Oversized <= entryByteLimit || big.Index == nil || *big.Index != 1 ||
		!strings.Contains(string(entries[1]), `"kind":{"oversized":`) {
		t.Fatalf("%s %s", entries[0], entries[1])
	}
	if e := heard(t, other, 4)["agent/entry"]; len(e) != 0 {
		t.Fatalf("the other window was sent %d entries", len(e))
	}

	// A window that goes is no longer sent them.
	showing.call(t, 5, "presence/report", map[string]any{"active": true})
	d.record(a.ID, runtimeNote("after"))
	if e := heard(t, showing, 6)["agent/entry"]; len(e) != 0 {
		t.Fatal("sent to a window that left it")
	}
}

func TestTheWatchedAgentIsShownAndAListCanBeLean(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.AvailableCommands = []wire.SlashCommand{{Name: "review"}}
	})
	archived := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.AvailableCommands = wire.AgentStateArchived, []wire.SlashCommand{{Name: "review"}}
		r, at := wire.AgentArchivedReasonByUser, now()
		a.ArchivedReason, a.ArchivedAt = &r, &at
	})
	// The web reports only what it watches.
	c.call(t, 1, "presence/report", map[string]any{"active": false, "watching": a.ID})
	d.record(a.ID, runtimeNote("hello"))
	if e := heard(t, c, 2)["agent/entry"]; len(e) != 1 {
		t.Fatal("the watched agent was not shown")
	}
	var list []wire.Agent
	json.Unmarshal(c.call(t, 3, "agents/list", map[string]any{"lean": true, "includeArchived": true}), &list)
	if len(list) != 2 || len(list[0].AvailableCommands) != 0 || list[0].ListsLeftOut == nil {
		t.Fatalf("%+v", list)
	}
	list = nil
	json.Unmarshal(c.call(t, 4, "agents/list", map[string]any{"includeArchived": true}), &list)
	for _, l := range list {
		if l.ID == archived.ID && len(l.AvailableCommands) != 0 || l.ID == a.ID && len(l.AvailableCommands) != 1 || l.ListsLeftOut != nil {
			t.Fatalf("%+v", l)
		}
	}
}
