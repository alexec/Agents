package agentsd

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports TimeLedgerTests: a turn's time is cut where what it waits on changes, banked by
// the hour when it ends, and the day says how many agents worked.

func TestATurnsTimeBySegment(t *testing.T) {
	at := time.Date(2026, 10, 16, 9, 59, 0, 0, time.Local)
	sec := func(n int) time.Time { return at.Add(time.Duration(n) * time.Second) }
	marks := []timeMark{
		{kind: markState, state: wire.AgentStateRunning, at: sec(0)},
		{kind: markToolStarted, id: "a", name: "Bash", at: sec(10)},
		{kind: markToolEnded, id: "a", at: sec(30)},
		{kind: markToolStarted, id: "w", name: "mcp__agents__wait_for_event", at: sec(40)},
		{kind: markAskOpened, id: "permission", at: sec(50)},
		{kind: markAskClosed, id: "permission", at: sec(70)},
		{kind: markToolEnded, id: "w", at: sec(100)},
		{kind: markState, state: wire.AgentStateFinished, at: sec(120)},
	}
	segs, carry := splitMarks(marks)
	var got []string
	for _, s := range segs {
		got = append(got, s.kind+":"+s.end.Sub(s.start).String())
	}
	want := []string{"agent:10s", "tools:20s", "agent:10s", "others:10s", "person:20s", "others:30s", "agent:20s"}
	if len(got) != len(want) || carry != nil {
		t.Fatalf("%v %v", got, carry)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%v", got)
		}
	}
	h := wire.TimeHistory{Hours: map[string]map[string]wire.TimeBucket{}, Days: map[string]map[string]wire.TimeBucket{}, Recap: map[string]wire.DayRecap{}}
	addStretch(&h, "agent", sec(0), sec(120), "claude")
	if h.Hours["2026-10-16T09"]["claude"].Agent != 60 || h.Hours["2026-10-16T10"]["claude"].Agent != 60 || h.Days["2026-10-16"]["claude"].Agent != 120 {
		t.Fatalf("%+v", h.Hours)
	}
	// Open at the cut: carried on.
	_, carry = splitMarks(marks[:2])
	if len(carry) != 2 || carry[1].kind != markToolStarted || carry[1].name != "tool" {
		t.Fatalf("%+v", carry)
	}
}

func TestATurnIsBanked(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "hello"}), &id)
	c.until(t, "the turn", ended(id, wire.AgentStateFinished))
	// The state says finished a moment before the entry that banks the turn.
	var h wire.TimeHistory
	day := dayStamp(time.Now())
	waitFor(t, "the turn banked", func() bool {
		h = wire.TimeHistory{}
		json.Unmarshal(c.call(t, 2, "time/history", map[string]any{}), &h)
		return h.Days[day]["claude"].Turns == 1
	})
	if b := h.Days[day]["claude"]; b.Agent+b.Tools <= 0 || h.Recap[day].Agents != 1 || h.Recap[day].PeakAgents != 1 || h.Now == "" {
		t.Fatalf("%+v %+v", h.Days, h.Recap)
	}
	if b, err := os.ReadFile(d.timePath()); err != nil || len(b) == 0 {
		t.Fatal(err)
	}
}
