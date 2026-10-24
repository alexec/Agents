package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports AttentionTests' cases for a host with no devices: what is a need, when the window
// is told, watching silences it, a look reads it, and the notes outlive a restart.

func shortPause(t *testing.T) {
	old := settlingPause
	settlingPause = 150 * time.Millisecond
	t.Cleanup(func() { settlingPause = old })
}

func attentionNote(want func(wire.AttentionNotification) bool) func(string, json.RawMessage) bool {
	return func(method string, p json.RawMessage) bool {
		var n wire.AttentionNotification
		return method == "attention/changed" && json.Unmarshal(p, &n) == nil && want(n)
	}
}

func TestACardReachesTheWindowAfterThePause(t *testing.T) {
	fakeRuntimes(t)
	shortPause(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	c.call(t, 1, "presence/report", map[string]any{"active": true})
	id := startAgent(t, c, 2, t.TempDir(), "Please ask, then write hi.txt")
	var card wire.PermissionRequest
	c.until(t, "a card", func(method string, p json.RawMessage) bool {
		var n wire.PermissionNotification
		if method == "agent/permission" && json.Unmarshal(p, &n) == nil && n.Request != nil {
			card = *n.Request
			return true
		}
		return false
	})
	var told wire.AttentionNotification
	c.until(t, "the window told", attentionNote(func(n wire.AttentionNotification) bool {
		told = n
		return n.Need != nil && n.To != nil
	}))
	if told.To == nil || told.To.Mac == nil || !told.Alert || told.Need.Kind != wire.NeedKindPermission ||
		told.Need.Headline.H3 != "Wants to Write hi.txt" || *told.Need.AgentID != id {
		t.Fatalf("%+v %+v", told, told.Need)
	}
	if a := told.Need.Headline.Answers; len(a) != 2 || a[0].ID != "allow" || a[0].IsDestructive || !a[1].IsDestructive {
		t.Fatalf("%+v", a)
	}
	var pending wire.AttentionPending
	json.Unmarshal(c.call(t, 3, "attention/pending", nil), &pending)
	if len(pending.Needs) != 1 || len(pending.Deliveries) != 1 {
		t.Fatalf("%+v", pending)
	}
	// Answered: withdrawn, by its id alone.
	c.in <- `{"jsonrpc":"2.0","id":4,"method":"permissions/answer","params":{"permissionID":"` + string(card.ID) + `","optionID":"allow"}}`
	c.until(t, "withdrawn", attentionNote(func(n wire.AttentionNotification) bool {
		return n.Need == nil && n.NeedID.Permission != nil && *n.NeedID.Permission == card.ID
	}))
	waitFor(t, "the turn's end", func() bool { return d.Store.Agent(id).State == wire.AgentStateFinished })
}

// A need shown on no surface is still told to every client, and so is its end (#1367): a
// phone's Needs you and the widget it writes are drawn from what it was told, and a change
// kept on the Mac must leave both.
func TestEveryClientHearsANeedShownNowhereAndItsEnd(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.WriteFile(filepath.Join(dir, "a.md"), nil, 0o644)
	c.call(t, 2, "pins/pin", map[string]any{"folder": folder, "path": "a.md"})
	worker := seeded(t, d, dir, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateRunning, nil
	})
	os.WriteFile(filepath.Join(dir, ".agents", "pins.json"), []byte(`{"pins":[]}`), 0o644)
	d.readPins(dir)
	var told wire.AttentionNotification
	c.until(t, "the change told", attentionNote(func(n wire.AttentionNotification) bool {
		told = n
		return n.Need != nil
	}))
	if told.To != nil || told.Alert || told.Need.Kind != wire.NeedKindGuardedChange || told.Need.AgentID == nil ||
		*told.Need.AgentID != worker.ID || told.NeedID.GuardedChange == nil {
		t.Fatalf("%+v %+v", told, told.Need)
	}
	// Told once, however often it is looked at again.
	d.reconsider()
	// Kept: every client hears it is over, by its id alone.
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 3, "folders/readGuardedChange", map[string]any{"folder": folder, "path": ".agents/pins.json"}), &reading)
	c.in <- `{"jsonrpc":"2.0","id":4,"method":"approvals/answer","params":{"folder":"` + string(folder) +
		`","kind":"file","key":".agents/pins.json","digest":"` + *reading.Digest + `","action":"approve"}}`
	c.until(t, "the change over", attentionNote(func(n wire.AttentionNotification) bool {
		if n.Need != nil {
			t.Fatalf("told again: %+v", n.Need)
		}
		return n.NeedID.GuardedChange != nil && n.NeedID.GuardedChange.Path == ".agents/pins.json"
	}))
	if n := d.attentionPending().Needs; len(n) != 0 {
		t.Fatalf("%+v", n)
	}
}

func TestWatchingSilencesItAndALookReadsAReport(t *testing.T) {
	shortPause(t)
	root := t.TempDir()
	d, c := start(t, root)
	report := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		title := "Fix login"
		yes := true
		a.Title, a.IsUnread = &title, &yes
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, Message: "Which branch?", At: now()}
	})
	pending := d.attentionPending()
	if len(pending.Needs) != 1 || pending.Needs[0].Kind != wire.NeedKindReport || pending.Needs[0].Headline.H3 != "Waiting on your answer: Which branch?" ||
		pending.Needs[0].Headline.H2 != "Fix login" {
		t.Fatalf("%+v", pending)
	}
	raised := pending.Needs[0].RaisedAt
	// The first-seen time survives a restart.
	d.reconsider()
	d.Shutdown()
	b, _ := os.ReadFile(filepath.Join(root, "attention.json"))
	if !strings.Contains(string(b), `"raised":[{"at":"20`) {
		t.Fatalf("%s", b)
	}
	d2, c2 := start(t, root)
	defer d2.Shutdown()
	if p := d2.attentionPending(); len(p.Needs) != 1 || p.Needs[0].RaisedAt-raised > 0.001 || raised-p.Needs[0].RaisedAt > 0.001 {
		t.Fatalf("raised %v then %v", raised, p.Needs[0].RaisedAt)
	}
	_ = c
	// A window that comes to watch it has read it: not a need any more.
	c2.call(t, 1, "presence/report", map[string]any{"active": true, "watching": report.ID})
	waitFor(t, "read", func() bool { return len(d2.attentionPending().Needs) == 0 })
	if a := d2.Store.Agent(report.ID); *a.IsUnread || a.ReportSeenAt == nil || *a.ReportSeenAt != a.Report.At {
		t.Fatalf("%+v", a)
	}
}

func TestQuickAnswersForAForm(t *testing.T) {
	two, _ := parseElicitation(json.RawMessage(`{"message":"Colour?","requestedSchema":{"propertyOrder":["question_0","question_0_custom"],"properties":{"question_0":{"type":"string","enum":["red","blue"]},"question_0_custom":{"type":"string"}}}}`), "A")
	if a := formAnswers(two); len(a) != 2 || *a[0].Field != "question_0" || a[1].Title != "blue" {
		t.Fatalf("%+v", a)
	}
	free, _ := parseElicitation(json.RawMessage(`{"message":"Name?","requestedSchema":{"properties":{"name":{"type":"string"}}}}`), "A")
	if a := formAnswers(free); len(a) != 1 || a[0].Kind != wire.QuickAnswerKindReply || a[0].Title != "Reply" {
		t.Fatalf("%+v", a)
	}
	many, _ := parseElicitation(json.RawMessage(`{"message":"x","requestedSchema":{"properties":{"a":{"type":"boolean"}}}}`), "A")
	if formAnswers(many) != nil {
		t.Fatal("a yes or no is not a quick answer")
	}
	h := truncating(wire.Headline{H1: " ", H2: "", H3: strings.Repeat("x", 120)})
	if h.H1 != "Agents" || h.H2 != "An agent" || len([]rune(h.H3)) != 100 || !strings.HasSuffix(h.H3, "…") {
		t.Fatalf("%+v", h)
	}
}

// The push's waiting count is what needs the person; an unread finish is only a mark
// on its row (#1565).
func TestWaitingCountLeavesOutUnreadFinishes(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	yes := true
	seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.IsUnread = &yes
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "Done.", At: now()}
	})
	if n := d.waitingCount(); n != 0 {
		t.Fatalf("an unread finish was counted: %d", n)
	}
	seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeNeedsAnswer, Message: "Which branch?", At: now()}
	})
	if n := d.waitingCount(); n != 1 {
		t.Fatalf("a question was not counted: %d", n)
	}
}
