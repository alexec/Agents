package agentsd

import (
	"context"
	"encoding/json"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/wire"
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

// A Forgejo remote is a forge's too (#3882): a session labelled #n or P#n in a folder that
// pushes to the same Codeberg repo is on it, and one whose folder pushes to another is not.
func TestAgentOnAForgejoRemote(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder, worktree, other := t.TempDir(), t.TempDir(), t.TempDir()
	for dir, remote := range map[string]string{
		folder:   "https://codeberg.org/alex/shop.git",
		worktree: "git@codeberg.org:alex/shop.git",
		other:    "https://codeberg.org/alex/other.git",
	} {
		gitIn(t, dir, "init", "-q")
		gitIn(t, dir, "remote", "add", "origin", remote)
	}

	title := "Fix the cart totals"
	seeded(t, d, worktree, func(a *wire.Agent) {
		a.Title = &title
		a.Labels = []wire.SessionLabel{{Value: "#7"}, {Value: "P#8"}}
	})
	seeded(t, d, other, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#9"}}
	})

	prs, issues, _ := d.agentOnIt(folder)
	if len(prs) != 1 || prs["8"] != title {
		t.Errorf("prs: %+v", prs)
	}
	if len(issues) != 1 || issues["7"] != title {
		t.Errorf("issues: %+v", issues)
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
		a.Labels = []wire.SessionLabel{{Value: "ENG-4"}, {Value: "AB#12"}}
	})
	byUser := wire.AgentArchivedReasonByUser
	seeded(t, d, folderB, func(a *wire.Agent) {
		a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
		a.Labels = []wire.SessionLabel{{Value: "ENG-9"}}
	})

	_, _, got := d.agentOnIt(folderA)
	if len(got) != 2 || got["ENG-4"] != title || got["AB#12"] != title {
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

// The viewer's own blank Jira login comes from this machine's Atlassian connection (#3313), as
// a blank Linear login comes from its Linear one; another person's login is theirs as kept.
func TestTeamPeopleFillsTheViewersJiraLoginFromTheAtlassianConnection(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	file.Put(connections.Connection{Provider: atlassianConnection, Login: "Alex Collins", Access: "atl",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	you, sam := true, "sam@example.com"
	ask := askControl(func(context.Context, string, any) (json.RawMessage, error) {
		return json.Marshal(wire.PeopleForViews{People: []wire.TeamPerson{
			{ID: "a", Name: "Alex", Kind: "person", You: &you},
			{ID: "s", Name: "Sam", Kind: "person", JiraLogin: &sam},
		}})
	})
	people := d.teamPeople(context.Background(), &ask)
	if len(people) != 2 || people[0]["jira"] != "Alex Collins" || people[1]["jira"] != sam {
		t.Fatalf("people: %+v", people)
	}
}

// The viewer's own blank Forgejo login comes from this machine's Forgejo connection (#3836);
// another person's login is theirs as kept.
func TestTeamPeopleFillsTheViewersForgejoLoginFromTheForgejoConnection(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	file.Put(connections.Connection{Provider: connections.Forgejo, Login: "alex", Access: "fj", ConnectedAt: time.Now()})
	you, sam := true, "sam"
	ask := askControl(func(context.Context, string, any) (json.RawMessage, error) {
		return json.Marshal(wire.PeopleForViews{People: []wire.TeamPerson{
			{ID: "a", Name: "Alex", Kind: "person", You: &you},
			{ID: "s", Name: "Sam", Kind: "person", ForgejoLogin: &sam},
		}})
	})
	people := d.teamPeople(context.Background(), &ask)
	if len(people) != 2 || people[0]["forgejo"] != "alex" || people[1]["forgejo"] != sam {
		t.Fatalf("people: %+v", people)
	}
}

// The viewer's own blank Bitbucket and Azure DevOps logins come from this machine's Bitbucket
// and Azure DevOps connections (#3853); another person's logins are theirs as kept.
func TestTeamPeopleFillsTheViewersBitbucketAndAzureDevOpsLoginsFromTheConnections(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	file.Put(connections.Connection{Provider: connections.Bitbucket, Login: "alex-bb", Access: "bb", ConnectedAt: time.Now()})
	file.Put(connections.Connection{Provider: connections.AzureDevOps, Login: "Alex Collins", Access: "ado", ConnectedAt: time.Now()})
	you, sam, samADO := true, "sam", "sam@example.com"
	ask := askControl(func(context.Context, string, any) (json.RawMessage, error) {
		return json.Marshal(wire.PeopleForViews{People: []wire.TeamPerson{
			{ID: "a", Name: "Alex", Kind: "person", You: &you},
			{ID: "s", Name: "Sam", Kind: "person", BitbucketLogin: &sam, AzureDevOpsLogin: &samADO},
		}})
	})
	people := d.teamPeople(context.Background(), &ask)
	if len(people) != 2 || people[0]["bitbucket"] != "alex-bb" || people[0]["azuredevops"] != "Alex Collins" ||
		people[1]["bitbucket"] != sam || people[1]["azuredevops"] != samADO {
		t.Fatalf("people: %+v", people)
	}
}
