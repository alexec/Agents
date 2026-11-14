package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/wire"
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
	if list.Connections[0].ByToken == nil || !*list.Connections[0].ByToken {
		t.Fatalf("a personal access token's row: %+v", list.Connections[0])
	}
	// No Entra app in the machine's secrets (#4873): the sign-in uses the Agents app, in any
	// work or school tenant; one in the secrets goes first.
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	t.Setenv("AGENTS_"+connections.AzureDevOpsClientIDName, "")
	if f := d.deviceFlow(wire.ConnectionProviderAzuredevops); f.ClientID != connections.AzureDevOpsClientID ||
		!strings.HasSuffix(f.Base, "/"+connections.EntraTenant+"/") {
		t.Fatalf("the Agents app: %q %q", f.ClientID, f.Base)
	}
	t.Setenv("AGENTS_"+connections.AzureDevOpsClientIDName, "own-app")
	if f := d.deviceFlow(wire.ConnectionProviderAzuredevops); f.ClientID != "own-app" {
		t.Fatalf("the machine's own app: %q", f.ClientID)
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

// Azure DevOps by Microsoft Entra (#3921): Entra's device flow for the organization given, the
// access token checked with it as a bearer token, the pair kept and renewed with the scope, and
// an Azure DevOps Server or no organization refused before Entra is asked.
func TestSigningInToAzureDevOpsWithEntra(t *testing.T) {
	var mu sync.Mutex
	var forms []map[string]string
	access := "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln"
	entra := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		form := map[string]string{"path": r.URL.Path}
		for k := range r.PostForm {
			form[k] = r.PostForm.Get(k)
		}
		mu.Lock()
		forms = append(forms, form)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/organizations/oauth2/v2.0/devicecode":
			fmt.Fprint(w, `{"device_code":"dc-secret","user_code":"ENTRA123","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5}`)
		case form["grant_type"] == "refresh_token":
			fmt.Fprint(w, `{"access_token":"`+access+`2","refresh_token":"rt-2","expires_in":3600}`)
		default:
			fmt.Fprint(w, `{"access_token":"`+access+`","refresh_token":"rt-1","expires_in":3600}`)
		}
	}))
	defer entra.Close()
	ado := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer "+access) {
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
	d.newDeviceFlow = func(wire.ConnectionProvider) *connections.DeviceFlow {
		f := connections.NewAzureDevOpsEntraFlow("entra-app", "")
		f.Base, f.HTTP = entra.URL+"/organizations/", entra.Client()
		f.Sleep = func(ctx context.Context, _ time.Duration) error { return ctx.Err() }
		return f
	}

	if msg := c.callErr(t, 1, "connections/sign-in", map[string]any{"provider": "azuredevops"}); !strings.Contains(msg, "organization") {
		t.Fatalf("no organization: %s", msg)
	}
	if msg := c.callErr(t, 2, "connections/sign-in", map[string]any{"provider": "azuredevops", "url": "https://tfs.example.com/tfs/DefaultCollection"}); !strings.Contains(msg, "Server") {
		t.Fatalf("an Azure DevOps Server: %s", msg)
	}
	var started wire.ConnectionSignIn
	json.Unmarshal(c.call(t, 3, "connections/sign-in", map[string]any{"provider": "azuredevops", "url": ado.URL + "/acme"}), &started)
	if started.Status != wire.ConnectionSignInStatusWaiting || deref(started.UserCode) != "ENTRA123" ||
		started.VerificationURL != "https://microsoft.com/devicelogin" || started.Grant != wire.ConnectionSignInGrantDeviceCode {
		t.Fatalf("started: %+v", started)
	}
	var done wire.ConnectionSignIn
	for range 50 {
		raw := c.call(t, 4, "connections/sign-in/wait", map[string]any{"flowID": started.FlowID})
		if strings.Contains(string(raw), "eyJ") || strings.Contains(string(raw), "rt-1") || strings.Contains(string(raw), "dc-secret") {
			t.Fatalf("a secret went to the client: %s", raw)
		}
		json.Unmarshal(raw, &done)
		if done.Status != wire.ConnectionSignInStatusWaiting {
			break
		}
	}
	if done.Status != wire.ConnectionSignInStatusConnected || done.Connection == nil || deref(done.Connection.Login) != "Agents Test" ||
		done.Connection.ByToken != nil || done.Connection.ExpiresAt != nil {
		t.Fatalf("done: %+v (%s)", done, deref(done.Message))
	}
	kept, ok, _ := file.Get(connections.AzureDevOps)
	if !ok || kept.Access != access || kept.Refresh != "rt-1" || kept.Resource != "acme" || kept.URL != ado.URL+"/" || kept.AccessExpiresAt.IsZero() {
		t.Fatalf("kept: %+v", kept)
	}
	mu.Lock()
	start := forms[0]
	mu.Unlock()
	if start["client_id"] != "entra-app" || start["scope"] != connections.AzureDevOpsEntraScope {
		t.Fatalf("the device code asked for: %+v", start)
	}

	// Due within the margin: renewed with the scope, as Entra wants it.
	kept.AccessExpiresAt = time.Now().Add(time.Minute)
	file.Put(kept)
	d.renewConnections()
	renewed, _, _ := file.Get(connections.AzureDevOps)
	mu.Lock()
	last := forms[len(forms)-1]
	mu.Unlock()
	if renewed.Access != access+"2" || renewed.Refresh != "rt-2" || renewed.Resource != "acme" || renewed.Login != "Agents Test" ||
		last["grant_type"] != "refresh_token" || last["scope"] != connections.AzureDevOpsEntraScope {
		t.Fatalf("renewed %+v with %+v", renewed, last)
	}
	// An Entra connection that must sign in again is still Entra's, not a token's.
	renewed.Access, renewed.Refresh, renewed.SignInAgain = "", "", true
	file.Put(renewed)
	var list wire.ConnectionsList
	json.Unmarshal(c.call(t, 5, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 1 || list.Connections[0].ByToken != nil || list.Connections[0].State != wire.ConnectionStateSignInAgain {
		t.Fatalf("list: %+v", list.Connections)
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
	// #3816: the Tasks slot names the remote's Azure Boards project for the Work pages, once,
	// approved; a person who takes it out is not overruled.
	if got := d.folderBoardsProjects(folder); !slices.Equal(got, []string{"acme/web"}) || !d.settled(folder, ".agents/folder.json") {
		b, _ := os.ReadFile(filepath.Join(folder, ".agents", "folder.json"))
		t.Fatalf("Azure Boards projects %q, folder.json %s", got, b)
	}
	if err := setFolderConfig(folder, "azureBoardsProjects", nil); err != nil {
		t.Fatal(err)
	}
	d.approveWrite(folder, ".agents/folder.json")
	c.call(t, 4, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"})
	if got := d.folderBoardsProjects(folder); len(got) != 0 {
		t.Fatalf("named again: %q", got)
	}
}

// #3816: a folder that names its Azure Boards projects already keeps them; one that names Jira
// projects or Linear teams for its tasks is given none.
func TestAnAzureDevOpsSetUpKeepsTheFoldersBoardsProjects(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.newAzureDevOpsSetupReader = func(string, string) azureDevOpsSetupReader { return &fakeSetupAzureDevOps{} }
	file.Put(connections.AzureDevOpsConnection(connections.AzureDevOpsServices, "acme", "ado-secret", "Agents Test", time.Now()))
	named := gitFolder(t, "https://dev.azure.com/acme/Web/_git/app")
	os.MkdirAll(filepath.Join(named, ".agents"), 0o755)
	os.WriteFile(filepath.Join(named, ".agents", "folder.json"), []byte(`{"azureBoardsProjects": ["acme/Plans"]}`), 0o644)
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + named})
	c.call(t, 2, "connectors/setup", map[string]any{"folder": named, "reading": "fresh"})
	if got := d.folderBoardsProjects(named); !slices.Equal(got, []string{"acme/plans"}) {
		t.Fatalf("named: %q", got)
	}

	jira := gitFolder(t, "https://dev.azure.com/acme/Web/_git/other")
	os.MkdirAll(filepath.Join(jira, ".agents"), 0o755)
	os.WriteFile(filepath.Join(jira, ".agents", "folder.json"), []byte(`{"jiraProjects": ["WEB"]}`), 0o644)
	c.call(t, 3, "folders/add", map[string]any{"folder": "file://" + jira})
	c.call(t, 4, "connectors/setup", map[string]any{"folder": jira, "reading": "fresh"})
	if b, _ := os.ReadFile(filepath.Join(jira, ".agents", "folder.json")); strings.Contains(string(b), "azureBoardsProjects") {
		t.Fatalf("a folder on Jira was given Azure Boards: %s", b)
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
