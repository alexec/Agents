package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports ChangesTests: the agent's reported edits beside git's view since it started, and a
// file's whole diff; and ForkTests: a branch of the conversation as an agent of its own.

func TestChangesAreTheReportedAndTheSeen(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := repo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one\ntwo\n"), 0o644)
	git(dir, "add", "a.txt")
	git(dir, "commit", "-q", "-m", "a")
	head, _ := git(dir, "rev-parse", "HEAD")
	a := seeded(t, d, dir, func(a *wire.Agent) {
		a.StartingPoint = &wire.StartingPoint{Repository: store.FolderURL(dir), Commit: head}
	})
	// The agent reports one edit to a.txt; the file then has one more line it did not report.
	path := filepath.Join(dir, "a.txt")
	old, nw := "two\n", "TWO\n"
	id, done := "call_1", "completed"
	d.Store.Append(a.ID, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{
		Value: wire.ToolCall{ToolCallID: &id, Title: "Edit", Status: &done, Locations: []wire.ToolCallLocation{},
			Content: []wire.ToolCallContent{{Type: "diff", Path: &path, OldText: &old, NewText: &nw}}}}}})
	os.WriteFile(path, []byte("one\nTWO\nthree\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "new.md"), []byte("# x\n"), 0o644)
	var list wire.ChangesList
	json.Unmarshal(c.call(t, 1, "changes/list", map[string]any{"agentID": a.ID}), &list)
	if !list.ReportsEdits || list.Git.Shared == nil || list.Git.Shared.Since != head || len(list.Files) != 2 {
		t.Fatalf("%+v", list)
	}
	f := list.Files[0]
	if f.Source != wire.ChangeSourceReportedAndSeen || f.State != wire.ChangeStateModified || *f.Added != 2 || *f.Removed != 1 ||
		!f.BeyondReported || f.EditCount != 1 || *f.FirstLine != 2 {
		t.Fatalf("%+v", f)
	}
	n := list.Files[1]
	if n.Source != wire.ChangeSourceSeen || n.State != wire.ChangeStateUntracked || *n.Added != 1 || *n.RelativePath != "new.md" {
		t.Fatalf("%+v", n)
	}
	var detail wire.ChangedFileDetail
	json.Unmarshal(c.call(t, 2, "changes/file", map[string]any{"agentID": a.ID, "path": path, "whole": true}), &detail)
	var kinds []string
	for _, l := range detail.Whole {
		kinds = append(kinds, string(l.Kind)+":"+l.Text)
	}
	if len(detail.Edits) != 1 || strings.Join(kinds, " ") != "context:one removed:two added:TWO added:three" {
		t.Fatalf("%v %+v", kinds, detail.Edits)
	}
	if e := c.callError(t, 3, "changes/file", map[string]any{"agentID": a.ID, "path": filepath.Join(dir, "nope")}); e.Code != wire.FailureNotChanged || e.Message != "nope has not changed." {
		t.Fatalf("%+v", e)
	}
}

func TestReplayAccountsForEdits(t *testing.T) {
	o := "b"
	edits := []wire.ReportedEdit{{OldText: &o, NewText: "B"}}
	if !replayAccounts(edits, "abc", "aBc") || replayAccounts(edits, "abc", "aBcd") || !replayAccounts(nil, "x", "x\n") {
		t.Fatal("replay")
	}
	if !replayAccounts([]wire.ReportedEdit{{NewText: "new\n"}}, "", "new") {
		t.Fatal("a new file without its last newline is accounted for")
	}
}

func TestBranchingFromAPrompt(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	session := "fake-session"
	title := "Plan"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.RuntimeSessionID, a.Title = &session, &title })
	ask := func(text string) wire.UUID {
		id := store.NewUUID()
		d.Store.Append(a.ID, wire.TranscriptEntry{ID: id, At: now(), Kind: wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: text}}})
		d.Store.Append(a.ID, wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{Text: "Done: " + text}}})
		return id
	}
	ask("Make the cache")
	second := ask("Make it faster")
	ask("Make it smaller")
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/branchFrom", map[string]any{"agentID": a.ID, "entryID": second}), &id)
	b := d.Store.Agent(id)
	if b == nil || b.RuntimeSessionID != nil || b.BranchedFrom == nil || *b.BranchedFrom != a.ID || *b.Title != "Plan (branch)" {
		t.Fatalf("%+v", b)
	}
	entries, _, _ := d.Store.Transcript(id, 0)
	if len(entries) != 3 || entries[0].Kind.UserMessage.Value != "Make the cache" || entries[2].Kind.RuntimeNote.Value != "Branched from Plan before its prompt 2." {
		t.Fatalf("%+v", entries)
	}
	// Its runtime reads the record ahead of the first prompt, and only until it has a conversation.
	p := d.branchPreface(b)
	if p == nil || !strings.Contains(*p, "Done: Make the cache") || strings.Contains(*p, "Make it faster") {
		t.Fatalf("%v", p)
	}
	other := "theirs"
	b.RuntimeSessionID = &other
	if d.branchPreface(b) != nil || d.branchPreface(&a) != nil {
		t.Fatal("a preface for a conversation of its own")
	}
	if e := c.callError(t, 2, "agents/branchFrom", map[string]any{"agentID": a.ID, "entryID": store.NewUUID()}); e.Message != "That prompt is not in this session's record." {
		t.Fatalf("%+v", e)
	}
}

func TestForkingAConversation(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	session := "fake-session"
	title := "Plan"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.RuntimeSessionID, a.Title = &session, &title })
	d.record(a.ID, runtimeNote("first"))
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/fork", map[string]any{"agentID": a.ID}), &id)
	b := d.Store.Agent(id)
	if b == nil || *b.RuntimeSessionID != "forked-fake-session" || *b.Title != "Plan (branch)" || b.State != wire.AgentStateFinished {
		t.Fatalf("%+v", b)
	}
	if n := notes(d, id); len(n) != 2 || n[0] != "first" || n[1] != "Branched from Plan." {
		t.Fatalf("%q", n)
	}
	none := seeded(t, d, t.TempDir(), nil)
	if e := c.callError(t, 2, "agents/fork", map[string]any{"agentID": none.ID}); e.Code != wire.FailureSessionGone {
		t.Fatalf("%+v", e)
	}
}
