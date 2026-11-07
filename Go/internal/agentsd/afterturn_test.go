package agentsd

import (
	"encoding/json"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Shutdown returns once the turns it stopped have written their endings and what follows
// them, and starts nothing after (#1272).
func TestShutdownWaitsForTheWritesAfterATurn(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "wait for me"}), &id)
	c.until(t, "running", ended(id, wire.AgentStateRunning))

	d.Shutdown()

	if k := kinds(d, id); len(k) == 0 || k[len(k)-1] != "stateChanged" {
		t.Fatalf("the ending was not recorded before Shutdown returned: %v", k)
	}
	b, _ := os.ReadFile(d.eventsPath())
	if !endingRaised(string(b), id) {
		t.Fatalf("the agent's ending was not in events.jsonl before Shutdown returned:\n%s", b)
	}
	if d.goAfterTurn("a turn after Shutdown", func() {}) {
		t.Fatal("something started after Shutdown")
	}
	time.Sleep(200 * time.Millisecond)
	if after, _ := os.ReadFile(d.eventsPath()); string(after) != string(b) {
		t.Fatalf("events.jsonl was written after Shutdown returned:\n%s", after[len(b):])
	}
}

// What follows a turn and tells the clients as the host goes is done when Shutdown
// returns, also with a client that reads nothing (#3828): each line to it waited the
// conn's 5 s, so a workflow's run that told three things outlived Shutdown's wait and
// wrote into a test's folder as it was deleted.
func TestShutdownWaitsForWhatTellsAClientThatReadsNothing(t *testing.T) {
	d, c := start(t, t.TempDir())
	for len(c.out) < cap(c.out) {
		c.out <- ""
	}
	var done atomic.Bool
	d.goAfterTurn("tells as the host goes", func() {
		for !d.going() {
			time.Sleep(time.Millisecond)
		}
		for range 3 {
			Broadcast(d, wire.NotifyWorkflowRemoved, wire.WorkflowRemovedNotification{WorkflowID: "x"})
		}
		done.Store(true)
	})

	d.Shutdown()

	if !done.Load() {
		t.Fatal("what told the clients was not done when Shutdown returned")
	}
}

// endingRaised is whether events.jsonl has the event that says how the agent ended.
func endingRaised(events string, id wire.UUID) bool {
	for _, line := range strings.Split(events, "\n") {
		if strings.Contains(line, string(id)) && (strings.Contains(line, `"agent.stopped"`) || strings.Contains(line, `"agent.failed"`)) {
			return true
		}
	}
	return false
}
