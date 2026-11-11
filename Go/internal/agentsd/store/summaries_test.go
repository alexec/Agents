package store

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// summariesRoot is a root with three archived agents and one live, each with commands,
// its summaries written.
func summariesRoot(t *testing.T) (string, *Store, []wire.UUID) {
	t.Helper()
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(fixtures, "archived-agent.json"))
	if err != nil {
		t.Fatal(err)
	}
	var shape wire.Agent
	if err := diskjson.Unmarshal(b, &shape); err != nil {
		t.Fatal(err)
	}
	about := "what it does"
	byUser, endTurn := wire.AgentArchivedReasonByUser, wire.EndedReasonEndTurn
	var ids []wire.UUID
	for i := range 4 {
		a := shape
		a.ID, a.Cwd, a.MadeInRoot = NewUUID(), wire.URL(fmt.Sprintf("file:///src/folder-%d", i%2)), &s.RootID
		title := fmt.Sprintf("Session %d", i)
		a.Title, a.Labels = &title, []wire.SessionLabel{{Value: fmt.Sprintf("#%d", i)}}
		a.AvailableCommands = []wire.SlashCommand{{Name: fmt.Sprintf("command-%d", i), Description: &about}}
		a.CostToDate = map[string]float64{"USD": float64(i)}
		if i == 0 {
			a.State, a.EndedReason, a.ArchivedAt, a.ArchivedReason = wire.AgentStateFinished, &endTurn, nil, nil
		} else {
			a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser
		}
		if err := s.Save(a); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, a.ID)
	}
	if err := s.WriteSummaries(); err != nil {
		t.Fatal(err)
	}
	// No write is left due when the test's root goes.
	t.Cleanup(s.FlushSummaries)
	return root, s, ids
}

// logged is what fn logs.
func logged(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	fn()
	return buf.String()
}

func reopen(t *testing.T, root string) (*Store, string) {
	t.Helper()
	var s *Store
	out := logged(t, func() {
		var err error
		if s, err = Open(root); err != nil {
			t.Fatal(err)
		}
	})
	t.Cleanup(s.FlushSummaries)
	return s, out
}

// The lists and an opened archived session show what they did before the summaries
// (#4653): the start trusts them, the lists carry every field but the commands, and an
// opened record has its commands, read from its file.
func TestArchivedSummariesShowTheSameData(t *testing.T) {
	root, before, ids := summariesRoot(t)
	o, out := reopen(t, root)
	if strings.Contains(out, "summaries") {
		t.Fatalf("a start with the summaries true rebuilt them: %s", out)
	}
	if got, want := mustJSON(o.Agents()), mustJSON(before.Agents()); got != want {
		t.Fatalf("the list changed:\n%s\nwas\n%s", got, want)
	}
	for _, f := range []string{"/src/folder-0", "/src/folder-1"} {
		if got, want := mustJSON(o.ArchivedIn(f)), mustJSON(before.ArchivedIn(f)); got != want {
			t.Fatalf("%s's archived tally is %s, was %s", f, got, want)
		}
	}
	for i, id := range ids {
		full, _, err := before.load(string(id))
		if err != nil {
			t.Fatal(err)
		}
		a := o.Agent(id)
		if got, want := mustJSON(a), mustJSON(full); got != want {
			t.Fatalf("agent %d opened as\n%s\nits record is\n%s", i, got, want)
		}
		if len(a.AvailableCommands) != 1 {
			t.Fatalf("agent %d has commands %v", i, a.AvailableCommands)
		}
		listed := o.AgentsIn(AgentFolder(a))
		for _, l := range listed {
			if l.ID == id && l.State == wire.AgentStateArchived && len(l.AvailableCommands) != 0 {
				t.Fatalf("the list holds an archived agent's commands")
			}
		}
	}
}

// A summary copied out and saved again keeps its record's commands; one unarchived is
// whole, and live from the next start.
func TestArchivedSummariesSavedAndUnarchived(t *testing.T) {
	root, s, ids := summariesRoot(t)
	var copied wire.Agent
	for _, a := range s.Agents() {
		if a.ID == ids[1] {
			copied = a
		}
	}
	title := "Renamed"
	copied.Title = &title
	if err := s.Save(copied); err != nil {
		t.Fatal(err)
	}
	if a := s.Agent(ids[1]); *a.Title != title || len(a.AvailableCommands) != 1 {
		t.Fatalf("saved summary: %s, commands %v", *a.Title, a.AvailableCommands)
	}
	a := s.Agent(ids[2])
	endTurn := wire.EndedReasonEndTurn
	a.State, a.ArchivedReason, a.EndedReason = wire.AgentStateFinished, nil, &endTurn
	if err := s.Save(*a); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ids[3]); err != nil {
		t.Fatal(err)
	}
	if err := s.WriteSummaries(); err != nil {
		t.Fatal(err)
	}
	o, out := reopen(t, root)
	if strings.Contains(out, "summaries") {
		t.Fatalf("the summaries were not kept true: %s", out)
	}
	if a := o.Agent(ids[1]); *a.Title != title || len(a.AvailableCommands) != 1 {
		t.Fatalf("after a start: %s, commands %v", *a.Title, a.AvailableCommands)
	}
	if a := o.Agent(ids[2]); a.State != wire.AgentStateFinished || len(a.AvailableCommands) != 1 {
		t.Fatalf("unarchived: %s, commands %v", a.State, a.AvailableCommands)
	}
	if o.Agent(ids[3]) != nil || len(o.Agents()) != 3 {
		t.Fatalf("the deleted agent is back")
	}
	if n := len(o.LiveAgents()); n != 2 {
		t.Fatalf("%d live, want 2", n)
	}
}

// Missing or stale summaries are rebuilt from the records, with a log line: a record
// another build wrote is read in full, and one it deleted is gone.
func TestArchivedSummariesRebuilt(t *testing.T) {
	root, s, ids := summariesRoot(t)
	if err := os.Remove(s.Loc.Summaries()); err != nil {
		t.Fatal(err)
	}
	o, out := reopen(t, root)
	if !strings.Contains(out, "summaries were missing: read 3 of 3 archived records in full") {
		t.Fatalf("no line for missing summaries: %q", out)
	}
	if _, err := os.Stat(o.Loc.Summaries()); err != nil {
		t.Fatalf("not written again: %v", err)
	}
	if _, out := reopen(t, root); strings.Contains(out, "summaries") {
		t.Fatalf("rebuilt twice: %s", out)
	}

	// Another build changes one archived record and deletes another.
	a := o.Agent(ids[1])
	title := "Written elsewhere"
	a.Title = &title
	b, _ := diskjson.Marshal(a)
	if err := os.WriteFile(o.Loc.Record(string(ids[1])), append(b, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	os.RemoveAll(o.Loc.Agent(string(ids[3])))
	o, out = reopen(t, root)
	if !strings.Contains(out, "summaries were 1 new or changed, 1 gone: read 1 of 2 archived records in full") {
		t.Fatalf("no line for stale summaries: %q", out)
	}
	if a := o.Agent(ids[1]); *a.Title != title || len(a.AvailableCommands) != 1 {
		t.Fatalf("the stale record: %s, commands %v", *a.Title, a.AvailableCommands)
	}
	if o.Agent(ids[3]) != nil {
		t.Fatal("a deleted record came back from its summary")
	}

	// A file this build cannot read is rebuilt too.
	os.WriteFile(o.Loc.Summaries(), []byte("{"), 0o600)
	if _, out := reopen(t, root); !strings.Contains(out, "summaries were unreadable") {
		t.Fatalf("no line for unreadable summaries: %q", out)
	}
}

