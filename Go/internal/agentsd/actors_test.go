package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// actorConn is a channel the control plane opened with an actor (ChannelOpen.actor).
type actorConn struct {
	*conn
	actor *wire.AuditActor
}

func (a actorConn) Actor() *wire.AuditActor { return a.actor }

func someone() *wire.AuditActor {
	name, client, clientName := "Ana", wire.UUID("11111111-2222-3333-4444-555555555555"), "Ana's iPhone"
	return &wire.AuditActor{User: "ana", UserName: &name, Client: &client, ClientName: &clientName}
}

// #1751: the events a person's call raises carry the actor the control plane gave its
// channel into events.jsonl; what the agent does by itself carries none.
func TestAPersonsCallsPutTheirActorOnTheLog(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, _ := start(t, root)
	c := actorConn{newConn(), someone()}
	go d.Accept(c)
	t.Cleanup(func() { close(c.in) })

	id := startAgent(t, c.conn, 1, t.TempDir(), "Write it")
	waitFor(t, "it finished", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
	waitFor(t, "the finish on the log", func() bool { n := names(d); return len(n) > 0 && n[len(n)-1] == "agent.finished" })
	c.call(t, 2, "agents/archive", map[string]any{"agentID": id})
	c.call(t, 3, "agents/delete", map[string]any{"agentID": id})

	by := map[string]*wire.AuditActor{}
	for _, e := range logged(d) {
		by[e.Name] = e.Actor
	}
	for _, name := range []string{"agent.started", "agent.archived", "agent.deleted"} {
		if a := by[name]; a == nil || a.User != "ana" || *a.ClientName != "Ana's iPhone" {
			t.Fatalf("%s: %+v", name, a)
		}
	}
	if by["agent.finished"] != nil {
		t.Fatalf("the agent finished by itself: %+v", by["agent.finished"])
	}
	b, _ := os.ReadFile(filepath.Join(root, "events.jsonl"))
	if strings.Count(string(b), `"user":"ana"`) != 3 {
		t.Fatalf("events.jsonl:\n%s", b)
	}

	// A client's own word in its draft is never read: the channel's actor is.
	d.RaiseByHand = true
	var e wire.Event
	draft := map[string]any{"name": "branch.moved", "at": now(), "scope": map[string]any{"mac": map[string]any{}},
		"sentence": "moved.", "details": map[string]any{}, "chainDepth": 0, "actor": map[string]any{"user": "mallory"}}
	if err := json.Unmarshal(c.call(t, 4, "events/raise", map[string]any{"draft": draft}), &e); err != nil {
		t.Fatal(err)
	}
	if e.Actor == nil || e.Actor.User != "ana" {
		t.Fatalf("%+v", e.Actor)
	}
}

// The same event from two people is two events, not one with a count.
func TestTwoPeoplesEventsDoNotFold(t *testing.T) {
	d, _ := start(t, t.TempDir())
	draft := wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: "ci went offline.",
		Details: map[string]string{"server": "ci"}}
	other := someone()
	other.User = "ben"
	d.raiseAs(draft, someone())
	d.raiseAs(draft, someone())
	d.raiseAs(draft, other)
	got := logged(d)
	if len(got) != 2 || got[0].Actor.User != "ben" || got[1].Count != 2 {
		t.Fatalf("%+v", got)
	}
}
