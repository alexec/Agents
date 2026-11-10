package controlplane

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The page asks for a step of a move of the control plane (#4255): the Mac's window is told
// it, not the browser, and how the window says it stands reaches the page. Any control plane
// relays it, as the copy elsewhere carries Run It Here Again… after a move.
func TestThePageAsksTheMacWindowToMoveTheControlPlane(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	page := p.clientOfKind("browser", records.KindBrowser)
	if got := callError(t, page, "", "control/planeMove", map[string]any{"action": "status"}); !strings.Contains(got, "isn’t open on the Mac") {
		t.Fatalf("with no window: %s", got)
	}
	window := p.clientOfKind("Mac", records.KindMac)
	call(t, window, "", "control/status", nil)
	call(t, page, "", "control/planeMove", map[string]any{"action": "check", "address": "https://agents.example.com"})
	var want wire.PlaneMoveAsk
	if err := json.Unmarshal(waitNote(t, window, wire.NotifyControlPlaneMoveWanted.Name).Params, &want); err != nil {
		t.Fatal(err)
	}
	if want.Action != wire.PlaneMoveActionCheck || want.Address == nil || *want.Address != "https://agents.example.com" {
		t.Fatalf("the window was told %+v", want)
	}
	report := map[string]any{"mac": "Alex's Mac", "rows": []map[string]any{{"kind": "move", "title": "Move to Another Machine", "detail": "To a server you run."}}}
	if got := callError(t, page, "", "control/planeMoveReport", report); !strings.Contains(got, "Only Agents on a Mac") {
		t.Fatalf("a browser reports: %s", got)
	}
	call(t, window, "", "control/planeMoveReport", report)
	var heard wire.PlaneMoveReport
	if err := json.Unmarshal(waitNote(t, page, wire.NotifyControlPlaneMoveReported.Name).Params, &heard); err != nil {
		t.Fatal(err)
	}
	if heard.Mac != "Alex's Mac" || len(heard.Rows) != 1 || heard.Rows[0].Kind != "move" {
		t.Fatalf("the page heard %+v", heard)
	}
}
