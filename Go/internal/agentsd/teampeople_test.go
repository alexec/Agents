package agentsd

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// "An agent is on it" (#2951): a non-archived session labelled #n or P#n, in a folder
// whose repo is the one asked about, by number; an archived session is not on it any
// more, and a label in another repo's folder does not match.
func TestAgentOnByNumber(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	other := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}, other: {"github", "alexec/other"}}

	title := "Fix the cart totals"
	seeded(t, d, folder, func(a *wire.Agent) {
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "#12"}, {Value: "P#40"}}
	})
	byUser := wire.AgentArchivedReasonByUser
	seeded(t, d, folder, func(a *wire.Agent) {
		a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
		a.Labels = []wire.SessionLabel{{Value: "#99"}}
	})
	seeded(t, d, other, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12"}}
	})

	prs, issues, _ := d.agentOnIt(folder)
	if len(prs) != 1 || prs["40"] != title {
		t.Errorf("prs: %+v", prs)
	}
	if len(issues) != 1 || issues["12"] != title {
		t.Errorf("issues: %+v", issues)
	}

	if prs, issues, _ := d.agentOnIt(t.TempDir()); len(prs) != 0 || len(issues) != 0 {
		t.Errorf("a folder with no repo: %+v %+v", prs, issues)
	}
}

// A Linear key is not one folder's own: a session labelled one is on it whichever
// folder it is in.
func TestAgentOnByLinearKey(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folderA, folderB := t.TempDir(), t.TempDir()

	title := "Fix the totals"
	seeded(t, d, folderA, func(a *wire.Agent) {
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "ENG-4"}}
	})
	byUser := wire.AgentArchivedReasonByUser
	seeded(t, d, folderB, func(a *wire.Agent) {
		a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
		a.Labels = []wire.SessionLabel{{Value: "ENG-9"}}
	})

	_, _, got := d.agentOnIt(folderA)
	if len(got) != 1 || got["ENG-4"] != title {
		t.Errorf("got %+v", got)
	}
}

// The people are asked of the control plane once a minute, not on every view call (#3108):
// a call inside the minute is given the kept answer, one after it is given the kept answer
// while a fresh one is asked for, and a new control-plane link asks again at once.
func TestTeamPeopleIsKept(t *testing.T) {
	clock := atTime(t, time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	var asked atomic.Int32
	name := atomic.Value{}
	name.Store("Ann")
	ask := func(_ context.Context, method string, _ any) (json.RawMessage, error) {
		if method != wire.CallPeopleForViews.Name {
			return nil, context.Canceled // askThereWaits, on a new link
		}
		asked.Add(1)
		return json.Marshal(wire.PeopleForViews{People: []wire.TeamPerson{{Name: name.Load().(string), Kind: "person"}}})
	}
	d.SetControlAsk(ask)
	named := func() string {
		list := d.cachedTeamPeople(context.Background())
		if len(list) != 1 {
			t.Fatalf("people: %+v", list)
		}
		return list[0]["name"].(string)
	}

	if got := named(); got != "Ann" || asked.Load() != 1 {
		t.Fatalf("first: %s, asked %d", got, asked.Load())
	}
	name.Store("Bea")
	clock.add(30 * time.Second)
	if got := named(); got != "Ann" || asked.Load() != 1 {
		t.Fatalf("inside the minute: %s, asked %d", got, asked.Load())
	}
	clock.add(time.Minute)
	if got := named(); got != "Ann" {
		t.Fatalf("stale is still given: %s", got)
	}
	deadline := time.Now().Add(5 * time.Second)
	for asked.Load() != 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	for named() != "Bea" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := named(); got != "Bea" || asked.Load() != 2 {
		t.Fatalf("after the refresh: %s, asked %d", got, asked.Load())
	}

	d.SetControlAsk(ask)
	if named(); asked.Load() != 3 {
		t.Fatalf("a new link asks again: asked %d", asked.Load())
	}
	d.SetControlAsk(nil)
	if list := d.cachedTeamPeople(context.Background()); list != nil {
		t.Fatalf("no control plane: %+v", list)
	}
}
