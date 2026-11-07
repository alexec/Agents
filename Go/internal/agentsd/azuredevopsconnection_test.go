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

	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// Azure DevOps (#3802): a personal access token is checked with its organization, kept with
// the organization's address, listed, and never given back or logged. Azure DevOps has no
// sign-in page.
func TestConnectingAzureDevOpsWithAToken(t *testing.T) {
	ado := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pass, _ := r.BasicAuth(); pass != "ado-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/acme/_apis/connectionData" {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"authenticatedUser":{"id":"u1","providerDisplayName":"Agents Test"}}`)
			return
		}
		http.NotFound(w, r)
	}))
	defer ado.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.azureDevOpsHTTP = ado.Client()

	var none wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 1, "connections/sign-in/token", map[string]any{"provider": "azuredevops", "token": "ado-secret"}), &none)
	if none.Error == nil || none.Connection != nil || !strings.Contains(*none.Error, "organization") {
		t.Fatalf("no organization: %+v", none)
	}
	var bad wire.ConnectionTokenAnswer
	json.Unmarshal(c.call(t, 2, "connections/sign-in/token", map[string]any{"provider": "azuredevops", "url": ado.URL + "/acme", "token": "ado-wrong"}), &bad)
	if bad.Error == nil || strings.Contains(*bad.Error, "ado-wrong") || !strings.Contains(*bad.Error, "did not take") {
		t.Fatalf("a wrong token: %+v", bad)
	}

	raw := c.call(t, 3, "connections/sign-in/token", map[string]any{"provider": "azuredevops", "url": ado.URL + "/acme/", "token": " ado-secret\n"})
	if strings.Contains(string(raw), "ado-secret") {
		t.Fatalf("the token went back to the client: %s", raw)
	}
	var made wire.ConnectionTokenAnswer
	json.Unmarshal(raw, &made)
	host := strings.TrimPrefix(ado.URL, "http://")
	if made.Error != nil || made.Connection == nil || made.Connection.Provider != wire.ConnectionProviderAzuredevops ||
		deref(made.Connection.Login) != "Agents Test" || deref(made.Connection.Workspace) != host+"/acme" || made.Connection.ExpiresAt != nil {
		t.Fatalf("made: %+v", made)
	}
	kept, ok, _ := file.Get(connections.AzureDevOps)
	if !ok || kept.Access != "ado-secret" || kept.URL != ado.URL+"/" || kept.Resource != "acme" || kept.Refresh != "" {
		t.Fatalf("kept: %+v", kept)
	}
	var list wire.ConnectionsList
	json.Unmarshal(c.call(t, 4, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 1 || list.Connections[0].Provider != wire.ConnectionProviderAzuredevops ||
		!strings.Contains(fmt.Sprint(list.Providers), "azuredevops") {
		t.Fatalf("list: %+v", list)
	}
	if msg := c.callErr(t, 5, "connections/sign-in", map[string]any{"provider": "azuredevops"}); !strings.Contains(msg, "personal access token") {
		t.Fatalf("an Azure DevOps sign-in page: %s", msg)
	}
	// A token with no refresh is not renewed, and stays.
	d.renewConnections()
	if again, ok, _ := file.Get(connections.AzureDevOps); !ok || again.SignInAgain || again.Access != "ado-secret" {
		t.Fatalf("after a renewal: %+v", again)
	}
	c.call(t, 6, "connections/disconnect", map[string]any{"provider": "azuredevops"})
	if _, ok, _ := file.Get(connections.AzureDevOps); ok {
		t.Fatal("still kept after disconnect")
	}
}

// fakeSetupAzureDevOps answers an Azure DevOps set-up's reads (#3802); refuse makes the
// builds read a 403.
type fakeSetupAzureDevOps struct {
	mu     sync.Mutex
	reads  []string
	refuse bool
}

func (f *fakeSetupAzureDevOps) read(repo string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads = append(f.reads, repo)
}

func (f *fakeSetupAzureDevOps) NewestItem(ctx context.Context, repo string) (*azuredevopsmcp.Newest, error) {
	f.read(repo)
	return &azuredevopsmcp.Newest{Number: 12, Title: "Walk the sheet", URL: "https://dev.azure.com/acme/Web/_workitems/edit/12", At: "2026-11-07T10:00:00Z"}, nil
}

func (f *fakeSetupAzureDevOps) NewestPull(ctx context.Context, repo string) (*azuredevopsmcp.Newest, error) {
	f.read(repo)
	return &azuredevopsmcp.Newest{Number: 5, Title: "Add a README", At: "2026-11-07T10:00:00Z"}, nil
}

func (f *fakeSetupAzureDevOps) LastChecks(ctx context.Context, repo string) (*azuredevopsmcp.Newest, error) {
	f.read(repo)
	if f.refuse {
		return nil, &azuredevopsmcp.AzureDevOpsError{Kind: azuredevopsmcp.Failed, Message: "Azure DevOps: HTTP 403: no"}
	}
	return &azuredevopsmcp.Newest{Number: 30, Title: "CI 2026.11.30", Outcome: "passed", At: "2026-11-07T10:00:00Z"}, nil
}

// An Azure DevOps folder (#3802): its dev.azure.com remote picks Azure DevOps, the connection
// fills the three slots, each proved by one read, a refusal says so, and the azuredevops
// connector's events go on.
func TestAnAzureDevOpsFoldersConnectorSetUp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ado := &fakeSetupAzureDevOps{refuse: true}
	d.newAzureDevOpsSetupReader = func(root, token string) azureDevOpsSetupReader {
		if root != azuredevopsmcp.DefaultBase || token != "ado-secret" {
			t.Errorf("Azure DevOps %q token %q", root, token)
		}
		return ado
	}
	d.newSetupReader = func(string) setupReader {
		t.Error("GitHub was read for an Azure DevOps folder")
		return &fakeSetupGitHub{}
	}
	folder := gitFolder(t, "git@ssh.dev.azure.com:v3/acme/Web/app")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	slots := slotsByKind(setup)
	if setup.Forge == nil || *setup.Forge != wire.ConnectionProviderAzuredevops || deref(setup.Site) != "dev.azure.com" ||
		deref(setup.Repository) != "acme/Web/app" || deref(setup.RepositoryURL) != "https://dev.azure.com/acme/Web/_git/app" ||
		setup.InstallURL != nil || slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindTasks].Choice != "Azure Boards work items" || len(ado.reads) != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	file.Put(connections.AzureDevOpsConnection(connections.AzureDevOpsServices, "acme", "ado-secret", "Agents Test", time.Now()))
	raw := c.call(t, 3, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"})
	if strings.Contains(string(raw), "ado-secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &setup)
	slots = slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if tasks.State != wire.ConnectorSlotStateRead || tasks.Proof == nil || *tasks.Proof.Number != 12 ||
		review.State != wire.ConnectorSlotStateRead || review.Choice != "Azure Repos pull requests" || ci.Choice != "Azure Pipelines" {
		t.Fatalf("tasks %+v review %+v", tasks, review)
	}
	if ci.State != wire.ConnectorSlotStateRefused || ci.Message == nil || *ci.Message != "Azure DevOps refused: Agents can't see builds in acme/Web/app." {
		t.Fatalf("ci: %+v", ci)
	}
	if setup.Connection == nil || setup.Connection.Provider != wire.ConnectionProviderAzuredevops {
		t.Fatalf("connected: %+v", setup)
	}
	if setup.Events.State != wire.ConnectorEventsStateOn || deref(setup.Events.Server) != "azure-devops" {
		t.Fatalf("events: %+v", setup.Events)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json")); !strings.Contains(string(b), "azuredevops-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}
}

// A connection to an Azure DevOps Server (or a walk's fake) is used for a remote on it, and a
// connection on dev.azure.com is not sent to a server; GitHub still comes first.
func TestAnAzureDevOpsRemoteAtTheConnectionsServer(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ctx := context.Background()

	cloud := gitFolder(t, "https://acme.visualstudio.com/DefaultCollection/Web/_git/app")
	if f, _, connected := d.forgeAt(ctx, cloud); f.provider != wire.ConnectionProviderAzuredevops || f.root != azuredevopsmcp.DefaultBase ||
		f.repo != "acme/Web/app" || f.site != "dev.azure.com" || connected {
		t.Fatalf("before connecting: %+v %v", f, connected)
	}
	fake := "http://127.0.0.1:3802/"
	file.Put(connections.AzureDevOpsConnection(fake, "acme", "ado-secret", "Agents Test", time.Now()))
	server := gitFolder(t, fake+"acme/Web/_git/app")
	if f, c, connected := d.forgeAt(ctx, server); f.root != fake || f.repo != "acme/Web/app" || !connected || c.Access != "ado-secret" {
		t.Fatalf("connected to a fake: %+v %v", f, connected)
	}
	if _, _, connected := d.forgeAt(ctx, cloud); connected {
		t.Fatal("the server's token went to dev.azure.com")
	}
	if f, _, _ := d.forgeAt(ctx, gitFolder(t, "git@github.com:team/app.git")); f.provider != wire.ConnectionProviderGithub {
		t.Fatalf("GitHub first: %+v", f)
	}
}
