package agentsd

import (
	"encoding/json"
	"testing"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/wire"
)

// A runtime moving itself to another mode (Claude leaving plan mode, or a config option
// it changed) is the agent's mode now: what a message from a stricter agent is held for,
// and what a helper it starts inherits.

func startedIn(mode string) func(*wire.Agent) {
	return func(a *wire.Agent) {
		inMode(mode)(a)
		v, _ := json.Marshal(mode)
		a.StartOptions = wire.StartOptions{Values: map[string]wire.JSONValue{"mode": v}, ExtraArguments: []string{}}
	}
}

func TestTheModeChecksReadTheModeAnAgentIsInNow(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	lead := seeded(t, d, dir, titledAs("Lead", startedIn("default")))
	planner := seeded(t, d, dir, titledAs("Planner", startedIn("plan")))
	helper := seeded(t, d, dir, titledAs("Helper", startedIn("default")))

	if why := d.looserThan(d.Store.Agent(planner.ID), d.Store.Agent(lead.ID)); why != "" {
		t.Fatal(why)
	}
	// Its plan approved with auto-accept edits: it runs in acceptEdits now.
	d.live(planner.ID).Update(sdk.SessionNotification{Update: sdk.SessionUpdate{CurrentModeUpdate: &sdk.SessionCurrentModeUpdate{CurrentModeId: "acceptEdits"}}})
	if why := d.looserThan(d.Store.Agent(planner.ID), d.Store.Agent(lead.ID)); why != "it runs in acceptEdits, which lets it do more without asking than yours (default)" {
		t.Fatal(why)
	}
	if m := inheritedMode(d.Store.Agent(planner.ID), ""); m == nil || *m != "acceptEdits" {
		t.Fatal(m)
	}

	// A config option it moved itself: a helper it starts now starts in plan.
	var u sdk.SessionConfigOptionUpdate
	if err := json.Unmarshal([]byte(`{"sessionUpdate":"config_option_update","configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"plan","options":[{"value":"plan","name":"Plan"},{"value":"default","name":"Default"}]}]}`), &u); err != nil {
		t.Fatal(err)
	}
	d.live(helper.ID).Update(sdk.SessionNotification{Update: sdk.SessionUpdate{ConfigOptionUpdate: &u}})
	if m := inheritedMode(d.Store.Agent(helper.ID), ""); m == nil || *m != "plan" {
		t.Fatal(m)
	}
	// The runtime moved itself, not the window: said in the transcript the same way
	// CurrentModeUpdate is, not silently (#3082).
	entries, _, _ := d.Store.Transcript(helper.ID, 0)
	var changed *wire.TranscriptEntryKindOptionChanged
	for _, e := range entries {
		if e.Kind.OptionChanged != nil {
			changed = e.Kind.OptionChanged
		}
	}
	if changed == nil || changed.ID != "mode" || string(changed.Value) != `"plan"` {
		t.Fatalf("option changed record: %+v", changed)
	}
}
