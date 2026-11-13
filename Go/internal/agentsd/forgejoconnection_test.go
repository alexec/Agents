package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/internal/forgejomcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A Forgejo (#3752): an access token is checked with that Forgejo, kept with its address,
// listed with its host, and never given back or logged. Forgejo has no sign-in page.
func TestConnectingForgejoWithAnAccessToken(t *testing.T) {
	fj := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "token fj-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `{"message":"user does not exist"}`)
			return
		}
		if r.URL.Path == "/api/v1/user" {
			fmt.Fprint(w, `{"id":2,"login":"agentstest"}`)
			return
		}
		http.NotFound(w, r)
	}))
	defer fj.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.forgejoHTTP = fj.Client()

	var refused wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 1, "connections/sign-in/token", map[string]any{"provider": "forgejo", "url": fj.URL, "token": "fj-wrong"}), &refused)
	if refused.Error == nil || refused.Connection != nil || strings.Contains(*refused.Error, "fj-wrong") || !strings.Contains(*refused.Error, "did not take") {
		t.Fatalf("a wrong token: %+v", refused)
	}
	var plain wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 2, "connections/sign-in/token", map[string]any{"provider": "forgejo", "url": "http://git.example.com", "token": "fj-secret"}), &plain)
	if plain.Error == nil || !strings.Contains(*plain.Error, "https://") {
		t.Fatalf("a token over http: %+v", plain)
	}

	raw := c.call(t, 3, "connections/sign-in/token", map[string]any{"provider": "forgejo", "url": fj.URL + "/api/v1", "token": " fj-secret\n"})
	if strings.Contains(string(raw), "fj-secret") {
		t.Fatalf("the token went back to the client: %s", raw)
	}
	var made wire.ConnectionTokenAnswer
	json.Unmarshal(raw, &made)
	host := strings.TrimPrefix(fj.URL, "http://")
	if made.Error != nil || made.Connection == nil || made.Connection.Provider != wire.ConnectionProviderForgejo ||
		deref(made.Connection.Login) != "agentstest" || deref(made.Connection.Workspace) != host || made.Connection.ExpiresAt != nil {
		t.Fatalf("made: %+v", made)
	}
	kept, ok, _ := file.Get(connections.Forgejo)
	if !ok || kept.Access != "fj-secret" || kept.URL != fj.URL+"/" || kept.Refresh != "" {
		t.Fatalf("kept: %+v", kept)
	}
	var list wire.ConnectionsList
	json.Unmarshal(c.call(t, 4, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 1 || list.Connections[0].Provider != wire.ConnectionProviderForgejo {
		t.Fatalf("list: %+v", list)
	}
	if msg := c.callErr(t, 5, "connections/sign-in", map[string]any{"provider": "forgejo"}); !strings.Contains(msg, "access token") {
		t.Fatalf("a Forgejo sign-in page: %s", msg)
	}
	// A token that does not end is not renewed, and stays.
	d.renewConnections()
	if again, ok, _ := file.Get(connections.Forgejo); !ok || again.SignInAgain || again.Access != "fj-secret" {
		t.Fatalf("after a renewal: %+v", again)
	}
	c.call(t, 6, "connections/disconnect", map[string]any{"provider": "forgejo"})
	if _, ok, _ := file.Get(connections.Forgejo); ok {
		t.Fatal("still kept after disconnect")
	}
}

// fakeSetupForgejo answers a Forgejo set-up's reads (#3752); refuse makes the checks read a 403.
type fakeSetupForgejo struct {
	mu     sync.Mutex
	reads  int
	refuse bool
}

func (f *fakeSetupForgejo) read() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
}

func (f *fakeSetupForgejo) NewestIssue(ctx context.Context, repo string) (*forgejomcp.Newest, error) {
	f.read()
	return &forgejomcp.Newest{Number: 4, Title: "Walk the sheet", URL: "https://codeberg.org/" + repo + "/issues/4", At: "2026-11-06T10:00:00Z"}, nil
}

func (f *fakeSetupForgejo) NewestPull(ctx context.Context, repo string) (*forgejomcp.Newest, error) {
	f.read()
	return &forgejomcp.Newest{Number: 5, Title: "Add a README", At: "2026-11-06T10:00:00Z"}, nil
}

func (f *fakeSetupForgejo) LastChecks(ctx context.Context, repo string) (*forgejomcp.Newest, error) {
	f.read()
	if f.refuse {
		return nil, &forgejomcp.ForgejoError{Kind: forgejomcp.Failed, Message: "Forgejo: HTTP 403", Refused: true}
	}
	return &forgejomcp.Newest{Title: "Checks on main", Outcome: "passed", At: "2026-11-06T10:00:00Z"}, nil
}

// A Forgejo folder (#3752): its remote picks Forgejo, the Forgejo connection fills the three
// slots, each proved by one read, the forgejo connector's events go on, and a connection to
// another Forgejo is not used here.
func TestAForgejoFoldersConnectorSetUp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	fj := &fakeSetupForgejo{refuse: true}
	d.newForgejoSetupReader = func(root, token string) forgejoSetupReader {
		if root != connections.Codeberg || token != "fj-secret" {
			t.Errorf("Forgejo %q token %q", root, token)
		}
		return fj
	}
	d.newSetupReader = func(string) setupReader {
		t.Error("GitHub was read for a Forgejo folder")
		return &fakeSetupGitHub{}
	}
	d.newGitLabSetupReader = func(string, string) gitlabSetupReader {
		t.Error("GitLab was read for a Forgejo folder")
		return &fakeSetupGitLab{}
	}
	folder := gitFolder(t, "git@codeberg.org:agentstest/agents-walk.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	slots := slotsByKind(setup)
	if setup.Forge == nil || *setup.Forge != wire.ConnectionProviderForgejo || deref(setup.Site) != "codeberg.org" ||
		deref(setup.Repository) != "agentstest/agents-walk" || deref(setup.RepositoryURL) != "https://codeberg.org/agentstest/agents-walk" ||
		setup.InstallURL != nil || slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindTasks].Choice != "Forgejo issues" || fj.reads != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	// A connection to another Forgejo is not sent to codeberg.org.
	file.Put(connections.Connection{Provider: connections.Forgejo, Login: "agentstest", Access: "fj-other",
		URL: "https://git.example.com/", Workspace: "git.example.com", ConnectedAt: time.Now()})
	json.Unmarshal(c.call(t, 3, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	if setup.Connection != nil || fj.reads != 0 || slotsByKind(setup)[wire.ConnectorSlotKindCi].State != wire.ConnectorSlotStateNotConnected {
		t.Fatalf("another Forgejo's connection: %+v", setup)
	}

	file.Put(connections.ForgejoConnection(connections.Codeberg, "fj-secret", "agentstest", time.Now()))
	raw := c.call(t, 4, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"})
	if strings.Contains(string(raw), "fj-secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &setup)
	slots = slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if tasks.State != wire.ConnectorSlotStateRead || tasks.Proof == nil || *tasks.Proof.Number != 4 ||
		review.State != wire.ConnectorSlotStateRead || review.Choice != "Forgejo pull requests" {
		t.Fatalf("tasks %+v review %+v", tasks, review)
	}
	if ci.State != wire.ConnectorSlotStateRefused || ci.Message == nil || *ci.Message != "Forgejo refused: Agents can't see checks in agentstest/agents-walk." {
		t.Fatalf("ci: %+v", ci)
	}
	if setup.Done != 5 || setup.Connection == nil || setup.Connection.Provider != wire.ConnectionProviderForgejo || setup.Installed != nil {
		t.Fatalf("connected: %+v", setup)
	}
	if setup.Events.State != wire.ConnectorEventsStateOn || deref(setup.Events.Server) != "forgejo" {
		t.Fatalf("events: %+v", setup.Events)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json")); !strings.Contains(string(b), "forgejo-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}
}

// Forgejo of one's own (#3752): a remote on the connected Forgejo picks it, as does a host
// named gitea before it is connected; a GitHub remote still comes first.
func TestAForgejoRemoteOfOnesOwn(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ctx := context.Background()

	gitea := gitFolder(t, "https://gitea.example.org/team/app.git")
	if f, _, connected := d.forgeAt(ctx, gitea); f.provider != wire.ConnectionProviderForgejo || f.root != "https://gitea.example.org/" ||
		f.repo != "team/app" || f.site != "gitea.example.org" || connected {
		t.Fatalf("a gitea host: %+v %v", f, connected)
	}
	own := gitFolder(t, "ssh://git@git.example.com:2222/team/app.git")
	if f, _, _ := d.forgeAt(ctx, own); f.provider != wire.ConnectionProviderGithub {
		t.Fatalf("an unknown host before connecting: %+v", f)
	}
	file.Put(connections.ForgejoConnection("https://git.example.com/", "fj-secret", "agentstest", time.Now()))
	if f, c, connected := d.forgeAt(ctx, own); f.provider != wire.ConnectionProviderForgejo || f.repo != "team/app" ||
		!connected || c.Access != "fj-secret" {
		t.Fatalf("the connected Forgejo: %+v %v", f, connected)
	}
	if f, _, connected := d.forgeAt(ctx, gitea); f.provider != wire.ConnectionProviderForgejo || connected {
		t.Fatalf("the connection went to another Forgejo: %+v %v", f, connected)
	}
}

// A project's slot on Forgejo (#3752) keeps only the host: on the connected Forgejo's host it
// is read at the connection's own root, http on this machine as well.
func TestAProjectsForgejoSlotUsesTheConnectionsRoot(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	forgejo, repo, site := wire.ConnectionProviderForgejo, "team/app", "localhost:3752"
	f := projectForge(wire.ProjectSlot{Slot: wire.ConnectorSlotKindCi, Forge: &forgejo, Repository: &repo, Site: &site})
	if f.root != "https://localhost:3752/" {
		t.Fatalf("before connecting: %+v", f)
	}
	file.Put(connections.ForgejoConnection("http://localhost:3752/", "fj-secret", "agentstest", time.Now()))
	f = d.atConnectedRoot(f)
	if c, ok := d.connectionFor(f); f.root != "http://localhost:3752/" || !ok || c.Access != "fj-secret" {
		t.Fatalf("connected: %+v %v", f, ok)
	}
	other := "git.example.com"
	if g := d.atConnectedRoot(projectForge(wire.ProjectSlot{Forge: &forgejo, Repository: &repo, Site: &other})); g.root != "https://git.example.com/" {
		t.Fatalf("another site: %+v", g)
	}
}
