package agentsd

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports BlockTests: a lead waits on its helper by name, ends its turn blocked, and is
// started again with what the helper said once it has finished; what cannot be waited on
// is refused in a sentence.

func TestALeadWaitsOnItsHelper(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	title := func(s string) *string { return &s }
	lead := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Lead"), wire.AgentStateRunning, nil })
	helper := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Helper"), wire.AgentStateRunning, nil })
	done := seeded(t, d, dir, func(a *wire.Agent) {
		a.Title, a.Report = title("Done one"), &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "All good.", At: now()}
	})
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "wait_for_agents", map[string]any{"agents": []string{"Nobody"}, "until_minutes": 30}); !isErr ||
		!strings.HasPrefix(text, "Nothing was recorded: no agent in this folder is called “Nobody”. The agents here are: ") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "wait_for_agents", map[string]any{"agents": []string{"Done one"}, "until_minutes": 30}); !isErr ||
		text != "Nothing was recorded: “Done one” has already ended (complete — All good.). Use what it said rather than waiting on it." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "wait_for_agents", map[string]any{"agents": []string{"Helper"}}); !isErr || !strings.HasPrefix(text, "Nothing is waited for: until_minutes is required") {
		t.Fatal(text)
	}
	text, _ := m.tool(5, "wait_for_agents", map[string]any{"agents": []string{"helper"}, "until_minutes": 30, "message": "Waiting for the tests."})
	if text != "Recorded. The person will see this conversation under \"Waiting\". You will be resumed when “Helper” has finished, or in 30 minutes, whichever comes first." {
		t.Fatal(text)
	}
	if w := d.waitingAgents(); len(w) != 1 || w[0].Status.Line != "◷ Waiting for “Helper” to finish" || w[0].Status.Cancellable {
		t.Fatalf("%+v", w)
	}
	// The lead's turn ends blocked, as it said.
	d.change(lead.ID, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn) })
	// The helper finishes: the lead is started again with what it said.
	d.change(helper.ID, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "Tests pass.", At: now()}
	})
	d.closeWaits(helper.ID, *waitEndingHow(d.Store.Agent(helper.ID)))
	waitFor(t, "the lead started again", func() bool {
		for _, u := range userMessages(d, lead.ID) {
			if strings.HasPrefix(u, "The wait you reported has cleared: the agent you were waiting on has finished.\n\n- “Helper” (id ") &&
				strings.Contains(u, "): finished: complete — Tests pass.\n\nYou said you were waiting on: Waiting for the tests.\nCarry on from here.") {
				return true
			}
		}
		return false
	})
	waitFor(t, "its turn over", func() bool {
		l := d.live(lead.ID)
		l.mu.Lock()
		busy := l.running || l.inTurn
		l.mu.Unlock()
		return !busy && d.Store.Agent(lead.ID).State == wire.AgentStateFinished && len(d.Store.Agent(lead.ID).QueuedPrompts) == 0
	})
	_ = done
}

// A block reported before a card in the same turn is still the turn's ending once the card
// is answered (#1432): the assessments' helpers and waits were lost to an edit's card.
func TestABlockOutlivesACardInTheSameTurn(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	waiting := &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting on the helper.", At: now(),
		Block: &wire.Block{Waits: []wire.Wait{}, CheckAgainAt: new(now())}}
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason, a.Report = wire.AgentStateRunning, nil, waiting })
	d.setState(a.ID, wire.AgentStateWaitingOnUser)
	d.setState(a.ID, wire.AgentStateRunning)
	if r := d.Store.Agent(a.ID).Report; r == nil || r.Outcome != wire.WorkOutcomeWaiting {
		t.Fatalf("after the card: %+v", r)
	}
	// A new turn clears it, as before.
	d.change(a.ID, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "Done.", At: now()}
	})
	d.setState(a.ID, wire.AgentStateRunning)
	if r := d.Store.Agent(a.ID).Report; r != nil {
		t.Fatalf("a new turn kept %+v", r)
	}
}

func TestCheckAgainNeedsInMinutes(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	title := func(s string) *string { return &s }
	lead := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Lead"), wire.AgentStateRunning, nil })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "check_again", map[string]any{}); !isErr ||
		!strings.HasPrefix(text, "Nothing is waited for: in_minutes is required") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "check_again", map[string]any{"in_minutes": 0}); !isErr ||
		!strings.Contains(text, "in_minutes has to be a whole number from") {
		t.Fatal(text)
	}
	text, _ := m.tool(4, "check_again", map[string]any{"in_minutes": 30, "message": "Waiting for CI."})
	if !strings.Contains(text, "Recorded.") || !strings.Contains(text, "Waiting") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(lead.ID).Report; r == nil || r.Outcome != wire.WorkOutcomeWaiting {
		t.Fatalf("%+v", r)
	}
}

// Only one of a Block (check_again, wait_for_agents) and an EventWait (wait_for_event) is
// ever open at a time, in either order (#3094): the chat draws one wait card at the foot
// of the chat, not two.
func TestOnlyOneWaitAtATime(t *testing.T) {
	fakeRuntimes(t)
	was := eventHoldLimit
	eventHoldLimit = 300 * time.Millisecond
	defer func() { eventHoldLimit = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	text, _ := m.tool(2, "check_again", map[string]any{"in_minutes": 30, "message": "Waiting for CI."})
	if !strings.Contains(text, "Recorded.") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(a.ID).Report; r == nil || !isOpenBlock(r) {
		t.Fatalf("no open block: %+v", r)
	}

	// wait_for_event closes the open block: it is replaced, not stacked.
	text, _ = m.tool(3, "wait_for_event", map[string]any{"events": "branch.moved", "until_minutes": 10})
	if !strings.HasPrefix(text, "Still waiting for branch.moved") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(a.ID).Report; isOpenBlock(r) {
		t.Fatalf("the check-again block is still open: %+v", r.Block)
	}
	if d.Store.Agent(a.ID).EventWait == nil {
		t.Fatal("no event wait was recorded")
	}

	// check_again closes the open event wait the same way.
	text, _ = m.tool(4, "check_again", map[string]any{"in_minutes": 15, "message": "Waiting again."})
	if !strings.Contains(text, "Replaced your earlier wait on branch.moved") || !strings.Contains(text, "Recorded.") {
		t.Fatal(text)
	}
	if d.Store.Agent(a.ID).EventWait != nil {
		t.Fatal("the event wait is still open")
	}
	if r := d.Store.Agent(a.ID).Report; r == nil || !isOpenBlock(r) {
		t.Fatalf("no open block: %+v", r)
	}
}

// Two waits closing at once resume the waiting agent once (#3099): the kill switch stopped
// both reviews a release waited on, each stop cleared the release's block, and the second
// resume woke the release's next wait on them at once, saying they were stopped.
func TestABlockClearedTwiceAtOnceResumesOnce(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	title := func(s string) *string { return &s }
	stopped := func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonCancelled) }
	one := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Security review"); stopped(a) })
	two := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Performance review"); stopped(a) })
	ending := &wire.WaitEnding{At: now(), How: wire.WaitEndingHow{Stopped: &wire.WaitEndingHowStopped{Value: reason(wire.EndedReasonCancelled)}}}
	anyOf := wire.BlockWakeOnAny
	lead := seeded(t, d, dir, func(a *wire.Agent) {
		a.Title, a.State, a.EndedReason = title("Release"), wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for the reviews.", At: now(),
			Block: &wire.Block{WakeOn: &anyOf, CheckAgainAt: new(wire.DateOf(time.Now().Add(time.Hour))), Waits: []wire.Wait{
				{AgentID: one.ID, NameAtReport: "Security review", Ending: ending},
				{AgentID: two.ID, NameAtReport: "Performance review", Ending: ending},
			}}}
	})
	gate := make(chan struct{})
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			<-gate
			d.resumeIfCleared(lead.ID)
		})
	}
	close(gate)
	wg.Wait()
	waitFor(t, "its turn over", func() bool {
		l := d.live(lead.ID)
		l.mu.Lock()
		busy := l.running || l.inTurn
		l.mu.Unlock()
		return !busy && len(d.Store.Agent(lead.ID).QueuedPrompts) == 0 && len(userMessages(d, lead.ID)) > 0
	})
	resumes := 0
	for _, u := range userMessages(d, lead.ID) {
		if strings.HasPrefix(u, "The wait you reported has cleared") {
			resumes++
		}
	}
	if resumes != 1 {
		t.Fatalf("resumed %d times: %q", resumes, userMessages(d, lead.ID))
	}
}
