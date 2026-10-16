package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

var fixtures = filepath.Join("..", "..", "..", "..", "Packages", "AgentsKit", "Tests", "AgentsKitTests", "Fixtures")

func TestPlatformFolders(t *testing.T) {
	env := func(v string) string { return map[string]string{"XDG_CACHE_HOME": "/c", "XDG_STATE_HOME": "/s"}[v] }
	l := platformFolders("/home/agents/.agents-server/root", "/home/agents", env)
	if !strings.HasPrefix(l.Cache, "/c/agents/roots/root-") || !strings.HasPrefix(l.Logs, "/s/agents/logs/roots/root-") {
		t.Fatalf("%+v", l)
	}
	l = platformFolders("/home/agents/.agents-server/root", "/home/agents", func(string) string { return "" })
	if want := "/home/agents/.local/state/agents/logs/roots/root-" + PathHash("/home/agents/.agents-server/root"); l.Logs != want {
		t.Fatalf("logs %s, want %s", l.Logs, want)
	}
	tmp := t.TempDir()
	if l := At(tmp); l.Cache != filepath.Join(tmp, "cache") || l.Logs != filepath.Join(tmp, "logs") {
		t.Fatalf("temporary root %+v", l)
	}
}

func TestPathHashIsSwifts(t *testing.T) {
	// FNV-1a 64 as StoreLocations.pathHash has it, with its offset basis 1469598103934665603
	// (one digit short of the standard one): "" is that basis, 14650fb0739d0383.
	if PathHash("") != "739d0383" || PathHash("a") != "73cd9906" {
		t.Fatalf("%s %s", PathHash(""), PathHash("a"))
	}
}

func seed(t *testing.T, root, file string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixtures, file))
	if err != nil {
		t.Fatal(err)
	}
	var head struct{ ID string }
	json.Unmarshal(b, &head)
	dir := filepath.Join(root, "agents", strings.ToUpper(head.ID))
	os.MkdirAll(dir, 0o755)
	if err := os.WriteFile(filepath.Join(dir, "agent.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
	return strings.ToUpper(head.ID)
}

// A root the Swift daemon wrote opens with every agent, and a record saved again keeps
// what it said (the dates, the lists, the fields this host does not use).
func TestARootSwiftWroteOpens(t *testing.T) {
	root := t.TempDir()
	id := seed(t, root, "archived-agent.json")
	before, _ := os.ReadFile(filepath.Join(root, "agents", id, "agent.json"))
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	a := s.Agent(wire.UUID(id))
	if a == nil {
		t.Fatal("the agent was not read")
	}
	if err := s.Save(*a); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(filepath.Join(root, "agents", id, "agent.json"))
	var x, y map[string]any
	json.Unmarshal(before, &x)
	json.Unmarshal(after, &y)
	delete(y, "madeInRoot") // stamped: the root had no id, so its records are its own
	for k, v := range x {
		if vb, _ := json.Marshal(v); string(vb) != mustJSON(y[k]) {
			t.Errorf("%s was %s, now %s", k, vb, mustJSON(y[k]))
		}
	}
	if len(x) != len(y) {
		t.Errorf("keys %d, now %d", len(x), len(y))
	}
	if again, _ := Open(root); again.RootID != s.RootID {
		t.Fatal("the root's id changed on a second open")
	}
}

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

// A record left running is the daemon's to find (DaemonCore+Recovery); only a start that
// carries an ending is mended here.
func TestARunningAgentIsLeftForTheDaemon(t *testing.T) {
	root := t.TempDir()
	s, _ := Open(root)
	a := wire.Agent{ID: NewUUID(), RuntimeID: "claude", Cwd: "file:///w/", State: wire.AgentStateRunning,
		AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{}, MadeInRoot: &s.RootID}
	if err := s.Save(a); err != nil {
		t.Fatal(err)
	}
	s, _ = Open(root)
	got := s.Agent(a.ID)
	if got.State != wire.AgentStateRunning {
		t.Fatalf("%v %v", got.State, got.EndedReason)
	}
	if got.MadeInRoot == nil || *got.MadeInRoot != s.RootID {
		t.Fatal("not stamped with the root's id")
	}
}

func TestSaveRefusesWhatTheRulesForbid(t *testing.T) {
	s, _ := Open(t.TempDir())
	err := s.Save(wire.Agent{ID: NewUUID(), State: wire.AgentStateStopped})
	if _, ok := err.(*Refused); !ok {
		t.Fatalf("err %v", err)
	}
}

func TestTranscriptAppendAndRead(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	text := "hello"
	for i := 0; i < 3; i++ {
		n, err := s.Append(id, wire.TranscriptEntry{ID: NewUUID(), At: wire.Date(i), Kind: wire.TranscriptEntryKind{
			AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: text}}})
		if err != nil || n != i {
			t.Fatalf("append %d: %d %v", i, n, err)
		}
	}
	es, at, err := s.Transcript(id, 1)
	if err != nil || len(es) != 2 || at[0] != 1 || es[1].Kind.AgentMessage.Text != text {
		t.Fatalf("%v %v %v", es, at, err)
	}
	b, _ := os.ReadFile(s.Loc.Transcript(string(id)))
	if !strings.Contains(string(b), `"at":"2001-01-01T00:00:01.000Z"`) {
		t.Fatalf("on disk %s", b)
	}
	// A store opened again counts on from the file.
	s2, _ := Open(s.Loc.Root)
	if n, _ := s2.Append(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{}}}); n != 3 {
		t.Fatalf("index %d", n)
	}
}

func TestProjectsFile(t *testing.T) {
	s, _ := Open(t.TempDir())
	ps := []wire.Project{{Folder: FolderURL("/w/b"), AddedAt: 2}, {Folder: FolderURL("/w/a b"), AddedAt: 1}}
	if err := s.SaveProjects(ps); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(s.Loc.Projects())
	if string(b) != `[{"addedAt":"2001-01-01T00:00:01.000Z","folder":"file:///w/a%20b"},{"addedAt":"2001-01-01T00:00:02.000Z","folder":"file:///w/b"}]` {
		t.Fatalf("projects.json %s", b)
	}
	s2, _ := Open(s.Loc.Root)
	if got := s2.Projects(); len(got) != 2 || FolderPath(got[0].Folder) != "/w/a b" {
		t.Fatalf("%v", got)
	}
}

func TestRootIDFileIsSwifts(t *testing.T) {
	root := t.TempDir()
	s, _ := Open(root)
	b, _ := os.ReadFile(filepath.Join(root, "root-id.json"))
	if !strings.HasPrefix(string(b), "{\n  \"id\" : \""+s.RootID+"\",\n  \"madeAt\" : \"") {
		t.Fatalf("root-id.json %s", b)
	}
	if !strings.Contains(string(b), `"path" : "\/`) {
		t.Fatalf("slashes not escaped as Swift escapes them: %s", b)
	}
}
