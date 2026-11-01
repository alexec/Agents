package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A bot's machine (#1761, FR-032, FR-034): told it is a bot's, it matches runs-on: by the
// bot's name, its os and its provider, keeps that over a restart, offers no ask tools,
// claims a runs-on: run before it starts one, and at its cap starts none.
func TestABotsMachineAsksNobodyAndClaimsItsRuns(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	if d.isBot() || !d.runsOnHere(nil) || d.runsOnHere([]string{"review-bot"}) {
		t.Fatal("a person's machine as it starts")
	}
	told, _ := json.Marshal(wire.MachineUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{"do-1"}})
	d.toldHostUser(told)
	if !d.isBot() || !d.runsOnHere([]string{"Review-Bot", osLabel(), "do-1"}) || d.runsOnHere([]string{"review-bot", "windows"}) {
		t.Fatalf("labels %v", d.machineLabels())
	}
	if !d.runsOnHere([]string{d.machineID()}) {
		t.Fatal("its own id")
	}
	// Two machines under Runs on: one of them is enough, and the other labels still all match (#2064).
	other, linux := "6F1C2E5A-0B7D-4C1E-9A3B-2D4E6F8A0B1C", "0123456789abcdef0123456789abcdef"
	if !d.runsOnHere([]string{other, d.machineID()}) || !d.runsOnHere([]string{"review-bot", d.machineID(), linux}) {
		t.Fatal("one of its machine ids")
	}
	if d.runsOnHere([]string{other, linux}) || d.runsOnHere([]string{d.machineID(), other, "windows"}) {
		t.Fatal("another machine's ids, or a label it lacks")
	}
	if b, err := os.ReadFile(d.hostUserPath()); err != nil || !strings.Contains(string(b), "review-bot") {
		t.Fatalf("%s %v", b, err)
	}
	for _, raw := range offeredTools(false, true, false) {
		if strings.Contains(string(raw), `"ask_question"`) {
			t.Fatal("ask_question offered on a bot's machine")
		}
	}
	found := false
	for _, raw := range offeredTools(false, false, false) {
		found = found || strings.Contains(string(raw), `"ask_question"`)
	}
	if !found {
		t.Fatal("ask_question not offered on a person's machine")
	}

	// Claimed first: a lost claim runs nothing; a won one, or Run now, runs.
	w := wire.Workflow{RunsOn: []string{"review-bot"}}
	if !d.claimsRuns(w) || d.claimsRuns(wire.Workflow{}) {
		t.Fatal("which workflows claim")
	}
	var asked []wire.WorkflowClaim
	won := false
	ask := askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method != wire.CallWorkflowsClaimRun.Name {
			return nil, nil
		}
		asked = append(asked, params.(wire.WorkflowClaim))
		return json.Marshal(wire.WorkflowClaimed{Won: won})
	})
	d.SetControlAsk(ask)
	e := wire.Event{Name: "pr.opened", Details: map[string]string{"pr": "412", "repo": "a/b"}}
	same := wire.Event{Name: "pr.opened", Details: map[string]string{"repo": "a/b", "pr": "412"}, Position: 99}
	if triggerID(fireRequest{}, &e) != triggerID(fireRequest{}, &same) || triggerID(fireRequest{}, nil) != "" {
		t.Fatal("a trigger's id is its event's name and details only")
	}
	if d.claimRun("/work/app", "review", triggerID(fireRequest{}, &e)) {
		t.Fatal("a lost claim ran")
	}
	won = true
	if !d.claimRun("/Users/b/src/app", "review", triggerID(fireRequest{}, &e)) || len(asked) != 2 || asked[0] != asked[1] {
		t.Fatalf("%+v", asked)
	}

	// At its cap, until the end of the day.
	until := wire.DateOf(time.Now().Add(time.Hour))
	told, _ = json.Marshal(wire.MachineUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{}, CapReachedUntil: &until})
	d.toldHostUser(told)
	if _, capped := d.capped(time.Now()); !capped {
		t.Fatal("not capped")
	}
	if _, capped := d.capped(time.Now().Add(2 * time.Hour)); capped {
		t.Fatal("capped past its end")
	}
}
