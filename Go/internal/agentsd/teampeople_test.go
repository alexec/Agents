package agentsd

import (
	"testing"

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

	prs, issues := d.agentOnByNumber(folder)
	if len(prs) != 1 || prs["40"] != title {
		t.Errorf("prs: %+v", prs)
	}
	if len(issues) != 1 || issues["12"] != title {
		t.Errorf("issues: %+v", issues)
	}

	if prs, issues := d.agentOnByNumber(t.TempDir()); len(prs) != 0 || len(issues) != 0 {
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

	got := d.agentOnByLinearKey()
	if len(got) != 1 || got["ENG-4"] != title {
		t.Errorf("got %+v", got)
	}
}
