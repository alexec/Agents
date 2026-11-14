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

	"github.com/agentloops-dev/agent-loops/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Bitbucket (#3785): an Atlassian API token with its email, or an access token, is checked
// with Bitbucket, kept, listed, and never given back or logged. Bitbucket has no sign-in page.
func TestConnectingBitbucketWithAToken(t *testing.T) {
	bb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		user, pass, basic := r.BasicAuth()
		ok := (basic && user == "me@example.com" && pass == "bb-secret") || r.Header.Get("Authorization") == "Bearer bb-access"
		if !ok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/2.0/user" {
			fmt.Fprint(w, `{"nickname":"agentstest","display_name":"Agents Test"}`)
			return
		}
		http.NotFound(w, r)
	}))
	defer bb.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.bitbucketHTTP, d.bitbucketAPI = bb.Client(), bb.URL+"/2.0"

	var refused wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 1, "connections/sign-in/token", map[string]any{"provider": "bitbucket", "token": "bb-secret"}), &refused)
	if refused.Error == nil || refused.Connection != nil || strings.Contains(*refused.Error, "bb-secret") || !strings.Contains(*refused.Error, "email") {
		t.Fatalf("an API token without its email: %+v", refused)
	}
	var bad wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 2, "connections/sign-in/token", map[string]any{"provider": "bitbucket", "user": "not an email", "token": "bb-secret"}), &bad)
	if bad.Error == nil || !strings.Contains(*bad.Error, "email") {
		t.Fatalf("not an email: %+v", bad)
	}

	raw := c.call(t, 3, "connections/sign-in/token", map[string]any{"provider": "bitbucket", "user": " me@example.com", "token": " bb-secret\n"})
	if strings.Contains(string(raw), "bb-secret") {
		t.Fatalf("the token went back to the client: %s", raw)
	}
	var made wire.ConnectionTokenAnswer
	json.Unmarshal(raw, &made)
	if made.Error != nil || made.Connection == nil || made.Connection.Provider != wire.ConnectionProviderBitbucket ||
		deref(made.Connection.Login) != "agentstest" || deref(made.Connection.Workspace) != "bitbucket.org" || made.Connection.ExpiresAt != nil {
		t.Fatalf("made: %+v", made)
	}
	kept, ok, _ := file.Get(connections.Bitbucket)
	if !ok || kept.Access != "bb-secret" || kept.User != "me@example.com" || kept.URL != bb.URL+"/2.0/" || kept.Refresh != "" {
		t.Fatalf("kept: %+v", kept)
	}
	var access wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 4, "connections/sign-in/token", map[string]any{"provider": "bitbucket", "token": "bb-access"}), &access)
	if access.Connection == nil {
		t.Fatalf("an access token: %+v", access)
	}
	if again, _, _ := file.Get(connections.Bitbucket); again.Access != "bb-access" || again.User != "" {
		t.Fatalf("an access token replaces the API token: %+v", again)
	}
	var list wire.ConnectionsList
	json.Unmarshal(c.call(t, 5, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 1 || list.Connections[0].Provider != wire.ConnectionProviderBitbucket {
		t.Fatalf("list: %+v", list)
	}
	if msg := c.callErr(t, 6, "connections/sign-in", map[string]any{"provider": "bitbucket"}); !strings.Contains(msg, "token") {
		t.Fatalf("a Bitbucket sign-in page: %s", msg)
	}
	// A token with no refresh is not renewed, and stays.
	d.renewConnections()
	if again, ok, _ := file.Get(connections.Bitbucket); !ok || again.SignInAgain || again.Access != "bb-access" {
		t.Fatalf("after a renewal: %+v", again)
	}
	c.call(t, 7, "connections/disconnect", map[string]any{"provider": "bitbucket"})
	if _, ok, _ := file.Get(connections.Bitbucket); ok {
		t.Fatal("still kept after disconnect")
	}
}

// fakeSetupBitbucket answers a Bitbucket set-up's reads (#3785); offTracker makes the issues
// read a tracker that is off, refuse makes the checks read a 403.
type fakeSetupBitbucket struct {
	mu         sync.Mutex
	reads      int
	offTracker bool
	refuse     bool
}

func (f *fakeSetupBitbucket) read() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
}

func (f *fakeSetupBitbucket) NewestIssue(ctx context.Context, repo string) (*bitbucketmcp.Newest, error) {
	f.read()
	f.mu.Lock()
	off := f.offTracker
	f.mu.Unlock()
	if off {
		return nil, &bitbucketmcp.NoTrackerError{Repo: repo}
	}
	return &bitbucketmcp.Newest{Number: 4, Title: "Walk the sheet", URL: "https://bitbucket.org/" + repo + "/issues/4", At: "2026-11-07T10:00:00Z"}, nil
}

func (f *fakeSetupBitbucket) NewestPull(ctx context.Context, repo string) (*bitbucketmcp.Newest, error) {
	f.read()
	return &bitbucketmcp.Newest{Number: 5, Title: "Add a README", At: "2026-11-07T10:00:00Z"}, nil
}

func (f *fakeSetupBitbucket) LastChecks(ctx context.Context, repo string) (*bitbucketmcp.Newest, error) {
	f.read()
	if f.refuse {
		return nil, &bitbucketmcp.BitbucketError{Kind: bitbucketmcp.Failed, Message: "Bitbucket: HTTP 403", Refused: true}
	}
	return &bitbucketmcp.Newest{Title: "Checks on main", Outcome: "passed", At: "2026-11-07T10:00:00Z"}, nil
}

// A Bitbucket folder (#3785): its bitbucket.org remote picks Bitbucket, the connection fills
// the three slots with the email it was made with, each proved by one read, a tracker that is
// off says so, and the bitbucket connector's events go on.
func TestABitbucketFoldersConnectorSetUp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	bb := &fakeSetupBitbucket{refuse: true}
	d.newBitbucketSetupReader = func(root, email, token string) bitbucketSetupReader {
		if root != connections.BitbucketAPI || email != "me@example.com" || token != "bb-secret" {
			t.Errorf("Bitbucket %q email %q token %q", root, email, token)
		}
		return bb
	}
	d.newSetupReader = func(string) setupReader {
		t.Error("GitHub was read for a Bitbucket folder")
		return &fakeSetupGitHub{}
	}
	d.newForgejoSetupReader = func(string, string) forgejoSetupReader {
		t.Error("Forgejo was read for a Bitbucket folder")
		return &fakeSetupForgejo{}
	}
	folder := gitFolder(t, "git@bitbucket.org:agentstest/agents-walk.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	slots := slotsByKind(setup)
	if setup.Forge == nil || *setup.Forge != wire.ConnectionProviderBitbucket || deref(setup.Site) != "bitbucket.org" ||
		deref(setup.Repository) != "agentstest/agents-walk" || deref(setup.RepositoryURL) != "https://bitbucket.org/agentstest/agents-walk" ||
		setup.InstallURL != nil || slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindCodeReview].Choice != "Bitbucket pull requests" || bb.reads != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	file.Put(connections.BitbucketConnection(connections.BitbucketAPI, "me@example.com", "bb-secret", "agentstest", time.Now()))
	raw := c.call(t, 3, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"})
	if strings.Contains(string(raw), "bb-secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &setup)
	slots = slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if tasks.State != wire.ConnectorSlotStateRead || tasks.Proof == nil || *tasks.Proof.Number != 4 ||
		review.State != wire.ConnectorSlotStateRead || ci.Choice != "Bitbucket checks" {
		t.Fatalf("tasks %+v review %+v", tasks, review)
	}
	if ci.State != wire.ConnectorSlotStateRefused || ci.Message == nil || *ci.Message != "Bitbucket refused: Agent Loops can't see checks in agentstest/agents-walk." {
		t.Fatalf("ci: %+v", ci)
	}
	if setup.Connection == nil || setup.Connection.Provider != wire.ConnectionProviderBitbucket {
		t.Fatalf("connected: %+v", setup)
	}
	if setup.Events.State != wire.ConnectorEventsStateOn || deref(setup.Events.Server) != "bitbucket" {
		t.Fatalf("events: %+v", setup.Events)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json")); !strings.Contains(string(b), "bitbucket-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}

	bb.mu.Lock()
	bb.offTracker = true
	bb.mu.Unlock()
	json.Unmarshal(c.call(t, 4, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	if tasks := slotsByKind(setup)[wire.ConnectorSlotKindTasks]; tasks.State != wire.ConnectorSlotStateFailed || tasks.Message == nil ||
		!strings.HasPrefix(*tasks.Message, "agentstest/agents-walk has its issue tracker off.") {
		t.Fatalf("a tracker that is off: %+v", tasks)
	}
}

// A connection to a fake Bitbucket's API (a walk's) is used for a bitbucket.org remote and a
// project's Bitbucket slot, and Bitbucket comes before a Forgejo remote but after GitHub.
func TestABitbucketRemoteAtTheConnectionsAPI(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ctx := context.Background()

	folder := gitFolder(t, "https://alex@bitbucket.org/team/app.git")
	if f, _, connected := d.forgeAt(ctx, folder); f.provider != wire.ConnectionProviderBitbucket || f.root != connections.BitbucketAPI ||
		f.repo != "team/app" || f.site != "bitbucket.org" || connected {
		t.Fatalf("before connecting: %+v %v", f, connected)
	}
	fake := "http://127.0.0.1:3785/2.0/"
	file.Put(connections.BitbucketConnection(fake, "", "bb-access", "agentstest", time.Now()))
	if f, c, connected := d.forgeAt(ctx, folder); f.root != fake || !connected || c.Access != "bb-access" {
		t.Fatalf("connected to a fake: %+v %v", f, connected)
	}
	bitbucket, repo := wire.ConnectionProviderBitbucket, "team/app"
	f := d.atConnectedRoot(projectForge(wire.ProjectSlot{Slot: wire.ConnectorSlotKindCi, Forge: &bitbucket, Repository: &repo}))
	if c, ok := d.connectionFor(f); f.site != "bitbucket.org" || f.root != fake || !ok || c.Access != "bb-access" {
		t.Fatalf("a project's slot: %+v %v", f, ok)
	}
	if f, _, _ := d.forgeAt(ctx, gitFolder(t, "git@github.com:team/app.git")); f.provider != wire.ConnectionProviderGithub {
		t.Fatalf("GitHub first: %+v", f)
	}
}
