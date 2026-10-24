package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports ArchiveRequestTests and HelperStopArchiveTests: an agent asks to be archived once
// its turn ends and waits for the person's approval; an ending that wants the person takes
// the ask away; a helper whose starter may archive it is archived with nobody asked; and a
// lead stops and archives only what it started.

func TestAnAgentAsksToBeArchived(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	// The person's own chat, with the person's setting off: it waits for approval (#1802).
	if _, err := d.setPreferences(map[string]wire.JSONValue{agentsMayArchiveMyChatsKey: wire.JSONValue("false")}); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "archive_session", nil); text != "Once this turn ends, this conversation waits for the person to approve archiving it. Anything the person sends before then drops it." {
		t.Fatal(text)
	}
	got := d.Store.Agent(a.ID)
	report := &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "Done.", At: now()}
	requested, archiveNow := d.settleArchiveRequest(&wire.Agent{ID: got.ID, AfterTurn: got.AfterTurn, Report: report, State: wire.AgentStateFinished},
		wire.AgentStateFinished, wire.EndedReasonEndTurn, false)
	if !requested || archiveNow {
		t.Fatal(requested, archiveNow)
	}
	// An ending that asks the person something takes the ask away.
	b := wire.Agent{AfterTurn: got.AfterTurn, Report: &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer}, State: wire.AgentStateFinished}
	if requested, _ := d.settleArchiveRequest(&b, wire.AgentStateFinished, wire.EndedReasonEndTurn, false); requested || b.ArchiveRequest != nil {
		t.Fatalf("%+v", b)
	}
	// A helper ending done is archived on its word, as its starter may archive it.
	lead := seeded(t, d, t.TempDir(), nil)
	h := wire.Agent{AfterTurn: got.AfterTurn, Report: report, StartedByAgent: &lead.ID, Cwd: a.Cwd}
	if _, archiveNow := d.settleArchiveRequest(&h, wire.AgentStateFinished, wire.EndedReasonEndTurn, false); !archiveNow {
		t.Fatal("not archived")
	}
}

// #1802: a chat the person started archives itself when it ends done, as the person's
// setting allows by default; not when the turn showed a file, which stays unread under
// Done with nobody asked; and never when the turn wants the person.
func TestThePersonsChatArchivesItself(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "archive_session", nil); !strings.Contains(text, "as the person lets agents archive the chats they start") {
		t.Fatal(text)
	}
	after := d.Store.Agent(a.ID).AfterTurn
	done := &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "Done.", At: now()}
	mine := wire.Agent{ID: a.ID, AfterTurn: after, Report: done, State: wire.AgentStateFinished, Cwd: a.Cwd}
	if requested, archiveNow := d.settleArchiveRequest(&mine, wire.AgentStateFinished, wire.EndedReasonEndTurn, false); requested || !archiveNow {
		t.Fatal(requested, archiveNow)
	}
	shown := wire.Agent{ID: a.ID, AfterTurn: after, Report: done, State: wire.AgentStateFinished, Cwd: a.Cwd}
	if requested, archiveNow := d.settleArchiveRequest(&shown, wire.AgentStateFinished, wire.EndedReasonEndTurn, true); requested || archiveNow || shown.ArchiveRequest != nil {
		t.Fatalf("%v %v %+v", requested, archiveNow, shown.ArchiveRequest)
	}
	// A question takes the ask away (#1916: the only ending that wants the person).
	asked := wire.Agent{ID: a.ID, AfterTurn: after, Report: &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, At: now()}, State: wire.AgentStateFinished, Cwd: a.Cwd}
	if requested, archiveNow := d.settleArchiveRequest(&asked, wire.AgentStateFinished, wire.EndedReasonEndTurn, false); requested || archiveNow {
		t.Fatal(requested, archiveNow)
	}
	// A workflow's run goes by its workflow's when-done, not by the person's setting.
	run := "review"
	wf := wire.Agent{ID: a.ID, AfterTurn: after, Report: done, State: wire.AgentStateFinished, Cwd: a.Cwd, StartedByWorkflow: &run}
	if requested, archiveNow := d.settleArchiveRequest(&wf, wire.AgentStateFinished, wire.EndedReasonEndTurn, false); !requested || archiveNow {
		t.Fatal(requested, archiveNow)
	}
}

// #1802: show_file puts a mark on the row of a conversation nobody is watching, and reading
// it, or Mark as Read, takes the mark away.
func TestAShownFileIsAMarkUntilRead(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	a := seeded(t, d, dir, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	path := filepath.Join(dir, "report.md")
	if err := os.WriteFile(path, []byte("# Report\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "show_file", map[string]any{"path": path}); isErr {
		t.Fatal(text)
	}
	got := d.Store.Agent(a.ID)
	if got.FileToSee == nil || got.FileToSee.Path != path {
		t.Fatalf("%+v", got.FileToSee)
	}
	if g := Group(got); g == "needsAttention" {
		t.Fatal(g)
	}
	d.markRead(a.ID)
	if got := d.Store.Agent(a.ID); got.FileToSee != nil {
		t.Fatalf("%+v", got.FileToSee)
	}
}

func TestALeadStopsAndArchivesItsHelpers(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	title := func(s string) *string { return &s }
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Lead") })
	helper := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.StartedByAgent = title("Helper"), &lead.ID })
	below := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.StartedByAgent = title("Below"), &helper.ID })
	person := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Mine") })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "stop_session", map[string]any{"id": string(person.ID)}); !isErr ||
		text != "Nothing changed: that is one of the person's own sessions. You can only stop or archive sessions you started (also with manage_workflows run) and the sessions they started." {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "stop_session", map[string]any{"id": string(helper.ID)}); text != "“Helper” had already stopped; nothing changed." {
		t.Fatal(text)
	}
	// One below one it started is its to archive too.
	if text, _ := m.tool(4, "archive_session", map[string]any{"id": string(below.ID)}); text != "Archived “Below”, freeing its place; the person can unarchive it. This folder now has 0 of 3 running, 1 of 5 not archived." {
		t.Fatal(text)
	}
	if a := d.Store.Agent(below.ID); a.State != wire.AgentStateArchived || *a.ArchivedReason != wire.AgentArchivedReasonByAgent {
		t.Fatalf("%+v", a)
	}
	if n := names(d); !strings.Contains(strings.Join(n, " "), "agent.archived") {
		t.Fatal(n)
	}
	if e := logged(d)[0]; e.Name != "agent.archived" || e.Details["by"] != "agent" {
		t.Fatalf("%+v", e)
	}
}
