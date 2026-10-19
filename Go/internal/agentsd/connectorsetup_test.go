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

func gitProject(t *testing.T, remote string) string {
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

// A project's set-up (#1336): before the connection every GitHub slot waits for it and This
// Mac is done; once connected each slot reads one real thing, a refusal says so, the github
// connector's events go on once, a read that does not reach GitHub keeps a tick, and a skip
// is kept in .agents/project.json and counts.
func TestAProjectsConnectorSetUp(t *testing.T) {
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
	project := gitProject(t, "git@github.com:alexec/agents-walk.git")
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": project}), &setup)
	slots := slotsByKind(setup)
	if setup.Repository == nil || *setup.Repository != "alexec/agents-walk" || setup.Connection != nil || setup.Done != 1 ||
		slots[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNotConnected ||
		slots[wire.ConnectorSlotKindWorkspace].State != wire.ConnectorSlotStateRead ||
		setup.Events.State != wire.ConnectorEventsStateOff || gh.reads != 0 {
		t.Fatalf("before connecting: %+v", setup)
	}

	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	raw := c.call(t, 3, "connectors/setup", map[string]any{"folder": project})
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
	if b, _ := os.ReadFile(filepath.Join(project, ".agents", "mcp.json")); !strings.Contains(string(b), "github-mcp") {
		t.Fatalf("mcp.json: %s", b)
	}

	// A read inside five minutes is used again; Try Again reads now. GitHub not reached: the
	// tick stays. The events are not added a second time once taken out.
	reads := gh.reads
	c.call(t, 4, "connectors/setup", map[string]any{"folder": project})
	if gh.reads != reads {
		t.Fatalf("read again inside five minutes: %d", gh.reads)
	}
	os.Remove(filepath.Join(project, ".agents", "mcp.json"))
	gh.mu.Lock()
	gh.err = map[string]error{"issue": &githubmcp.GitHubError{Kind: githubmcp.Failed, Message: "GitHub: dial tcp: no route"}}
	gh.mu.Unlock()
	json.Unmarshal(c.call(t, 5, "connectors/setup", map[string]any{"folder": project, "reading": "fresh"}), &setup)
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

	json.Unmarshal(c.call(t, 6, "connectors/setup/skip", map[string]any{"folder": project, "slot": "codeReview", "skipped": true}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindCodeReview]; s.State != wire.ConnectorSlotStateSkipped || setup.Done != 4 {
		t.Fatalf("skipped: %+v %d", s, setup.Done)
	}
	if b, _ := os.ReadFile(filepath.Join(project, ".agents", "project.json")); !strings.Contains(string(b), `"codeReview"`) {
		t.Fatalf("project.json: %s", b)
	}
	json.Unmarshal(c.call(t, 7, "connectors/setup/skip", map[string]any{"folder": project, "slot": "codeReview", "skipped": false}), &setup)
	if s := slotsByKind(setup)[wire.ConnectorSlotKindCodeReview]; s.State != wire.ConnectorSlotStateRead {
		t.Fatalf("set up again: %+v", s)
	}
	if _, err := os.Stat(filepath.Join(project, ".agents", "project.json")); !os.IsNotExist(err) {
		t.Fatalf("project.json is kept with nothing in it: %v", err)
	}
	if e := c.callError(t, 8, "connectors/setup/skip", map[string]any{"folder": project, "slot": "workspace", "skipped": true}); e == nil {
		t.Fatal("This Mac was skipped")
	}

	// Disconnected, the slots wait for the connection again.
	file.Delete(connections.GitHub)
	json.Unmarshal(c.call(t, 9, "connectors/setup", map[string]any{"folder": project, "reading": "stored"}), &setup)
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
	project := gitProject(t, "https://github.com/alexec/agents-walk.git")
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": project}), &setup)
	if setup.Events.State != wire.ConnectorEventsStateFailed || setup.Events.Message == nil ||
		strings.Contains(*setup.Events.Message, "-32") {
		t.Fatalf("%+v", setup.Events)
	}
}

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
	project := gitProject(t, "https://gitlab.com/alexec/blog.git")
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})

	var setup wire.ConnectorSetup
	json.Unmarshal(c.call(t, 2, "connectors/setup", map[string]any{"folder": project}), &setup)
	if setup.Repository != nil || slotsByKind(setup)[wire.ConnectorSlotKindTasks].State != wire.ConnectorSlotStateNoRemote ||
		gh.reads != 0 || setup.Events.State != wire.ConnectorEventsStateOff {
		t.Fatalf("%+v", setup)
	}
	if e := c.callError(t, 3, "connectors/setup", map[string]any{"folder": t.TempDir()}); e == nil {
		t.Fatal("a folder that is not a project")
	}
}
