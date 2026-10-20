package agentsd

import (
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports SessionLookupTests, SessionHistoryTests and AgentMessageTests: the project's
// sessions listed and read in SessionLookup's words, and a message from one to another
// that wakes it, with the loop guard and the archived refused.

func TestReadingAndMessagingSessions(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	titled := func(title string) func(*wire.Agent) { return func(a *wire.Agent) { a.Title = &title } }
	lead := seeded(t, d, dir, titled("Lead"))
	helper := seeded(t, d, dir, titled("Helper"))
	gone := seeded(t, d, dir, func(a *wire.Agent) {
		title, by, at := "Old", wire.AgentArchivedReasonByUser, now()
		a.Title, a.State, a.ArchivedReason, a.ArchivedAt = &title, wire.AgentStateArchived, &by, &at
	})
	seeded(t, d, t.TempDir(), titled("Elsewhere"))
	person := wire.PromptOriginPerson
	d.record(helper.ID, wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "Fix the login", From: &person}})
	id := "m1"
	d.record(helper.ID, wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &id, Text: "I fixed "}})
	d.record(helper.ID, wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: &id, Text: "it."}})

	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	text, _ := m.tool(2, "list_sessions", map[string]any{"limit": 2})
	if !strings.HasPrefix(text, "Sessions in this project, not archived first, most recent first.") ||
		!strings.Contains(text, string(lead.ID)+": “Lead” (you) — Claude, Done, last active ") ||
		strings.Contains(text, "Elsewhere") || strings.Contains(text, string(gone.ID)) ||
		!strings.Contains(text, "\n\n1 more, all archived. For the next page, call list_sessions with after: \"") {
		t.Fatal(text)
	}
	text, _ = m.tool(3, "read_session", map[string]any{"session": "Helper"})
	if !strings.HasPrefix(text, "# Session “Helper”\n\n- Id: "+string(helper.ID)+"\n- Runtime: Claude\n- Status: Done\n") ||
		!strings.Contains(text, "## The conversation\n\n**The person:** Fix the login\n**Claude:** I fixed it.\n") {
		t.Fatal(text)
	}
	if text, _ := m.tool(4, "read_session", map[string]any{"session": "Nobody"}); text != "There is no session named “Nobody” in this project." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(5, "message_session", map[string]any{"to": "Old", "message": "hi"}); !isErr || text != "Nothing was sent: “Old” is archived. Only the person can unarchive it." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(6, "message_session", map[string]any{"to": "Lead", "message": "hi"}); !isErr || text != "Nothing was sent: that is this session." {
		t.Fatal(text)
	}
	text, _ = m.tool(7, "message_session", map[string]any{"to": string(helper.ID), "message": "Run the tests too"})
	if text != "Sent to “Helper”, which is working on it now. A reply, if it sends one, comes to this session as a message." {
		t.Fatal(text)
	}
	waitFor(t, "the message in its chat", func() bool {
		u := userMessages(d, helper.ID)
		return u[len(u)-1] == "Run the tests too"
	})
	entries, _, _ := d.Store.Transcript(helper.ID, 0)
	var sender *wire.MessageSender
	for _, e := range entries {
		if e.Kind.UserMessage != nil && e.Kind.UserMessage.Value == "Run the tests too" {
			sender = e.Sender
		}
	}
	if sender == nil || sender.Title != "Lead" {
		t.Fatalf("%+v", sender)
	}
	if n := names(d); !strings.Contains(strings.Join(n, " "), "agent.messaged") {
		t.Fatal(n)
	}
	waitFor(t, "its turn over", func() bool { return d.Store.Agent(helper.ID).State == wire.AgentStateFinished })
	// A chain of three messages with no word from the person is the most.
	d.messageMu.Lock()
	d.messageHops = map[wire.UUID]int{lead.ID: 3}
	d.messageMu.Unlock()
	if text, isErr := m.tool(8, "message_session", map[string]any{"to": "Helper", "message": "again"}); !isErr ||
		!strings.HasPrefix(text, "Nothing was sent: this turn began with the third message in a row between agents") {
		t.Fatal(text)
	}
}

// The count of messages in a row starts again when wait_for_event or a workflow's trigger
// starts a turn, as the person's words do; the app's other words leave it (#1728).
func TestEventAndTriggerTurnsStartTheHopCountAgain(t *testing.T) {
	fakeRuntimes(t)
	was := eventHoldLimit
	eventHoldLimit = 300 * time.Millisecond
	defer func() { eventHoldLimit = was }()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	go func() {
		for range c.out {
		}
	}()
	dir := t.TempDir()
	lead := seeded(t, d, dir, titledAs("Lead"))
	seeded(t, d, dir, titledAs("Peer"))
	// A turn's new process drops the app's token, so each call has a client of its own.
	tool := func(name string, args map[string]any) (string, bool) {
		m := appClient(t, d, lead.ID)
		m.post("initialize", map[string]any{}, 1)
		return m.tool(2, name, args)
	}
	atTheLimit := func() {
		d.messageMu.Lock()
		d.messageHops = map[wire.UUID]int{lead.ID: messageHopLimit}
		d.messageMu.Unlock()
	}
	hops := func() int {
		d.messageMu.Lock()
		defer d.messageMu.Unlock()
		return d.messageHops[lead.ID]
	}
	turn := func(text string, queue func()) {
		t.Helper()
		queue()
		waitFor(t, "the turn in its chat", func() bool {
			for _, u := range userMessages(d, lead.ID) {
				if strings.HasPrefix(u, text) {
					return true
				}
			}
			return false
		})
		waitFor(t, "its turn over", func() bool { return d.Store.Agent(lead.ID).State == wire.AgentStateFinished })
	}

	// The app's own words leave the count where it was, and a message is refused.
	atTheLimit()
	turn("A lease note", func() {
		if err := d.promptFromApp(lead.ID, "A lease note"); err != nil {
			t.Fatal(err)
		}
	})
	if n := hops(); n != messageHopLimit {
		t.Fatal(n)
	}
	if text, isErr := tool("message_session", map[string]any{"to": "Peer", "message": "again"}); !isErr ||
		!strings.HasPrefix(text, "Nothing was sent: this turn began with the third message in a row between agents") {
		t.Fatal(text)
	}

	// A workflow's trigger starts it again.
	atTheLimit()
	turn("Triggered", func() {
		if err := d.promptFromTrigger(lead.ID, "Triggered"); err != nil {
			t.Fatal(err)
		}
	})
	if n := hops(); n != 0 {
		t.Fatal(n)
	}
	d.messageMu.Lock()
	marks := len(d.triggerPrompts)
	d.messageMu.Unlock()
	if marks != 0 {
		t.Fatal(marks)
	}

	// So does a wake by wait_for_event.
	text, _ := tool("wait_for_event", map[string]any{"events": "branch.moved", "until_minutes": 10})
	if !strings.HasPrefix(text, "Still waiting for branch.moved") {
		t.Fatal(text)
	}
	atTheLimit()
	turn("The event you were waiting for happened.", func() {
		d.raise(wire.EventDraft{Name: "branch.moved", At: now(), Scope: projectScope(dir), Sentence: "cd moved.", Details: map[string]string{"branch": "cd"}})
	})
	if n := hops(); n != 0 {
		t.Fatal(n)
	}
}
