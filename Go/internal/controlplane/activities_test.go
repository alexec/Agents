package controlplane

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

const (
	activityAgent = "A0000000-0000-4000-8000-000000000001"
	// An activity's APNs token, made up.
	activityToken = "b1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90" //nolint:gosec // not a credential
)

func activityState(t *testing.T, push apns.Push) turnActivityState {
	t.Helper()
	if push.Activity == nil {
		t.Fatal("not a Live Activity push")
	}
	var state turnActivityState
	if err := json.Unmarshal(push.Activity.State, &state); err != nil {
		t.Fatal(err)
	}
	return state
}

// A phone gives its activity's token; its host says the turn asks, is answered, and ends:
// each goes to the activity by APNs, with no words, and the end forgets the token (#1744).
func TestATurnUpdatesItsLiveActivityByPush(t *testing.T) {
	t.Parallel()
	pusher := &fakePusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	box := p.host("MACHINE-2")
	m, phone := p.phoneWithToken()
	call(t, phone, "", "clients/setActivityToken", map[string]any{"agentID": strings.ToLower(activityAgent),
		"token": strings.ToUpper(activityToken), "environment": "development", "startedAt": 800000000})
	tokens := p.s.Records().Client(m.Client).ActivityTokens
	if len(tokens) != 1 || tokens[0].Agent != activityAgent || tokens[0].Token != activityToken || tokens[0].StartedAt != 800000000 {
		t.Fatal(tokens)
	}

	say := func(turn string) {
		if _, err := p.s.methods.HostSaid(box.member.Host, "attention/turn", json.RawMessage(turn)); err != nil {
			t.Fatal(err)
		}
	}
	say(`{"agentID":"` + activityAgent + `","phase":"approval"}`)
	say(`{"agentID":"` + activityAgent + `","phase":"working"}`)
	say(`{"agentID":"` + activityAgent + `","phase":"done","endedAt":800000300}`)
	p.waitFor(func() bool { return len(pusher.sent()) == 3 }, "three pushes")
	sent := pusher.sent()
	for _, push := range sent {
		if push.Token != activityToken || push.Environment != wire.PushEnvironmentDevelopment {
			t.Fatal(push)
		}
		if body := string(push.Payload()); strings.Contains(body, "title") || strings.Contains(body, "line") {
			t.Fatal("words in the clear:", body)
		}
	}
	if s := activityState(t, sent[0]); s.Phase != "approval" || s.StartedAt != 800000000 || s.EndedAt != nil ||
		!sent[0].Activity.Urgent || sent[0].Activity.End {
		t.Fatal(s, sent[0].Activity)
	}
	if s := activityState(t, sent[1]); s.Phase != "working" || sent[1].Activity.Urgent {
		t.Fatal(s)
	}
	end := sent[2].Activity
	if s := activityState(t, sent[2]); s.Phase != "done" || s.EndedAt == nil || *s.EndedAt != 800000300 || !end.End ||
		end.Dismiss.Sub(end.Timestamp) != keptAfterEnd {
		t.Fatal(s, end)
	}
	if tokens := p.s.Records().Client(m.Client).ActivityTokens; len(tokens) != 0 {
		t.Fatal("kept after the end:", tokens)
	}

	// Another session's turn reaches no activity.
	say(`{"agentID":"A0000000-0000-4000-8000-000000000002","phase":"working"}`)
	time.Sleep(100 * time.Millisecond)
	if n := len(pusher.sent()); n != 3 {
		t.Fatal(n)
	}
}

// An archived session's activity ends at once; a token Apple says is gone is forgotten;
// no token takes one away; and only a device sets one.
func TestLiveActivityTokensComeAndGo(t *testing.T) {
	t.Parallel()
	pusher := &fakePusher{answer: apns.ErrGone}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	_, window := p.client("window")
	set := map[string]any{"agentID": activityAgent, "token": activityToken, "environment": "production", "startedAt": 800000000}
	if e := callError(t, window, "", "clients/setActivityToken", set); !strings.Contains(e, "iPhone") {
		t.Fatal(e)
	}
	box := p.host("MACHINE-2")
	m, phone := p.phoneWithToken()
	if e := callError(t, phone, "", "clients/setActivityToken", map[string]any{"agentID": activityAgent, "token": "nope",
		"environment": "production", "startedAt": 0}); !strings.Contains(e, "not a push token") {
		t.Fatal(e)
	}

	say := func(turn string) {
		if _, err := p.s.methods.HostSaid(box.member.Host, "attention/turn", json.RawMessage(turn)); err != nil {
			t.Fatal(err)
		}
	}
	call(t, phone, "", "clients/setActivityToken", set)
	say(`{"agentID":"` + activityAgent + `","phase":"question"}`)
	p.waitFor(func() bool { return len(p.s.Records().Client(m.Client).ActivityTokens) == 0 }, "the gone token forgotten")

	pusher.mu.Lock()
	pusher.answer = nil
	pusher.mu.Unlock()
	call(t, phone, "", "clients/setActivityToken", set)
	say(`{"agentID":"` + activityAgent + `","phase":"gone"}`)
	p.waitFor(func() bool { return len(pusher.sent()) == 2 }, "the end")
	end := pusher.sent()[1].Activity
	if !end.End || !end.Dismiss.Equal(end.Timestamp) {
		t.Fatal(end)
	}

	call(t, phone, "", "clients/setActivityToken", set)
	call(t, phone, "", "clients/setActivityToken", map[string]any{"agentID": activityAgent, "environment": "production", "startedAt": 800000000})
	if tokens := p.s.Records().Client(m.Client).ActivityTokens; len(tokens) != 0 {
		t.Fatal("not taken away:", tokens)
	}
}

// A phone shows one activity for every turn sent from it (#2991): the same token for two
// sessions. Each push says the summary: the session that asks, the count of the others,
// and the timer from the oldest; a session that ends leaves, and the last end ends it.
func TestOneLiveActivitySpeaksForEveryTurn(t *testing.T) {
	t.Parallel()
	const other = "A0000000-0000-4000-8000-000000000002"
	pusher := &fakePusher{}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.Push = pusher })
	box := p.host("MACHINE-2")
	m, phone := p.phoneWithToken()
	for agent, started := range map[string]int{activityAgent: 800000000, other: 800000100} {
		call(t, phone, "", "clients/setActivityToken", map[string]any{"agentID": agent, "token": activityToken,
			"environment": "development", "startedAt": started})
	}
	if tokens := p.s.Records().Client(m.Client).ActivityTokens; len(tokens) != 2 {
		t.Fatal(tokens)
	}

	say := func(turn string) {
		if _, err := p.s.methods.HostSaid(box.member.Host, "attention/turn", json.RawMessage(turn)); err != nil {
			t.Fatal(err)
		}
	}
	say(`{"agentID":"` + other + `","phase":"working"}`)
	say(`{"agentID":"` + activityAgent + `","phase":"approval"}`)
	say(`{"agentID":"` + activityAgent + `","phase":"done","endedAt":800000300}`)
	say(`{"agentID":"` + other + `","phase":"failed","endedAt":800000400}`)
	p.waitFor(func() bool { return len(pusher.sent()) == 4 }, "four pushes")
	sent := pusher.sent()
	for _, push := range sent {
		if push.Token != activityToken {
			t.Fatal(push)
		}
		if body := string(push.Payload()); strings.Contains(body, "title") || strings.Contains(body, "line") ||
			strings.Contains(body, "place") {
			t.Fatal("words in the clear:", body)
		}
	}
	// Both work: the newest is shown, the other counted, the timer from the oldest.
	if s := activityState(t, sent[0]); s.Phase != "working" || s.AgentID != other || s.OthersWorking != 1 ||
		s.OthersAsking != 0 || s.StartedAt != 800000000 || sent[0].Activity.Urgent || sent[0].Activity.End {
		t.Fatal(s, sent[0].Activity)
	}
	// The older one asks: it is shown, urgently.
	if s := activityState(t, sent[1]); s.Phase != "approval" || s.AgentID != activityAgent || s.OthersWorking != 1 ||
		!sent[1].Activity.Urgent {
		t.Fatal(s)
	}
	// It ends while the other works: it leaves, and the activity goes on.
	if s := activityState(t, sent[2]); s.Phase != "working" || s.AgentID != other || s.OthersWorking != 0 ||
		s.StartedAt != 800000100 || s.EndedAt != nil || sent[2].Activity.End {
		t.Fatal(s, sent[2].Activity)
	}
	// The last one ends it, with its own end.
	end := sent[3].Activity
	if s := activityState(t, sent[3]); s.Phase != "failed" || s.AgentID != other || s.EndedAt == nil ||
		*s.EndedAt != 800000400 || !end.End {
		t.Fatal(s, end)
	}
	if tokens := p.s.Records().Client(m.Client).ActivityTokens; len(tokens) != 0 {
		t.Fatal("kept after the end:", tokens)
	}
}
