package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The person's attention (#2805): a burst, then one notice back each cool-down, never
// the whole burst at the end of one.
func TestNoticesComeBackOneAtATime(t *testing.T) {
	d := &Daemon{}
	at := time.Unix(1_000_000, 0)
	for i := 2; i >= 0; i-- {
		left, next, ok := d.takeNotice(at, 3, 10*time.Minute)
		if !ok || left != i || !next.Equal(at.Add(10*time.Minute)) {
			t.Fatalf("notice %d: %v %d %v", 3-i, ok, left, next)
		}
	}
	if _, next, ok := d.takeNotice(at.Add(4*time.Minute), 3, 10*time.Minute); ok || !next.Equal(at.Add(10*time.Minute)) {
		t.Fatalf("in the cool-down: %v %v", ok, next)
	}
	// Ten minutes on, one came back, and only one.
	if left, _, ok := d.takeNotice(at.Add(10*time.Minute), 3, 10*time.Minute); !ok || left != 0 {
		t.Fatalf("one back: %v %d", ok, left)
	}
	if _, next, ok := d.takeNotice(at.Add(11*time.Minute), 3, 10*time.Minute); ok || !next.Equal(at.Add(20*time.Minute)) {
		t.Fatalf("the next: %v %v", ok, next)
	}
	// A quiet time of burst × cool-down fills it, and no more.
	if left, _, ok := d.takeNotice(at.Add(time.Hour), 3, 10*time.Minute); !ok || left != 2 {
		t.Fatalf("full again: %v %d", ok, left)
	}
}

func TestNotifyingThePerson(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	if _, err := d.setPreferences(map[string]wire.JSONValue{noticeBurstKey: json.RawMessage("2")}); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "notify", map[string]any{"title": " "}); !isErr || !strings.HasPrefix(text, "Nothing was sent") {
		t.Fatal(text)
	}
	if text, _ := m.tool(3, "notify", map[string]any{"title": "The deploy finished", "body": "All three regions are green."}); !strings.HasPrefix(text, "Sent. 1 more can go now") {
		t.Fatal(text)
	}
	if text, _ := m.tool(4, "notify", map[string]any{"title": "The tests passed"}); !strings.HasPrefix(text, "Sent. 0 more") {
		t.Fatal(text)
	}
	if text, _ := m.tool(5, "notify", map[string]any{"title": "One too many"}); !strings.HasPrefix(text, "In the cool-down: the next notice can go at ") {
		t.Fatal(text)
	}
	// Posted as needs, not Needs you rows: the badge's count does not move.
	var pending wire.AttentionPending
	json.Unmarshal(c.call(t, 6, "attention/pending", nil), &pending)
	var notices []wire.Need
	for _, n := range pending.Needs {
		if n.Kind == wire.NeedKindNotice {
			notices = append(notices, n)
		}
	}
	if len(notices) != 2 || notices[0].Headline.H3 != "The deploy finished — All three regions are green." || *notices[0].AgentID != a.ID {
		t.Fatalf("%+v", pending.Needs)
	}
	if n := d.waitingCount(); n != 0 {
		t.Fatalf("waiting %d", n)
	}
	var outcomes []wire.NoticeOutcome
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	for _, e := range entries {
		if e.Kind.Notified != nil {
			outcomes = append(outcomes, e.Kind.Notified.Value.Outcome)
		}
	}
	if len(outcomes) != 3 || outcomes[0] != wire.NoticeOutcomeSent || outcomes[2] != wire.NoticeOutcomeCoolingDown {
		t.Fatalf("%v", outcomes)
	}
	if got := d.Store.Agent(a.ID); got.IsUnread == nil || !*got.IsUnread {
		t.Fatal("not unread")
	}
	// Opening the chat takes its notices down, and one sent while it is open is shown there.
	c.call(t, 7, "presence/report", map[string]any{"active": true, "watching": a.ID})
	json.Unmarshal(c.call(t, 8, "attention/pending", nil), &pending)
	for _, n := range pending.Needs {
		if n.Kind == wire.NeedKindNotice {
			t.Fatalf("still posted: %+v", n)
		}
	}
	if text, _ := m.tool(9, "notify", map[string]any{"title": "Seen"}); !strings.HasPrefix(text, "Not sent as a notification") {
		t.Fatal(text)
	}
}
