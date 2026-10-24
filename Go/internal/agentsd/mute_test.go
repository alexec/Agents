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

// Mute Notifications (#2003): a muted session's need is offered to no control plane and
// shown on no surface, yet stays in Needs you and the count; unmuted, it goes as before.
func TestAMutedSessionNeedsYouWithoutAPush(t *testing.T) {
	shortPause(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	yes := true
	report := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		title := "Noisy run"
		a.Title, a.IsMuted = &title, &yes
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, Message: "Which branch?", At: now()}
	})
	control := &toldControl{}
	d.SetControl(control.tell)
	offer := func(m wire.AttentionNeed) bool {
		return m.Need != nil && m.Need.ID.Report != nil && m.Need.ID.Report.AgentID == report.ID
	}
	if control.find(offer) != nil {
		t.Fatalf("a muted session was offered: %+v", control.sent)
	}
	counted := control.find(func(m wire.AttentionNeed) bool { return m.Waiting != nil && *m.Waiting == 1 })
	if counted == nil {
		t.Fatalf("the count left it out: %+v", control.sent)
	}
	if n := d.attentionPending().Needs; len(n) != 1 {
		t.Fatalf("not in Needs you: %+v", n)
	}
	before := d.Store.Agent(report.ID).LastActivityAt
	c.call(t, 1, "agents/setMuted", map[string]any{"agentID": report.ID, "muted": false})
	waitFor(t, "offered once unmuted", func() bool { return control.find(offer) != nil })
	if a := d.Store.Agent(report.ID); a.IsMuted != nil || a.LastActivityAt != before {
		t.Fatalf("%+v moved from %v", a, before)
	}
	// Muted again: withdrawn.
	c.call(t, 2, "agents/setMuted", map[string]any{"agentID": report.ID, "muted": true})
	waitFor(t, "withdrawn once muted", func() bool {
		return control.find(func(m wire.AttentionNeed) bool { return m.Withdraw != nil && m.Withdraw.Report != nil }) != nil
	})
	if e := c.callError(t, 3, "agents/setMuted", map[string]any{"agentID": "00000000-0000-0000-0000-000000000000", "muted": true}); e == nil {
		t.Fatal("muted a session that is not there")
	}
}

// At the window, a muted session's need goes to no surface: the Mac posts no notification.
func TestAMutedSessionSendsTheMacNoNotification(t *testing.T) {
	shortPause(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	c.call(t, 1, "presence/report", map[string]any{"active": true})
	yes := true
	report := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.IsMuted = &yes
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, Message: "Which branch?", At: now()}
	})
	d.reconsider()
	var told wire.AttentionNotification
	c.until(t, "the need told", attentionNote(func(n wire.AttentionNotification) bool {
		told = n
		return n.Need != nil && n.Need.AgentID != nil && *n.Need.AgentID == report.ID
	}))
	if told.To != nil || told.Alert {
		t.Fatalf("a muted need was delivered: %+v", told)
	}
	// Unmuted, it goes to the window after the pause.
	c.call(t, 2, "agents/setMuted", map[string]any{"agentID": report.ID, "muted": false})
	c.until(t, "the window told", attentionNote(func(n wire.AttentionNotification) bool {
		return n.Need != nil && n.To != nil && n.To.Mac != nil && n.Alert
	}))
}

// A workflow's mute is `muted: true` in its file: its runs not archived take it, and so
// do the runs it starts.
func TestMutingAWorkflowMutesItsRuns(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	wfDir := filepath.Join(dir, ".agents", "workflows")
	if err := os.MkdirAll(wfDir, 0o750); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(wfDir, "nightly.md")
	if err := os.WriteFile(path, []byte("---\nname: Nightly\n---\n\nGo.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	id, other := "nightly", "daily"
	run := seeded(t, d, dir, func(a *wire.Agent) { a.StartedByWorkflow = &id })
	byUser := wire.AgentArchivedReasonByUser
	archived := seeded(t, d, dir, func(a *wire.Agent) {
		a.StartedByWorkflow, a.State, a.ArchivedReason = &id, wire.AgentStateArchived, &byUser
	})
	stranger := seeded(t, d, dir, func(a *wire.Agent) { a.StartedByWorkflow = &other })
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/setMuted", map[string]any{"folder": store.FolderURL(dir), "workflowID": id, "muted": true}), &s)
	if s.Workflow.Muted == nil || !*s.Workflow.Muted {
		t.Fatalf("%+v", s.Workflow)
	}
	if text, _ := os.ReadFile(path); !strings.Contains(string(text), "muted: true") {
		t.Fatalf("%s", text)
	}
	muted := func(a wire.Agent) bool { b := d.Store.Agent(a.ID).IsMuted; return b != nil && *b }
	if !muted(run) || muted(archived) || muted(stranger) {
		t.Fatalf("run %v archived %v stranger %v", muted(run), muted(archived), muted(stranger))
	}
	json.Unmarshal(c.call(t, 3, "workflows/setMuted", map[string]any{"folder": store.FolderURL(dir), "workflowID": id, "muted": false}), &s)
	if text, _ := os.ReadFile(path); s.Workflow.Muted != nil || strings.Contains(string(text), "muted") || muted(run) {
		t.Fatalf("%+v %s", s.Workflow, text)
	}
	if w := parseWorkflow("---\nmuted: loud\n---\nGo", "x", "/p"); w.Problem == nil || w.Problem.Unreadable == nil ||
		!strings.HasPrefix(w.Problem.Unreadable.Value, "`muted:` must be true or false") {
		t.Fatalf("%+v", w.Problem)
	}
}
