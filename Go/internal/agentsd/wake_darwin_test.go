package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

func TestPMSetIsRead(t *testing.T) {
	battery := "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t18%; discharging; 1:02 remaining present: true\n"
	if r := parsePMSet(battery); r.onMains || r.percent == nil || *r.percent != 18 {
		t.Fatalf("%+v", r)
	}
	if r := parsePMSet("Now drawing from 'AC Power'\n"); !r.onMains || r.percent != nil {
		t.Fatalf("a desktop: %+v", r)
	}
}

// The Mac is held while an agent runs, kept for the grace after, and never for one that is
// only waiting on the person; on battery at the floor it is let go.
func TestTheMacIsHeldWhileAnAgentWorks(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	k := d.awake
	holds := 0
	power := powerReading{onMains: true}
	now := time.Now()
	k.mu.Lock()
	k.readPower = func() powerReading { return power }
	k.startHold = func() *exec.Cmd { holds++; return nil }
	k.now = func() time.Time { return now }
	k.mu.Unlock()
	state := func() wire.WakeState {
		var s wire.WakeState
		json.Unmarshal(c.call(t, int(now.UnixNano()%1e6), "wake/state", nil), &s)
		return s
	}

	waiting := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateWaitingOnUser, nil })
	k.revise(true)
	if s := state(); s.IsHolding || holds != 0 {
		t.Fatalf("held for an agent waiting on the person: %+v", s)
	}
	running := *d.Store.Agent(waiting.ID)
	running.State = wire.AgentStateRunning
	d.Store.Save(running)
	k.revise(true)
	if s := state(); !s.IsHolding || s.AgentsInFlight != 1 || s.Since == nil || holds != 1 {
		t.Fatalf("not held for a running agent: %+v (%d)", s, holds)
	}
	// It stops: the grace keeps the hold, an hour by default.
	running.State, running.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
	d.Store.Save(running)
	k.revise(true)
	if s := state(); !s.IsHolding || s.GraceUntil == nil || s.AgentsInFlight != 0 {
		t.Fatalf("no grace: %+v", s)
	}
	now = now.Add(61 * time.Minute)
	k.revise(true)
	if s := state(); s.IsHolding {
		t.Fatalf("held past the grace: %+v", s)
	}
	// On battery at the floor, a running agent does not hold it.
	running.State, running.EndedReason = wire.AgentStateRunning, nil
	d.Store.Save(running)
	pct := int64(20)
	power = powerReading{percent: &pct}
	k.revise(true)
	if s := state(); s.IsHolding || !s.HeldBackByBattery || s.BatteryPercent == nil || *s.BatteryPercent != 20 {
		t.Fatalf("held at the floor: %+v", s)
	}
	// Off is never held.
	power = powerReading{onMains: true}
	var settings wire.WakeSettings
	json.Unmarshal(c.call(t, 90, "wake/set", map[string]any{"keepsAwake": false, "graceHours": 12, "warmRuntimes": 3, "awakeOnPower": false}), &settings)
	if s := state(); s.IsHolding || settings.GraceHours != 8 {
		t.Fatalf("held while off: %+v %+v", s, settings)
	}
	if b, err := os.ReadFile(d.Store.Loc.Root + "/wake.json"); err != nil || !json.Valid(b) {
		t.Fatalf("wake.json: %v", err)
	}
}
