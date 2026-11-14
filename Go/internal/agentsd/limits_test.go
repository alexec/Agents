package agentsd

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Ports LimitRecognitionTests and the pool's refusals: a refusal's words say spent, credit
// gone or rate limited; spent and gone take the runtime out of the pool and stop the agent.

func TestALimitInWords(t *testing.T) {
	c := func(n int) *int { return &n }
	for _, tc := range []struct {
		runtime   string
		code      *int
		msg, said string
		want      limitKind
	}{
		{"claude", c(-32603), "Internal error: You've hit your session limit · resets 5pm", "", limitSpent},
		{"codex", c(-32603), "insufficient_quota", "", limitCreditGone},
		{"codex", c(429), "Too many requests", "", limitRateLimited},
		{"codex", c(-32603), "You have exhausted your daily quota", "", limitSpent},
		{"copilot", nil, "", "You have exceeded your monthly quota for premium requests.", limitSpent},
		{"grok", nil, "", "Error: Usage balance exhausted", limitSpent},
		{"opencode", nil, "", "Free usage limit reached. Free models work in OpenCode (https://opencode.ai)", limitSpent},
		{"claude", nil, "", "You've hit your limit, says the doc I read.", limitNone},
		{"antigravity", nil, "", "Resource has been exhausted (e.g. check quota).", limitRateLimited},
	} {
		if got := classifyLimit(tc.runtime, nil, nil, tc.code, tc.msg, tc.said).kind; got != tc.want {
			t.Errorf("%s %q %q: %v", tc.runtime, tc.msg, tc.said, got)
		}
	}
}

func TestACreditGoneStopsTheAgent(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "spend it all"}), &id)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if r := d.Store.Agent(id).EndedReason; r == nil || *r != wire.EndedReasonAllowanceSpent {
		t.Fatal(r)
	}
	var allow wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &allow)
	b, _ := json.Marshal(allow)
	if !strings.Contains(string(b), `"why":"creditUsedUp"`) {
		t.Fatalf("%s", b)
	}
	if n := names(d); !strings.Contains(strings.Join(n, " "), "cost.allowance_out") {
		t.Fatal(n)
	}
}

// The typed layer and the plan window (SessionFailure, RateLimitInfo): a limit with no
// action is spent, one with retry a rate limit, another kind only said.
func TestATypedFailureAndAPlanWindow(t *testing.T) {
	f := failureIn(map[string]any{"jetbrains": map[string]any{"air": map[string]any{"sessionFailure": map[string]any{
		"id": "f", "revision": 2.0, "category": "limit", "title": "Spent", "actions": []any{"retry"}}}}})
	if f == nil || f.Revision != 2 || !f.isError() || classifyLimit("claude", f, nil, nil, "", "").kind != limitRateLimited {
		t.Fatal(f)
	}
	f.Actions = nil
	reset := float64(time.Now().Add(time.Hour).Unix())
	w := rateLimitIn(map[string]any{"_claude/rateLimit": map[string]any{"status": "rejected", "resetsAt": reset}})
	if l := classifyLimit("claude", f, w, nil, "", ""); l.kind != limitSpent || l.resetsAt == nil || int64(l.resetsAt.Time().Unix()) != int64(reset) {
		t.Fatal(l)
	}
	f.Category = "access"
	if classifyLimit("claude", f, nil, nil, "", "").kind != limitOtherTyped {
		t.Fatal("access")
	}
	if (&sessionFailure{ID: "f", Revision: 3}).supersededBy(&sessionFailure{ID: "f", Revision: 2}).Revision != 3 {
		t.Fatal("an older revision won")
	}
	paying := rateLimitIn(map[string]any{"_claude/rateLimit": map[string]any{"status": "allowed", "overageInUse": true}})
	if classifyLimit("claude", nil, paying, nil, "", "").kind != limitOverage {
		t.Fatal("overage")
	}
	if failureIn(map[string]any{"jetbrains": "no"}) != nil || rateLimitIn(nil) != nil {
		t.Fatal("a shape not understood")
	}
}

func saidIn(d *Daemon, id wire.UUID) (users, notes []string) {
	entries, _, _ := d.Store.Transcript(id, 0)
	for _, e := range entries {
		if e.Kind.UserMessage != nil {
			users = append(users, e.Kind.UserMessage.Value)
		}
		if e.Kind.RuntimeNote != nil {
			notes = append(notes, e.Kind.RuntimeNote.Value)
		}
	}
	return
}

func TestARateLimitIsSentAgain(t *testing.T) {
	fakeRuntimes(t)
	old := rateLimitPolicy.delays
	rateLimitPolicy.delays = []time.Duration{100 * time.Millisecond}
	t.Cleanup(func() { rateLimitPolicy.delays = old })
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "rate limit me"}), &id)
	c.until(t, "finished", ended(id, wire.AgentStateFinished))
	users, notes := saidIn(d, id)
	if len(users) != 1 || !strings.Contains(strings.Join(notes, "\n"), "is rate limited. Trying again at") {
		t.Fatal(users, notes)
	}
	var allow wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &allow)
	if b, _ := json.Marshal(allow); strings.Contains(string(b), `"rateLimited"`) {
		t.Fatalf("still rate limited after it worked: %s", b)
	}
}

func TestATypedLimitStopsTheAgentUntilItsReset(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "typed limit"}), &id)
	c.until(t, "stopped", ended(id, wire.AgentStateStopped))
	if r := d.Store.Agent(id).EndedReason; r == nil || *r != wire.EndedReasonAllowanceSpent {
		t.Fatal(r)
	}
	_, notes := saidIn(d, id)
	if s := strings.Join(notes, "\n"); !strings.Contains(s, "Claude: You've hit your session limit") || !strings.Contains(s, "Its provider says it resets at") {
		t.Fatal(notes)
	}
	var allow wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &allow)
	if b, _ := json.Marshal(allow); !strings.Contains(string(b), `"why":"allowanceSpent"`) || !strings.Contains(string(b), `"until":`) ||
		!strings.Contains(string(b), `"window":"five_hour"`) {
		t.Fatalf("%s", b)
	}
}

func TestPaidOverageTakesTheRuntimeOutAndTheTurnStands(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(), "prompt": "pay extra"}), &id)
	c.until(t, "finished", ended(id, wire.AgentStateFinished))
	var allow wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &allow)
	if b, _ := json.Marshal(allow); !strings.Contains(string(b), `"why":"overage"`) {
		t.Fatalf("%s", b)
	}
	if n := names(d); !strings.Contains(strings.Join(n, " "), "cost.allowance_out") {
		t.Fatal(n)
	}
}

// A weekly reading is the last of its week (#3438): a later one of the same week replaces it,
// the next week adds one, at most six weeks of a window stay, and other windows are not kept.
func TestWithWeekKeepsTheLastReadingOfEachWeek(t *testing.T) {
	week := func(window string, n int, used float64, at float64) wire.AllowanceReading {
		resets := wire.Date(float64(n) * 7 * 86400)
		return wire.AllowanceReading{Window: &window, Used: &used, ResetsAt: &resets, At: wire.Date(at)}
	}
	var weeks []wire.AllowanceReading
	var ok bool
	weeks, ok = withWeek(weeks, week("seven_day", 1, 0.2, 10))
	if !ok || len(weeks) != 1 {
		t.Fatalf("first week: %v %v", weeks, ok)
	}
	if weeks, ok = withWeek(weeks, week("seven_day", 1, 0.5, 20)); !ok || len(weeks) != 1 || *weeks[0].Used != 0.5 {
		t.Fatalf("a later reading of the same week replaces it: %v %v", weeks, ok)
	}
	if _, ok = withWeek(weeks, week("seven_day", 1, 0.3, 15)); ok {
		t.Fatal("an older reading of the same week is not news")
	}
	if _, ok = withWeek(weeks, week("five_hour", 1, 0.3, 30)); ok {
		t.Fatal("a five-hour window is not a week")
	}
	weeks, _ = withWeek(weeks, week("seven_day_opus", 1, 0.1, 30))
	for n := 2; n <= 8; n++ {
		weeks, _ = withWeek(weeks, week("seven_day", n, 0.9, float64(n*100)))
	}
	var seven []float64
	for _, w := range weeks {
		if *w.Window == "seven_day" {
			seven = append(seven, float64(*w.ResetsAt)/(7*86400))
		}
	}
	if len(weeks) != 7 || !slices.Equal(seven, []float64{3, 4, 5, 6, 7, 8}) {
		t.Fatalf("six weeks of seven_day kept, the Opus one too, oldest first: %v", seven)
	}
	merged, more := withWeeks(nil, weeks)
	if !more || len(merged) != len(weeks) {
		t.Fatalf("another machine's weeks are taken in: %v", merged)
	}
	if _, more = withWeeks(merged, weeks); more {
		t.Fatal("the same weeks again are no news")
	}
}
