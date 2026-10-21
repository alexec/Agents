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
	told, _ := json.Marshal(wire.HostUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{"do-1"}})
	d.toldHostUser(told)
	if !d.isBot() || !d.runsOnHere([]string{"Review-Bot", osLabel(), "do-1"}) || d.runsOnHere([]string{"review-bot", "windows"}) {
		t.Fatalf("labels %v", d.machineLabels())
	}
	if !d.runsOnHere([]string{d.machineID()}) {
		t.Fatal("its own id")
	}
	if b, err := os.ReadFile(d.hostUserPath()); err != nil || !strings.Contains(string(b), "review-bot") {
		t.Fatalf("%s %v", b, err)
	}
	for _, raw := range offeredTools(false, true) {
		if strings.Contains(string(raw), `"ask_form"`) {
			t.Fatal("ask_form offered on a bot's machine")
		}
	}
	found := false
	for _, raw := range offeredTools(false, false) {
		found = found || strings.Contains(string(raw), `"ask_form"`)
	}
	if !found {
		t.Fatal("ask_form not offered on a person's machine")
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
	told, _ = json.Marshal(wire.HostUser{User: "b1", Kind: "bot", Name: "review-bot", Labels: []string{}, CapReachedUntil: &until})
	d.toldHostUser(told)
	if _, capped := d.capped(time.Now()); !capped {
		t.Fatal("not capped")
	}
	if _, capped := d.capped(time.Now().Add(2 * time.Hour)); capped {
		t.Fatal("capped past its end")
	}
}
