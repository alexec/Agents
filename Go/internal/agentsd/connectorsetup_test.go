package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/wire"
)

// fakeSetupGitHub answers the set-up's reads; err names a slot's error.
type fakeSetupGitHub struct {
	mu    sync.Mutex
	err   map[string]error
	reads int
}

func (f *fakeSetupGitHub) fail(what string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	return f.err[what]
}

func (f *fakeSetupGitHub) NewestIssue(ctx context.Context, repo string) (*githubmcp.Newest, error) {
	if err := f.fail("issue"); err != nil {
		return nil, err
	}
	return &githubmcp.Newest{Number: 7, Title: "Fix the walk", URL: "https://github.com/" + repo + "/issues/7", At: "2026-10-19T10:00:00Z"}, nil
}

func (f *fakeSetupGitHub) NewestPull(ctx context.Context, repo string) (*githubmcp.Newest, error) {
	return nil, f.fail("pull")
}

func (f *fakeSetupGitHub) LastRun(ctx context.Context, repo string) (*githubmcp.Newest, error) {
	if err := f.fail("run"); err != nil {
		return nil, err
	}
	return &githubmcp.Newest{Title: "CI on main", Outcome: "passed", At: "2026-10-19T10:00:00Z"}, nil
}

func (f *fakeSetupGitHub) AppReach(ctx context.Context, repo, slug string) (bool, int, error) {
	return repo == "alexec/agents-walk" && slug == "agents-loops", 3, f.fail("reach")
}

func gitFolder(t *testing.T, remote string) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", remote}} {
		if remote == "" && args[0] == "remote" {
			continue
		}
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return dir
}

func slotsByKind(s wire.ConnectorSetup) map[wire.ConnectorSlotKind]wire.ConnectorSlot {
	out := map[wire.ConnectorSlotKind]wire.ConnectorSlot{}
	for _, slot := range s.Slots {
		out[slot.Slot] = slot
	}
	return out
}

// A folder's set-up (#1336): before the connection every GitHub slot waits for it and This
// Mac is done; once connected each slot reads one real thing, a refusal says so, the github
// connector's events go on once, a read that does not reach GitHub keeps a tick, and a skip
// is kept in .agents/folder.json and counts.
func TestAFoldersConnectorSetUp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gh := &fakeSetupGitHub{err: map[string]error{"run": &githubmcp.GitHubError{Kind: githubmcp.Failed, Message: "GitHub: HTTP 403", Refused: true}}}
	d.newSetupReader = func(token string) setupReader {
		if token != "ghu_secret" {
			t.Errorf("token %q", token)
		}
		return gh
	}
	folder := gitFolder(t, "git@github.com:alexec/agents-walk.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	slots := slotsByKind(setup)
	if setup.Repository == nil || *setup.Repository != "alexec/agents-walk" || setup.Connection != nil || setup.Done != 1 ||
		slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindWorkspace].State != wire.ConnectorSlotStateRead ||
		setup.Events.State != wire.ConnectorEventsStateOff || gh.reads != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	raw := c.call(t, 3, "connectors/setup", map[string]any{"folder": folder})
	if strings.Contains(string(raw), "ghu_secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &setup)
	slots = slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if tasks.State != wire.ConnectorSlotStateRead || tasks.Proof == nil || *tasks.Proof.Number != 7 || tasks.Proof.Title != "Fix the walk" {
		t.Fatalf("tasks: %+v", tasks)
	}
	if review.State != wire.ConnectorSlotStateRead || review.Proof != nil {
		t.Fatalf("a repo with no pull requests still reads: %+v", review)
	}
	if ci.State != wire.ConnectorSlotStateRefused || ci.Message == nil || !strings.Contains(*ci.Message, "Actions runs in alexec/agents-walk") {
		t.Fatalf("ci: %+v", ci)
	}
	if setup.Done != 3 || setup.Installed == nil || !*setup.Installed || *setup.Repositories != 3 ||
		setup.Connection == nil || *setup.Connection.Login != "alexec" {
		t.Fatalf("connected: %+v", setup)
	}
	if setup.Events.State != wire.ConnectorEventsStateOn || setup.Events.Server == nil || *setup.Events.Server != "github" ||
		len(setup.Events.Names) == 0 {
		t.Fatalf("events: %+v", setup.Events)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json")); !strings.Contains(string(b), "github-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}

	// A read inside five minutes is used again; Try Again reads now. GitHub not reached: the
	// tick stays. The events are not added a second time once taken out.
	reads := gh.reads
	c.call(t, 4, "connectors/setup", map[string]any{"folder": folder})
	if gh.reads != reads {
		t.Fatalf("read again inside five minutes: %d", gh.reads)
	}
	os.Remove(filepath.Join(folder, ".agents", "mcp.json"))
	gh.mu.Lock()
	gh.err = map[string]error{"issue": &githubmcp.GitHubError{Kind: githubmcp.Failed, Message: "GitHub: dial tcp: no route"}}
	gh.mu.Unlock()
	json.Unmarshal(c.call(t, 5, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	slots = slotsByKind(setup)
	if s := slots[wire.ConnectorSlotKindTasks]; s.State != wire.ConnectorSlotStateRead || s.Proof == nil {
		t.Fatalf("a lost read untick: %+v", s)
	}
	if s := slots[wire.ConnectorSlotKindCi]; s.State != wire.ConnectorSlotStateRead {
		t.Fatalf("ci read on the second try: %+v", s)
	}
	if setup.Events.State != wire.ConnectorEventsStateOff {
		t.Fatalf("the events came back after they were taken out: %+v", setup.Events)
	}

	json.Unmarshal(c.call(t, 6, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "codeReview", "skipped": true}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindCodeReview]; s.State != wire.ConnectorSlotStateSkipped || setup.Done != 4 {
		t.Fatalf("skipped: %+v %d", s, setup.Done)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "folder.json")); !strings.Contains(string(b), `"codeReview"`) {
		t.Fatalf("folder.json: %s", b)
	}
	json.Unmarshal(c.call(t, 7, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "codeReview", "skipped": false}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindCodeReview]; s.State != wire.ConnectorSlotStateRead {
		t.Fatalf("set up again: %+v", s)
	}
	// Only the project id that adding the folder wrote (#2317) is left.
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "folder.json")); strings.Contains(string(b), "connectors") || !strings.Contains(string(b), `"project"`) {
		t.Fatalf("folder.json: %s", b)
	}
	if e := c.callError(t, 8, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "workspace", "skipped": true}); e == nil {
		t.Fatal("This Mac was skipped")
	}

	// Disconnected, the slots wait for the connection again.
	file.Delete(connections.GitHub)
	json.Unmarshal(c.call(t, 9, "connectors/setup", map[string]any{"folder": folder, "reading": "stored"}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindTasks]; s.State != wire.ConnectorSlotStateNotConnected || setup.Done != 1 {
		t.Fatalf("disconnected: %+v", setup)
	}
}

// A host with no personal home can't add the connector: the page says why in words, with no
// wire code in them.
func TestEventsThatCannotBeTurnedOnSayWhy(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", "")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.newSetupReader = func(string) setupReader { return &fakeSetupGitHub{} }
	folder := gitFolder(t, "https://github.com/alexec/agents-walk.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	if setup.Events.State != wire.ConnectorEventsStateFailed || setup.Events.Message == nil ||
		strings.Contains(*setup.Events.Message, "-32") {
		t.Fatalf("%+v", setup.Events)
	}
}

// A remote on neither forge (#1632: a gitlab.com one is GitLab's set-up now).
func TestASetUpWithNoGitHubRemote(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gh := &fakeSetupGitHub{}
	d.newSetupReader = func(string) setupReader { return gh }
	folder := gitFolder(t, "https://code.example.org/alexec/blog.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	if setup.Repository != nil || slotsByKind(setup)[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNoRemote ||
		gh.reads != 0 || setup.Events.State != wire.ConnectorEventsStateOff {
		t.Fatalf("%+v", setup)
	}
	if e := c.callError(t, 3, "connectors/setup", map[string]any{"folder": t.TempDir()}); e == nil {
		t.Fatal("a folder that is not a folder")
	}
}

// fakeSetupGitLab answers a GitLab set-up's reads (#1632); refuse makes the pipeline read a 403.
type fakeSetupGitLab struct {
	mu     sync.Mutex
	reads  int
	refuse bool
}

func (f *fakeSetupGitLab) read() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
}

func (f *fakeSetupGitLab) NewestIssue(ctx context.Context, folder string) (*gitlabmcp.Newest, error) {
	f.read()
	return &gitlabmcp.Newest{Number: 3, Title: "Walk the views", URL: "https://gitlab.com/" + folder + "/-/issues/3", At: "2026-10-20T10:00:00Z"}, nil
}

func (f *fakeSetupGitLab) NewestMergeRequest(ctx context.Context, folder string) (*gitlabmcp.Newest, error) {
	f.read()
	return &gitlabmcp.Newest{Number: 2, Title: "Add a README", At: "2026-10-20T10:00:00Z"}, nil
}

func (f *fakeSetupGitLab) LastPipeline(ctx context.Context, folder string) (*gitlabmcp.Newest, error) {
	f.read()
	if f.refuse {
		return nil, &gitlabmcp.GitLabError{Kind: gitlabmcp.Failed, Message: "GitLab: HTTP 403", Refused: true}
	}
	return &gitlabmcp.Newest{Title: "Pipeline on main", Outcome: "passed", At: "2026-10-20T10:00:00Z"}, nil
}

// A GitLab folder (#1632): its remote picks GitLab, the GitLab connection fills the three
// slots, each proved by one read, the gitlab connector's events go on, and a connection to
// another GitLab is not used here.
func TestAGitLabFoldersConnectorSetUp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gl := &fakeSetupGitLab{refuse: true}
	d.newGitLabSetupReader = func(root, token string) gitlabSetupReader {
		if root != connections.GitLabCom || token != "gloas-secret" {
			t.Errorf("GitLab %q token %q", root, token)
		}
		return gl
	}
	d.newSetupReader = func(string) setupReader {
		t.Error("GitHub was read for a GitLab folder")
		return &fakeSetupGitHub{}
	}
	folder := gitFolder(t, "git@gitlab.com:agentstest-group/agents-walk.git")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder}), &setup)
	slots := slotsByKind(setup)
	if setup.Forge == nil || *setup.Forge != wire.ConnectionProviderGitlab || deref(setup.Site) != "gitlab.com" ||
		deref(setup.Repository) != "agentstest-group/agents-walk" || setup.InstallURL != nil ||
		slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindTasks].Choice != "GitLab issues" || gl.reads != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	// A connection to a self-managed GitLab is not sent to gitlab.com.
	file.Put(connections.Connection{Provider: connections.GitLab, Login: "agentstest", Access: "glpat-other",
		URL: "https://gitlab.example.com/", ConnectedAt: time.Now()})
	json.Unmarshal(c.call(t, 3, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	if setup.Connection != nil || gl.reads != 0 || slotsByKind(setup)[wire.ConnectorSlotKindCi].State != wire.ConnectorSlotStateNotConnected {
		t.Fatalf("another GitLab's connection: %+v", setup)
	}

	file.Put(connections.Connection{Provider: connections.GitLab, Login: "agentstest", Access: "gloas-secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	raw := c.call(t, 4, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"})
	if strings.Contains(string(raw), "gloas-secret") {
		t.Fatalf("a token went to the client: %s", raw)
	}
	json.Unmarshal(raw, &setup)
	slots = slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if tasks.State != wire.ConnectorSlotStateRead || tasks.Proof == nil || *tasks.Proof.Number != 3 ||
		review.State != wire.ConnectorSlotStateRead || review.Choice != "GitLab merge requests" {
		t.Fatalf("tasks %+v review %+v", tasks, review)
	}
	if ci.State != wire.ConnectorSlotStateRefused || ci.Message == nil || *ci.Message != "GitLab refused: Agents can't see pipelines in agentstest-group/agents-walk." {
		t.Fatalf("ci: %+v", ci)
	}
	if setup.Done != 3 || setup.Connection == nil || setup.Connection.Provider != wire.ConnectionProviderGitlab || setup.Installed != nil {
		t.Fatalf("connected: %+v", setup)
	}
	if setup.Events.State != wire.ConnectorEventsStateOn || deref(setup.Events.Server) != "gitlab" {
		t.Fatalf("events: %+v", setup.Events)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, ".agents", "mcp.json")); !strings.Contains(string(b), "gitlab-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}
}

// US4 (#2669): a folder whose project sets Code review reads the project's repository, even
// with no remote of its own; a slot the project skips is skipped; a slot the project does
// not set is the folder's own; the folder cannot skip a slot the project sets; the Pull
// requests page follows the project; the slots are kept across a restart.
func TestAProjectsSlotsFillItsFolders(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	var mu sync.Mutex
	readRepos := map[string]bool{}
	d.newSetupReader = func(token string) setupReader { return &recordingGitHub{fakeSetupGitHub: &fakeSetupGitHub{}, mu: &mu, repos: readRepos} }
	folder := gitFolder(t, "")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	id, _, _ := d.folderProject(folder)
	if id == "" {
		t.Fatal("no project id")
	}

	forge, repo, yes := wire.ConnectionProviderGithub, "alexec/agents-walk", true
	d.heardProjects(wire.MachineProjects{Projects: []wire.ProjectTools{{ID: id, Name: "Agents", Slots: []wire.ProjectSlot{
		{Slot: wire.ConnectorSlotKindTasks, Skipped: &yes},
		{Slot: wire.ConnectorSlotKindCodeReview, Forge: &forge, Repository: &repo},
	}}}})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": folder, "reading": "fresh"}), &setup)
	slots := slotsByKind(setup)
	tasks, review, ci := slots[wire.ConnectorSlotKindTasks], slots[wire.ConnectorSlotKindCodeReview], slots[wire.ConnectorSlotKindCi]
	if setup.Project == nil || *setup.Project != id || setup.ProjectName == nil || *setup.ProjectName != "Agents" {
		t.Fatalf("project: %+v", setup)
	}
	if tasks.State != wire.ConnectorSlotStateSkipped || tasks.FromProject == nil {
		t.Fatalf("tasks: %+v", tasks)
	}
	if review.State != wire.ConnectorSlotStateRead || review.FromProject == nil || review.Repository == nil || *review.Repository != repo {
		t.Fatalf("review: %+v", review)
	}
	if ci.State != wire.ConnectorSlotStateNoRemote || ci.FromProject != nil {
		t.Fatalf("ci: %+v", ci)
	}
	mu.Lock()
	if !readRepos[repo] || len(readRepos) != 1 {
		t.Fatalf("read %v", readRepos)
	}
	mu.Unlock()
	if e := c.callError(t, 3, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "codeReview", "skipped": true}); e == nil || !strings.Contains(e.Message, "owner or an admin") {
		t.Fatalf("%+v", e)
	}
	if args, ok := d.projectViewArguments(folder, "agents/github", githubmcp.PullsURI); !ok || string(args) != `{"repo":"alexec/agents-walk"}` {
		t.Fatalf("pulls page: %s %v", args, ok)
	}
	if _, ok := d.projectViewArguments(folder, "agents/github", githubmcp.IssuesURI); ok {
		t.Fatal("the skipped Tasks slot pointed the Issues page")
	}

	// Kept on disk: a machine that starts again before the control plane answers has them.
	d.projectToolsMu.Lock()
	d.projectTools = nil
	d.projectToolsMu.Unlock()
	if _, set := d.projectSlot(folder, wire.ConnectorSlotKindCodeReview); !set {
		t.Fatal("the slots were not kept")
	}
	// The project gives the slot back: the folder's own again.
	d.heardProjects(wire.MachineProjects{Projects: []wire.ProjectTools{{ID: id, Name: "Agents", Slots: []wire.ProjectSlot{}}}})
	var again wire.ConnectorSetup
	json.Unmarshal(c.call(t, 4, "connectors/setup", map[string]any{"folder": folder}), &again)
	if s := slotsByKind(again)[wire.ConnectorSlotKindCodeReview]; s.State != wire.ConnectorSlotStateNoRemote || s.FromProject != nil || s.Repository != nil {
		t.Fatalf("given back: %+v", s)
	}
}

// recordingGitHub is fakeSetupGitHub, noting each repository read.
type recordingGitHub struct {
	*fakeSetupGitHub
	mu    *sync.Mutex
	repos map[string]bool
}

func (r *recordingGitHub) NewestPull(ctx context.Context, repo string) (*githubmcp.Newest, error) {
	r.mu.Lock()
	r.repos[repo] = true
	r.mu.Unlock()
	return r.fakeSetupGitHub.NewestPull(ctx, repo)
}
