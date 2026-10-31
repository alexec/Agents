package agentsd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports EventWaitTests and EventPatternTests: what a wait refuses and why, a call answered
// by the event, a call held as long as it may and the agent woken later with the news, and
// the ends a wait comes to.

func TestAWaitSaysWhatIsWrongWithIt(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	m := appClient(t, d, seeded(t, d, t.TempDir(), nil).ID)
	m.post("initialize", map[string]any{}, 1)
	for i, c := range []struct {
		args map[string]any
		want string
	}{
		{map[string]any{"events": []string{}}, `Say what to wait for in events, e.g. ["agent.finished"].`},
		{map[string]any{"events": "agent.finished"}, "until_minutes is required: say how long to wait, from 1 minute to 24 hours (1440)."},
		{map[string]any{"events": "agent.finished", "until_minutes": 0}, "until_minutes has to be from 1 to 1440."},
		{map[string]any{"events": "agent.finsihed", "until_minutes": 5}, `"agent.finsihed" is not an event. Did you mean agent.finished? Events you can wait on: agent.started,`},
		{map[string]any{"events": "custom.done", "until_minutes": 5}, `"custom.done" is never raised: agents no longer publish events`},
		{map[string]any{"events": "agent.finished", "where": map[string]any{"x": 1}, "until_minutes": 5},
			`agent.finished takes no arguments; "x" is not one of its arguments. To wait for particular agents, use wait_for_agents.`},
		{map[string]any{"events": "person.away", "where": map[string]any{"why": "asleep"}, "until_minutes": 5},
			"person.away: why is one of locked, idle, not asleep."},
		{map[string]any{"events": []string{"mac.wake", "person.back"}, "until_minutes": 5},
			"mac.wake, person.back are only raised on a Mac, and this machine is a Linux server, so they never happen here. Nothing is waiting."},
		{map[string]any{"events": "pr.merged", "until_minutes": 5}, "No server here offers pr.merged. This folder has no MCP server that offers events."},
	} {
		text, isErr := m.tool(10+i, "wait_for_event", c.args)
		if !isErr || !strings.HasPrefix(text, c.want) {
			t.Errorf("%v: %s", c.args, text)
		}
	}
	if text, _ := m.tool(31, "cancel_wait", nil); text != "You weren't waiting on anything." {
		t.Fatal(text)
	}
}

func TestAWaitIsAnsweredByItsEvent(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "wait_for_event", map[string]any{"events": "server.*", "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the wait on the record", func() bool { return d.Store.Agent(a.ID).EventWait != nil })
	if w := d.waitingAgents(); len(w) != 1 || !strings.HasPrefix(w[0].Status.Line, "◷ Waiting for server.* · since ") {
		t.Fatalf("%+v", w)
	}
	e := d.raise(wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: "ci went offline.", Details: map[string]string{"server": "ci"}})
	text := <-answered
	if !strings.HasPrefix(text, "server.offline happened at ") || !strings.Contains(text, "after waiting 0 s: ci went offline.. server=ci. You can carry on.") &&
		!strings.Contains(text, ": ci went offline.. server=ci. You can carry on.") {
		t.Fatal(text)
	}
	if got := d.event(e.Position); len(got.Consequences) != 1 || got.Consequences[0].Woke == nil {
		t.Fatalf("%+v", got)
	}
	if d.Store.Agent(a.ID).EventWait != nil || len(d.waitingAgents()) != 0 {
		t.Fatal("still waiting")
	}
	// A later wait starts from the current head, so an event already on the log is not a match.
}

func TestAHeldWaitWakesTheAgentLater(t *testing.T) {
	fakeRuntimes(t)
	was := eventHoldLimit
	eventHoldLimit = 300 * time.Millisecond
	defer func() { eventHoldLimit = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, _ := m.tool(2, "wait_for_event", map[string]any{"events": "branch.moved", "where": map[string]any{"branch": []string{"ci", "cd"}}, "until_minutes": 10})
	if !strings.HasPrefix(text, "Still waiting for branch.moved branch ci|cd, since ") || !strings.Contains(text, "Your place is kept; you can end your turn.") {
		t.Fatal(text)
	}
	waitFor(t, "agent.waiting on the log", func() bool { n := names(d); return len(n) > 0 && n[len(n)-1] == "agent.waiting" })
	d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: folderScope(dir), Sentence: "other moved.", Details: map[string]string{"branch": "other"}})
	if w := d.Store.Agent(a.ID).EventWait; w == nil || w.Ending != nil {
		t.Fatal("woken by an event it did not wait for")
	}
	d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: folderScope(dir), Sentence: "cd moved.", Details: map[string]string{"branch": "cd"}})
	waitFor(t, "the wake in its chat", func() bool {
		for _, u := range userMessages(d, a.ID) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nbranch.moved at ") && strings.Contains(u, "\ncd moved.\nbranch: cd") {
				return true
			}
		}
		return false
	})
	if w := d.Store.Agent(a.ID).EventWait; w == nil || w.Ending == nil || w.Ending.Matched == nil {
		t.Fatalf("%+v", w)
	}
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(a.ID).State == wire.AgentStateFinished })
}

func TestAWaitEnds(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	wait := func(id int) chan string {
		answered := make(chan string, 1)
		go func() {
			text, _ := m.tool(id, "wait_for_event", map[string]any{"events": "lease.granted", "until_minutes": 10})
			answered <- text
		}()
		waitFor(t, "the wait", func() bool { w := d.Store.Agent(a.ID).EventWait; return w != nil && w.Ending == nil })
		return answered
	}
	answered := wait(2)
	c.call(t, 1, "events/cancelWait", map[string]any{"agentID": a.ID})
	if text := <-answered; text != "The person cancelled your wait for lease.granted. Check whether lease.granted happened anyway before you stop: the person may only be telling you to carry on without waiting, not that it did not happen." {
		t.Fatal(text)
	}
	if e := c.callError(t, 2, "events/cancelWait", map[string]any{"agentID": a.ID}); e.Message != "That agent is not waiting on anything." {
		t.Fatal(e.Message)
	}
	answered = wait(3)
	if text, _ := m.tool(4, "cancel_wait", nil); text != "Stopped waiting for lease.granted." {
		t.Fatal(text)
	}
	if text := <-answered; text != "Stopped waiting for lease.granted." {
		t.Fatal(text)
	}
	answered = wait(5)
	past := wire.DateOf(time.Now().Add(-time.Second))
	d.change(a.ID, func(a *wire.Agent) {
		w := *a.EventWait
		w.Deadline = &past
		a.EventWait = &w
	})
	d.waitDeadlinesPassed()
	if text := <-answered; !strings.HasPrefix(text, "Your wait for lease.granted timed out at ") || !strings.HasSuffix(text, " with no match.") {
		t.Fatal(text)
	}
	// A second wait replaces the first, which hears so.
	answered = wait(6)
	second := make(chan string, 1)
	go func() {
		text, _ := m.tool(7, "wait_for_event", map[string]any{"events": "lease.released", "until_minutes": 10})
		second <- text
	}()
	if text := <-answered; text != "Replaced your earlier wait on lease.granted. " {
		t.Fatal(text)
	}
	waitFor(t, "the second wait", func() bool {
		w := d.Store.Agent(a.ID).EventWait
		return w != nil && w.Patterns[0].Name == "lease.released"
	})
	c.call(t, 3, "agents/stop", map[string]any{"agentID": a.ID})
	if text := <-second; text != "Replaced your earlier wait on lease.granted. You were stopped, which ended your wait for lease.released." {
		t.Fatal(text)
	}
}

// aPersonEventsServer is a streamable HTTP MCP server offering review.requested by poll,
// an event raised only about the connected account (#2034), never the repo.
func aPersonEventsServer(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int            `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		var result any
		switch m.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": "2026-07-28", "capabilities": map[string]any{"events": map[string]any{"listChanged": true}}}
		case "events/list":
			result = map[string]any{"events": []any{map[string]any{"name": "review.requested", "delivery": []string{"poll"},
				"inputSchema": map[string]any{"type": "object", "additionalProperties": false,
					"properties": map[string]any{"repo": map[string]any{"type": "string"}, "pr": map[string]any{"type": "integer"}}}}}}
		case "events/poll":
			result = map[string]any{"events": []any{}, "cursor": "c1", "truncated": false, "hasMore": false, "nextPollMs": 10}
		default:
			result = map[string]any{}
		}
		w.Header().Set("Mcp-Session-Id", "s1")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": *m.ID, "result": result})
	}))
	t.Cleanup(s.Close)
	return s
}

// A wait on review.requested, which is always about the connected account (#2034), sets
// ForPerson on the record, unlike an ordinary server event (#3051).
func TestAWaitOnAPersonEventIsMarkedForPerson(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	gh := aPersonEventsServer(t)
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	serverHome(t, d, gh.URL)
	quickPolls(d)
	d.StartMCPEvents()
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "wait_for_event", map[string]any{"events": "review.requested", "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the wait on the record", func() bool { return d.Store.Agent(a.ID).EventWait != nil })
	w := d.Store.Agent(a.ID).EventWait
	if w.ForPerson == nil || !*w.ForPerson {
		t.Fatalf("%+v", w)
	}
	if got := Group(d.Store.Agent(a.ID)); got != "needsAttention" {
		t.Fatalf("Group() = %s, want needsAttention", got)
	}
	// Ended cleanly, so no poll outlives the test and its server (#577).
	if text, _ := m.tool(3, "cancel_wait", nil); !strings.HasPrefix(text, "Stopped waiting for review.requested") {
		t.Fatal(text)
	}
	<-answered
}
