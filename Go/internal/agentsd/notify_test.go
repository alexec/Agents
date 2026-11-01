package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
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

// A notice's need is its line (#2860), so a tap on the banner goes to it, and the line
// says where it went: the computer once the window has it, then the device the control
// plane says, each once.
func TestNoticeLineSaysWhereItWent(t *testing.T) {
	was := settlingPause
	settlingPause = 0
	defer func() { settlingPause = was }()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	c.call(t, 2, "presence/report", map[string]any{"active": true})
	if text, _ := m.tool(3, "notify", map[string]any{"title": "The deploy finished"}); !strings.HasPrefix(text, "Sent.") {
		t.Fatal(text)
	}
	var pending wire.AttentionPending
	json.Unmarshal(c.call(t, 4, "attention/pending", nil), &pending)
	var need *wire.NeedID
	for _, n := range pending.Needs {
		if n.Kind == wire.NeedKindNotice {
			need = &n.ID
		}
	}
	if need == nil {
		t.Fatalf("%+v", pending.Needs)
	}
	told, _ := json.Marshal(wire.NoticeDelivered{Need: *need, To: wire.NoticeDeviceIPhone})
	d.Told(wire.NotifyNoticesDelivered.Name, told)
	d.Told(wire.NotifyNoticesDelivered.Name, told)
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	var line wire.UUID
	var went []wire.NoticeDevice
	for _, e := range entries {
		if e.Kind.Notified != nil {
			line = e.ID
		}
		if v := e.Kind.NoticeDelivered; v != nil {
			if v.Value.Notice != line {
				t.Fatalf("delivery of %s, line %s", v.Value.Notice, line)
			}
			went = append(went, v.Value.To)
		}
	}
	if string(line) != *need.Notice {
		t.Fatalf("need %s, line %s", *need.Notice, line)
	}
	if len(went) != 2 || went[0] != wire.NoticeDeviceComputer || went[1] != wire.NoticeDeviceIPhone {
		t.Fatalf("%v", went)
	}
}

// With a control plane (#2859), the person's one bucket there decides; Burst and Cool-down
// set in a client go into your layer (#2957) and are pushed on, as every change to it is
// (user/setPolicy), not by the old dedicated user/setNoticeLimits call, which is gone.
func TestNoticeLimitsFollowThePerson(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	policies := make(chan wire.YourPolicy, 8)
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		switch method {
		case wire.CallNoticesTake.Name:
			return mustJSON(wire.NoticeTaken{Sent: false, NextAt: wire.DateOf(time.Now().Add(time.Minute))}), nil
		case wire.CallUserSetPolicy.Name:
			signed := params.(wire.SignedYourPolicy)
			raw, _ := base64.StdEncoding.DecodeString(signed.Policy)
			var policy wire.YourPolicy
			json.Unmarshal(raw, &policy)
			policies <- policy
			return json.RawMessage(`{}`), nil
		}
		return nil, errors.New("no such method")
	})
	c.call(t, 1, "preferences/set", map[string]any{noticeBurstKey: 7, "other": true})
	// Burst 7 reaches the control plane in your layer's noticeLimits rule; an earlier push,
	// from the first-start move at connect, may arrive first and is skipped.
	deadline := time.After(5 * time.Second)
	for {
		select {
		case p := <-policies:
			if n := p.Rules.NoticeLimits; n != nil && n.Burst != nil && *n.Burst == 7 {
				goto gotBurst
			}
		case <-deadline:
			t.Fatal("burst 7 never reached the control plane")
		}
	}
gotBurst:
	// The control plane's bucket is empty, though this host's is full.
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "notify", map[string]any{"title": "Done"}); !strings.HasPrefix(text, "In the cool-down") {
		t.Fatal(text)
	}
	// A control plane that cannot be asked leaves this host's own bucket to decide.
	d.SetControlAsk(func(context.Context, string, any) (json.RawMessage, error) { return nil, errors.New("gone") })
	if text, _ := m.tool(3, "notify", map[string]any{"title": "Done"}); !strings.HasPrefix(text, "Sent. 6 more") {
		t.Fatal(text)
	}
	if prefs := d.preferences(); string(prefs["other"]) != "true" {
		t.Fatalf("%s", prefs)
	}
}
