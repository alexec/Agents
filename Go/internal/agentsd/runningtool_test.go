package agentsd

import (
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The sidebars' running tool (#1902): a tool that holds is shown by its title, one that
// ends at once never is, and the turn goes back to thinking once none is in flight.

func TestARunningToolShowsOnlyOnceItHolds(t *testing.T) {
	old := toolSettle
	toolSettle = 50 * time.Millisecond
	t.Cleanup(func() { toolSettle = old })
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
