package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// #4072: a folder added before its forge was connected lists that forge's pull requests once
// it is connected, with no restart: the forge's remembered answer for the folder is for the
// roots it was read on, so a new connection reads it again. One test per forge.

// adoServerDaemon is a daemon with one folder on an Azure DevOps Server and nothing connected.
func adoServerDaemon(t *testing.T) (*Daemon, *conn, *fakeForgeAzureDevOps, *connections.File) {
	t.Helper()
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	ado := &fakeForgeAzureDevOps{}
	d.newForgeAzureDevOps = func(root, token string) forgeAzureDevOps {
		if root != "https://tfs.example.com/tfs/" || token != "ado-secret" {
			t.Errorf("Azure DevOps at %q with %q", root, token)
		}
		return ado
	}
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + gitFolder(t, "https://tfs.example.com/tfs/Main/proj/_git/app")})
	return d, c, ado, file
}

func pulls(t *testing.T, c *conn, id int) wire.ForgeList {
	t.Helper()
	var list wire.ForgeList
	json.Unmarshal(c.call(t, id, "forge/pulls", wire.ForgeListRequest{}), &list)
	return list
}

func TestAzureDevOpsConnectedAfterTheFolderListsItsPullRequests(t *testing.T) {
	_, c, ado, file := adoServerDaemon(t)
	pulls(t, c, 1)
	if len(ado.searches) != 0 {
		t.Fatalf("Azure DevOps was asked before it was connected: %v", ado.searches)
	}
	file.Put(connections.AzureDevOpsConnection("https://tfs.example.com/tfs/", "Main", "ado-secret", "Agents Test", time.Now()))
	pulls(t, c, 2)
	if len(ado.searches) != 1 || ado.searches[0] != "[Main/proj/app] state= label= after= first=50" {
		t.Fatalf("Azure DevOps was asked %v", ado.searches)
	}
}

// The connector's AZURE_DEVOPS_URL in the secrets finds the folder too, as its token is for it.
func TestAzureDevOpsSecretsAfterTheFolderListItsPullRequests(t *testing.T) {
	_, c, ado, _ := adoServerDaemon(t)
	pulls(t, c, 1)
	home := os.Getenv("AGENTS_PERSONAL_HOME")
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"),
		[]byte("AZURE_DEVOPS_URL=https://tfs.example.com/tfs\nAZURE_DEVOPS_TOKEN=ado-secret\n"), 0o600)
	pulls(t, c, 2)
	if len(ado.searches) != 1 || ado.searches[0] != "[Main/proj/app] state= label= after= first=50" {
		t.Fatalf("Azure DevOps was asked %v", ado.searches)
	}
}

func TestForgejoConnectedAfterTheFolderListsItsPullRequests(t *testing.T) {
	_, c, fj, file := forgejoDaemon(t)
	forgejo, _, _ := file.Get(connections.Forgejo)
	file.Delete(connections.Forgejo)
	pulls(t, c, 1)
	if len(fj.searches) != 0 {
		t.Fatalf("Forgejo was asked before it was connected: %v", fj.searches)
	}
	file.Put(forgejo)
	pulls(t, c, 2)
	if len(fj.searches) != 1 || fj.searches[0] != "[walkalex/App] prs=true label= after= first=50" {
		t.Fatalf("Forgejo was asked %v", fj.searches)
	}
}

func TestGitLabConnectedAfterTheFolderListsItsMergeRequests(t *testing.T) {
	d, c, _, gl, _, file := allForgesDaemon(t)
	d.newForgeGitLab = func(string, string) forgeGitLab { return gl }
	file.Delete(connections.GitLab)
	pulls(t, c, 1)
	if len(gl.searches) != 0 {
		t.Fatalf("GitLab was asked before it was connected: %v", gl.searches)
	}
	file.Put(connections.Connection{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: "https://gitlab.example.com/",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	pulls(t, c, 2)
	if len(gl.searches) != 1 || gl.searches[0] != "ops/tool after=" {
		t.Fatalf("GitLab was asked %v", gl.searches)
	}
}

func TestBitbucketConnectedAfterTheFolderListsItsPullRequests(t *testing.T) {
	_, c, bb, file := bitbucketDaemon(t)
	bitbucket, _, _ := file.Get(connections.Bitbucket)
	file.Delete(connections.Bitbucket)
	pulls(t, c, 1)
	if len(bb.searches) != 0 {
		t.Fatalf("Bitbucket was asked before it was connected: %v", bb.searches)
	}
	file.Put(bitbucket)
	pulls(t, c, 2)
	if len(bb.searches) != 1 || bb.searches[0] != "[walkalex/App] prs=true label= after= first=50" {
		t.Fatalf("Bitbucket was asked %v", bb.searches)
	}
}

// #4118: a folder on a self-hosted GitLab whose host does not say "gitlab" is GitLab's in
// lineage while that GitLab is connected, as a Forgejo or an Azure DevOps Server of any name is.
func TestLineageOnASelfHostedGitLabOfAnyName(t *testing.T) {
	d, c, _, file := forgeDaemon(t)
	folder := gitFolder(t, "git@git.corp.example:Platform/API.git")
	c.call(t, 100, "folders/add", map[string]any{"folder": "file://" + folder})
	if r := d.folderRepo(folder); r.forge != "" {
		t.Fatalf("with no GitLab connection: %+v", r)
	}
	gitlab := connections.Connection{Provider: connections.GitLab, Login: "kim", Access: "gloas-secret", URL: "https://git.corp.example/",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()}
	file.Put(gitlab)
	if r := d.folderRepo(folder); r != (forgeRepo{"gitlab", "platform/api"}) {
		t.Fatalf("on the connected GitLab: %+v", r)
	}
	if n, ok := d.labelNode(folder, "P#4"); !ok || n != (wire.LineageNode{Kind: "pr", Ref: "gitlab:platform/api!4"}) {
		t.Fatalf("its P#4: %+v", n)
	}

	// Another GitLab connected, or none: the folder is on no forge lineage knows.
	other := gitlab
	other.URL = connections.GitLabCom
	file.Put(other)
	if r := d.folderRepo(folder); r.forge != "" {
		t.Fatalf("with gitlab.com connected: %+v", r)
	}
	file.Delete(connections.GitLab)
	if r := d.folderRepo(folder); r.forge != "" {
		t.Fatalf("with no GitLab connection: %+v", r)
	}
}
