package store

import (
	"encoding/json"
	"os"
	"os/exec"
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

// AppendMany writes a branch's 10,000 entries with one open, not one for each (#1852).
func TestAppendManyOpensTheTranscriptOnce(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	s.Append(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{}}})
	opens := 0
	was := openTranscript
	openTranscript = func(file string) (*os.File, error) { opens++; return was(file) }
	defer func() { openTranscript = was }()
	es := make([]wire.TranscriptEntry, 10000)
	for i := range es {
		es[i] = wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: "x"}}}
	}
	n, err := s.AppendMany(id, es)
	if err != nil || n != 1 || opens != 1 {
		t.Fatalf("first %d, opens %d, %v", n, opens, err)
	}
	if n, _ := s.Append(id, es[0]); n != 10001 {
		t.Fatalf("next index %d", n)
	}
	got, at, _ := s.Transcript(id, 0)
	if len(got) != 10002 || at[10001] != 10001 || got[5000].ID != es[4999].ID {
		t.Fatalf("read back %d", len(got))
	}
}

func TestFoldersFile(t *testing.T) {
	s, _ := Open(t.TempDir())
	ps := []wire.Folder{{Folder: FolderURL("/w/b"), AddedAt: 2}, {Folder: FolderURL("/w/a b"), AddedAt: 1}}
	if err := s.SaveFolders(ps); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(s.Loc.Folders())
	if string(b) != `[{"addedAt":"2001-01-01T00:00:01.000Z","folder":"file:///w/a%20b"},{"addedAt":"2001-01-01T00:00:02.000Z","folder":"file:///w/b"}]` {
		t.Fatalf("folders.json %s", b)
	}
	s2, _ := Open(s.Loc.Root)
	if got := s2.Folders(); len(got) != 2 || FolderPath(got[0].Folder) != "/w/a b" {
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

// EntriesFrom reads whole lines from a byte on, leaves a line still being written for next
// time, and keeps no line index (P20261019-1).
func TestEntriesFrom(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	for _, text := range []string{"one", "two"} {
		s.Append(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: text}}})
	}
	path := s.Loc.Transcript(string(id))
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"half`)
	f.Close()
	var texts []string
	var starts []int64
	end, size, err := s.EntriesFrom(id, 0, func(e wire.TranscriptEntry, start, _ int64) {
		texts, starts = append(texts, e.Kind.AgentMessage.Text), append(starts, start)
	})
	if err != nil || strings.Join(texts, ",") != "one,two" || starts[0] != 0 || size != end+6 {
		t.Fatalf("%v %v end %d size %d %v", texts, starts, end, size, err)
	}
	texts = nil
	if again, _, _ := s.EntriesFrom(id, starts[1], func(e wire.TranscriptEntry, _, _ int64) {
		texts = append(texts, e.Kind.AgentMessage.Text)
	}); again != end || strings.Join(texts, ",") != "two" {
		t.Fatalf("from the second line: %v end %d", texts, again)
	}
	if _, size, _ := s.EntriesFrom(id, size+10, func(wire.TranscriptEntry, int64, int64) { t.Fatal("read past the end") }); size == 0 {
		t.Fatal("size")
	}
	if len(s.ib.indexes) != 0 {
		t.Fatalf("kept %d line indexes", len(s.ib.indexes))
	}
}

// A transcript line with a token in it is written redacted, and the caller gets the
// redacted entry to send on (#1001, SC-001).
func TestATokenInATranscriptLineIsStoredRedacted(t *testing.T) {
	s, _ := Open(t.TempDir())
	id := NewUUID()
	token := "ghp_" + strings.Repeat("a1B2", 9)
	said := "Your token is " + token + ".\nKeep it safe."
	call := wire.ToolCall{Title: "cat .env: GITHUB_TOKEN=" + token, Content: []wire.ToolCallContent{}}
	n, got, err := s.AppendOne(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{
		AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: said}}})
	if err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if want := "Your token is [redacted:github].\nKeep it safe."; got.Kind.AgentMessage == nil || got.Kind.AgentMessage.Text != want {
		t.Fatalf("entry sent on: %+v", got.Kind.AgentMessage)
	}
	if _, err := s.Append(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{
		ToolCall: &wire.TranscriptEntryKindToolCall{Value: call}}}); err != nil {
		t.Fatal(err)
	}
	plain := "Nothing secret here."
	if _, got, _ := s.AppendOne(id, wire.TranscriptEntry{ID: NewUUID(), Kind: wire.TranscriptEntryKind{
		AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: plain}}}); got.Kind.AgentMessage.Text != plain {
		t.Fatalf("plain text changed: %q", got.Kind.AgentMessage.Text)
	}
	b, err := os.ReadFile(s.Loc.Transcript(string(id)))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), token) || strings.Count(string(b), "[redacted:github]") != 2 {
		t.Fatalf("transcript on disk:\n%s", b)
	}
	entries, _, _ := s.Transcript(id, 0)
	if len(entries) != 3 || entries[1].Kind.ToolCall.Value.Title != "cat .env: GITHUB_TOKEN=[redacted:github]" {
		t.Fatalf("read back: %+v", entries)
	}
}

// A worktree record with no folder (#2650) gets one on load, written back: the old
// "project" key when it has one, else the repository its root belongs to. None is left "".
func TestAWorktreeWithNoFolderIsFilled(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(t.TempDir(), "repo")
	wt := filepath.Join(repo, ".agents", "worktrees", "lane")
	os.MkdirAll(wt, 0o755)
	if out, err := exec.Command("git", "init", "-q", repo).CombinedOutput(); err != nil {
		t.Skipf("no git here: %v %s", err, out)
	}
	write := func(id, worktree string) {
		dir := filepath.Join(root, "agents", id)
		os.MkdirAll(dir, 0o755)
		b := `{"id":"` + id + `","runtimeID":"claude","cwd":"file:///w/","state":"stopped","endedReason":"endTurn",` +
			`"advertisedOptions":[],"availableCommands":[],"worktree":` + worktree + `}`
		if err := os.WriteFile(filepath.Join(dir, "agent.json"), []byte(b), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	empty, old, gone := NewUUID(), NewUUID(), NewUUID()
	write(string(empty), `{"name":"lane","root":"`+string(PathURL(wt))+`","madeByApp":true,"folder":""}`)
	write(string(old), `{"name":"lane","root":"file:///x/.agents/worktrees/lane","madeByApp":true,"project":"file:///x"}`)
	write(string(gone), `{"name":"lane","root":"file:///nowhere/src/.agents/worktrees/lane","madeByApp":true,"folder":""}`)
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	want := map[wire.UUID]wire.URL{empty: FolderURL(repo), old: "file:///x", gone: "file:///nowhere/src"}
	for id, folder := range want {
		if a := s.Agent(id); a == nil || a.Worktree == nil || a.Worktree.Folder != folder {
			t.Errorf("%s: folder %+v, want %s", id, a.Worktree, folder)
		}
		b, _ := os.ReadFile(s.Loc.Record(string(id)))
		var rec struct{ Worktree struct{ Folder wire.URL } }
		json.Unmarshal(b, &rec)
		if rec.Worktree.Folder != folder {
			t.Errorf("%s: written back as %q, want %s", id, rec.Worktree.Folder, folder)
		}
	}
}
