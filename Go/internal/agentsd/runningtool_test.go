package agentsd

import (
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The sidebars' running tool (#1902): a tool that holds is shown by its title, one that
// ends at once never is, and the turn goes back to thinking once none is in flight.

func TestARunningToolShowsOnlyOnceItHolds(t *testing.T) {
	oldSettle, oldHold := toolSettle, markHold
	toolSettle, markHold = 50*time.Millisecond, 0
	t.Cleanup(func() { toolSettle, markHold = oldSettle, oldHold })
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	l := d.live(a.ID)
	tool := func(id, title, status string) wire.ToolCall {
		return wire.ToolCall{ToolCallID: &id, Title: title, Status: &status}
	}
	shown := func() string {
		if r := d.Store.Agent(a.ID).RunningTool; r != nil {
			return *r
		}
		return ""
	}

	// Begun and ended inside the settle: never shown.
	l.noteToolCall(tool("1", "ls", "pending"), true)
	l.noteToolCall(tool("1", "ls", "completed"), false)
	time.Sleep(3 * toolSettle)
	if s := shown(); s != "" {
		t.Fatalf("a tool that ended at once was shown: %q", s)
	}

	// One that holds: shown, by its title, once the settle has passed.
	l.noteToolCall(tool("2", "swift test", "in_progress"), true)
	if s := shown(); s != "" {
		t.Fatalf("shown before it held: %q", s)
	}
	waitFor(t, "the tool shown", func() bool { return shown() == "swift test" })

	// A second one begun meanwhile is the newest; the first ending leaves it.
	l.noteToolCall(tool("3", "git status", "pending"), true)
	l.noteToolCall(tool("2", "swift test", "completed"), false)
	waitFor(t, "the newest tool shown", func() bool { return shown() == "git status" })

	// None in flight: thinking again, after the settle.
	l.noteToolCall(tool("3", "git status", "failed"), false)
	waitFor(t, "thinking again", func() bool { return shown() == "" })
}

// The mark holds (#2046): once it changes between thinking and a tool, it stays for
// markHold before it can change back, but a new title on the same mark waits only for
// the settle, and a change undone inside the hold never shows.
func TestTheMarkHoldsBeforeItChangesBack(t *testing.T) {
	oldSettle, oldHold := toolSettle, markHold
	toolSettle, markHold = 20*time.Millisecond, 400*time.Millisecond
	t.Cleanup(func() { toolSettle, markHold = oldSettle, oldHold })
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	l := d.live(a.ID)
	tool := func(id, title, status string) wire.ToolCall {
		return wire.ToolCall{ToolCallID: &id, Title: title, Status: &status}
	}
	shown := func() string {
		if r := d.Store.Agent(a.ID).RunningTool; r != nil {
			return *r
		}
		return ""
	}

	// The first tool shows after the settle alone: nothing has held the mark yet.
	began := time.Now()
	l.noteToolCall(tool("1", "ls", "in_progress"), true)
	waitFor(t, "the first tool shown", func() bool { return shown() == "ls" })

	// Another title on the same mark: after the settle, not the hold.
	l.noteToolCall(tool("2", "make", "in_progress"), true)
	l.noteToolCall(tool("1", "ls", "completed"), false)
	waitFor(t, "the new title shown", func() bool { return shown() == "make" })
	if time.Since(began) >= markHold {
		t.Fatalf("a new title waited for the hold")
	}

	// Thinking inside the hold: it waits until the hold has passed.
	l.noteToolCall(tool("2", "make", "completed"), false)
	time.Sleep(4 * toolSettle)
	if s := shown(); s != "make" {
		t.Fatalf("the mark changed inside the hold: %q", s)
	}
	waitFor(t, "thinking after the hold", func() bool { return shown() == "" })
	if time.Since(began) < markHold {
		t.Fatalf("thinking shown %v after the tool, before the %v hold", time.Since(began), markHold)
	}
	thought := time.Now()

	// A tool that ends inside the hold, after its settle, never shows.
	l.noteToolCall(tool("3", "git status", "in_progress"), true)
	time.Sleep(4 * toolSettle)
	l.noteToolCall(tool("3", "git status", "completed"), false)
	time.Sleep(markHold - time.Since(thought) + 4*toolSettle)
	if s := shown(); s != "" {
		t.Fatalf("a tool undone inside the hold was shown: %q", s)
	}
}
