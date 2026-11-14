package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/yamlnode"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4730: provider, topic, subject and debounce, as a wait and a trigger read them.
func TestReadBusFilter(t *testing.T) {
	f, problem := readBusFilter(map[string][]string{"provider": {"GitHub"}, "topic": {"Alexec/Agents", "alexec/agents", "x/y"},
		"subject": {"github:pr:alexec/agents#4702"}, "debounce": {"30s"}})
	if problem != "" || f.provider != "github" || len(f.topics) != 2 || f.topics[0] != "alexec/agents" ||
		f.subject == nil || f.subject.ID != "4702" || f.debounce != 30*time.Second || !f.wide() {
		t.Fatalf("%+v %q", f, problem)
	}
	if f, _ := readBusFilter(map[string][]string{"debounce": {"90"}}); f.debounce != 90*time.Second || f.wide() {
		t.Fatalf("%+v", f)
	}
	for values, want := range map[*map[string][]string]string{
		{"provider": {"Git Hub"}}:                              "is not a provider",
		{"subject": {"#4702"}}:                                 "is not a ref",
		{"debounce": {"2h"}}:                                   "is not a time from 1s to 1h",
		{"debounce": {"0.1s"}}:                                 "is not a time from 1s to 1h",
		{"provider": {"jira"}, "subject": {"github:pr:a/b#1"}}: "is not of the provider jira",
		{"provider": {"github", "gitlab"}}:                     "is one value",
	} {
		if _, problem := readBusFilter(*values); !strings.Contains(problem, want) {
			t.Errorf("%v: %q, want %q", *values, problem, want)
		}
	}
}

func TestBusFilterMatchesTheEnvelope(t *testing.T) {
	subject := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "4702"}
	other := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "1"}
	provider, topic := "github", "Alexec/Agents"
	e := wire.Event{Name: "pr.merged", Provider: &provider, Topic: &topic, Subject: &subject}
	for _, c := range []struct {
		f    busFilter
		want bool
	}{
		{busFilter{}, true},
		{busFilter{provider: "github"}, true},
		{busFilter{provider: "gitlab"}, false},
		{busFilter{topics: []string{"x/y", "alexec/agents"}}, true},
		{busFilter{topics: []string{"x/y"}}, false},
		{busFilter{subject: &subject}, true},
		{busFilter{subject: &other}, false},
	} {
		if got := c.f.envelopeMatches(e); got != c.want {
			t.Errorf("%+v: %v", c.f, got)
		}
	}
	if (busFilter{provider: "github"}).envelopeMatches(wire.Event{Name: "pr.merged"}) {
		t.Error("an event with no envelope matched a provider")
	}
}

// A forge's server here is asked for the thing the subject names.
func TestLocalWhereFromTheSubject(t *testing.T) {
	subject := wire.Ref{Provider: "gitlab", Type: "mr", Topic: "group/repo", ID: "45"}
	got := busFilter{subject: &subject}.localWhere(map[string][]string{"mine": {"true"}})
	if len(got) != 3 || got["project"][0] != "group/repo" || got["pr"][0] != "45" || got["mine"][0] != "true" {
		t.Fatalf("%v", got)
	}
	if got := (busFilter{provider: "github", topics: []string{"alexec/agents"}}).localWhere(map[string][]string{"repo": {"x/y"}}); got["repo"][0] != "x/y" {
		t.Fatalf("where's own repo was replaced: %v", got)
	}
	if got := (busFilter{provider: "jira", topics: []string{"abc"}}).localWhere(map[string][]string{}); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}

// A workflow's `- type: …` trigger, with the envelope's keys beside it: they stay in its
// keys, are no server argument, and a forge's repo comes from its topic.
func TestATriggerByTypeProviderAndTopic(t *testing.T) {
	m, err := yamlnode.MappingFrom([]string{
		"on:",
		"  - type: pr.merged",
		"    provider: github",
		"    topic: alexec/agents",
		"    debounce: 30s",
		"  - name: agent.finished",
		"    provider: agents",
	})
	if err != nil {
		t.Fatal(err)
	}
	ts, err := parseTriggers(m["on"])
	if err != nil || len(ts) != 2 {
		t.Fatalf("%v %+v", err, ts)
	}
	if triggerName(ts[0]) != "pr.merged" || triggerName(ts[1]) != "agent.finished" {
		t.Fatalf("%+v", ts)
	}
	mt, ok := serverTrigger(ts[0])
	if !ok || len(mt.arguments) != 1 || string(mt.arguments["repo"]) != `"alexec/agents"` {
		t.Fatalf("%+v", mt)
	}
	if triggerDebounce(ts[0]) != 30*time.Second {
		t.Fatal(triggerDebounce(ts[0]))
	}
	p, ok := triggerPattern(ts[1])
	if !ok || p.bus.provider != "agents" {
		t.Fatalf("%+v", p)
	}
	for _, bad := range [][]string{
		{"on:", "  - type: pr.merged", "    debounce: soon"},
		{"on:", "  - type: pr.merged", "    subject: 4702"},
	} {
		m, _ := yamlnode.MappingFrom(bad)
		if _, err := parseTriggers(m["on"]); err == nil {
			t.Errorf("%v was read", bad)
		}
	}

	// From another machine: the envelope only, and only a trigger with no where of its own.
	subject := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "4702"}
	provider, topic := "github", "alexec/agents"
	e := wire.Event{Name: "pr.merged", Provider: &provider, Topic: &topic, Subject: &subject,
		Details: map[string]string{"bus_producer": "agents:machine:#b"}}
	if !triggerMatches(ts[0], e) {
		t.Fatal("the bus's event did not fire the trigger")
	}
	m, _ = yamlnode.MappingFrom([]string{"on:", "  - type: pr.merged", "    provider: github", "    pr: 4702"})
	narrowed, _ := parseTriggers(m["on"])
	if triggerMatches(narrowed[0], e) {
		t.Fatal("a trigger with where of its own fired on the bus")
	}
	m, _ = yamlnode.MappingFrom([]string{"on:", "  - pr.merged"})
	bare, _ := parseTriggers(m["on"])
	if triggerMatches(bare[0], e) {
		t.Fatal("a bare trigger fired on the bus")
	}
}

// A wait by provider and subject is sent as a subscription, wakes on the bus's event for
// that subject only, and says its ref and that it is a hint. A bare wait does not hear
// the bus.
func TestAWaitBySubjectHearsTheBus(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	var mu sync.Mutex
	var subs []wire.BusSubscription
	d.SetControlCapabilities(func() []string { return []string{wire.CapEventsBus1} })
	d.SetControlAsk(askControl(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if method == wire.CallBusSubscribe.Name {
			mu.Lock()
			subs = params.(wire.BusSubscribe).Subscriptions
			mu.Unlock()
		}
		return json.RawMessage(`{}`), nil
	}))
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "wait_for_event", map[string]any{"type": "server.offline", "provider": "agents",
			"subject": "agents:server:elsewhere#ci", "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the wait on the record", func() bool { return d.Store.Agent(a.ID).EventWait != nil })
	waitFor(t, "the subscription sent", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(subs) == 1 && subs[0].Type != nil && *subs[0].Type == "server.offline" && subs[0].Subject != nil &&
			subs[0].Subject.String() == "agents:server:elsewhere#ci"
	})
	mu.Lock()
	subID := subs[0].ID
	mu.Unlock()
	deliver := func(id string) {
		subject, _ := wire.ParseRef("agents:server:elsewhere#" + id)
		bus := wire.BusEvent{Specversion: "1.0", ID: subject.String() + "@server.offline/1", Type: "server.offline", Provider: "agents",
			Topic: "elsewhere", Subject: &subject, Source: "agents:elsewhere", Time: "2026-11-11T17:02:11Z", Producer: "agents:machine:#elsewhere"}
		raw, _ := json.Marshal(wire.BusDelivery{Event: bus, Subscriptions: []string{subID}})
		d.Told(wire.NotifyBusDeliver.Name, raw)
	}
	deliver("cd")
	if w := d.Store.Agent(a.ID).EventWait; w == nil || w.Ending != nil {
		t.Fatal("woken by another subject")
	}
	deliver("ci")
	text := <-answered
	if !strings.HasPrefix(text, "server.offline happened at ") || !strings.Contains(text, "Its ref is agents:server:elsewhere#ci@server.offline/1") ||
		!strings.Contains(text, "An event is a hint") {
		t.Fatal(text)
	}
	waitFor(t, "the subscription gone", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(subs) == 0
	})

	// A bare wait on the same type hears this machine only.
	go func() {
		text, _ := m.tool(3, "wait_for_event", map[string]any{"events": "server.*", "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the bare wait", func() bool { return d.Store.Agent(a.ID).EventWait != nil })
	deliver("ci2")
	if w := d.Store.Agent(a.ID).EventWait; w == nil || w.Ending != nil {
		t.Fatal("a bare wait heard the bus")
	}
	d.raise(wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: "ci went offline.", Details: map[string]string{"server": "ci"}})
	if text := <-answered; !strings.HasPrefix(text, "server.offline happened at ") {
		t.Fatal(text)
	}
}

// debounce holds a burst on one subject and type, and wakes once with the last and how
// many came.
func TestADebouncedWaitWakesOnceWithTheLast(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "wait_for_event", map[string]any{"events": []string{"server.offline"}, "provider": "agents",
			"debounce": "1s", "until_minutes": 10})
		answered <- text
	}()
	waitFor(t, "the wait on the record", func() bool { return d.Store.Agent(a.ID).EventWait != nil })
	for _, s := range []string{"first", "second", "last"} {
		d.raise(wire.EventDraft{Name: "server.offline", At: now(), Scope: macScope(), Sentence: s + ".", Details: map[string]string{"server": "ci", "n": s}})
	}
	select {
	case text := <-answered:
		t.Fatalf("woken before the debounce: %s", text)
	case <-time.After(300 * time.Millisecond):
	}
	text := <-answered
	if !strings.Contains(text, ": last.") || !strings.Contains(text, "3 events like it came in 1s; this is the last.") {
		t.Fatal(text)
	}
}

func TestAWaitSaysWhatIsWrongWithItsFilter(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, _ := m.tool(2, "wait_for_event", map[string]any{"type": "pr.merged", "subject": "P#12", "until_minutes": 10})
	if !strings.Contains(text, "is not a ref") || !strings.Contains(text, "Nothing is waiting.") {
		t.Fatal(text)
	}
}
