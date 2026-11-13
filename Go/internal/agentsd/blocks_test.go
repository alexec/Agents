package agentsd

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
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
	if text, isErr := m.tool(2, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"Nobody"}}, "until_minutes": 30}); !isErr ||
		!strings.HasPrefix(text, "Nothing was recorded: no agent in this folder is called “Nobody”. The agents here are: ") {
		t.Fatal(text)
	}
	// One that has already ended answers at once, with how, and nothing is waited for (#3799).
	if text, isErr := m.tool(3, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"Done one"}}, "until_minutes": 30}); isErr ||
		text != "Not waiting: the session you named has already ended.\n\n- “Done one” (id "+string(done.ID)+"): complete — All good.\n\n"+
			"Carry on from here, and read what each said with read_session." {
		t.Fatal(text)
	}
	if r := d.Store.Agent(lead.ID).Report; r != nil {
		t.Fatalf("an ended one recorded %+v", r)
	}
	// With wake_on any, one ended is enough.
	if text, isErr := m.tool(31, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"Helper", "Done one"}},
		"wake_on": "any", "until_minutes": 30}); isErr || !strings.HasPrefix(text, "Not waiting: you asked to wake when any of them ended, and one has already ended.") ||
		!strings.Contains(text, "): still working") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"Helper"}}}); !isErr || !strings.HasPrefix(text, "until_minutes is required") {
		t.Fatal(text)
	}
	// With wake_on all, the ended one is said and the wait is for the rest.
	text, _ := m.tool(5, "wait_for_event", map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": []string{"helper", "Done one"}}, "until_minutes": 30, "message": "Waiting for the tests."})
	if text != "“Done one” has already ended (complete — All good.). It is not waited on. "+
		"Recorded. The person will see this conversation under \"Waiting\". You will be resumed when “Helper” has finished, or in 30 minutes, whichever comes first." {
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
}

// agent.ended names its sessions, or sets any: true, and waits on its own; wake_on is for it
// alone (#3799).
func TestAWaitOnAgentEndedNamesItsSessions(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	m := appClient(t, d, seeded(t, d, t.TempDir(), nil).ID)
	m.post("initialize", map[string]any{}, 1)
	for i, c := range []struct {
		args map[string]any
		want string
	}{
		{map[string]any{"events": []string{"agent.ended"}, "until_minutes": 5},
			"agent.ended: Name the sessions (`agent`, by id or exact title), or set `any: true` to wake when any session in the folder ends. Nothing is waiting."},
		{map[string]any{"events": []string{"agent.ended", "branch.moved"}, "where": map[string]any{"agent": "Helper", "branch": "x"}, "until_minutes": 5},
			`agent.ended with agent waits on its own: call wait_for_event with events ["agent.ended"] alone. Nothing is waiting.`},
		{map[string]any{"events": []string{"agent.finished"}, "wake_on": "any", "until_minutes": 5},
			"wake_on is only for agent.ended with the sessions named in agent. Nothing is waiting."},
		{map[string]any{"events": []string{"agent.ended"}, "where": map[string]any{"agent": "Helper"}, "wake_on": "some", "until_minutes": 5},
			"wake_on has to be all or any. Nothing is waiting."},
	} {
		if text, isErr := m.tool(10+i, "wait_for_event", c.args); !isErr || text != c.want {
			t.Errorf("%v: %s", c.args, text)
		}
	}
}

// Every way a session ends is agent.ended, with how; a turn that ends waiting is not (#3799).
func TestEndedHow(t *testing.T) {
	report := func(o wire.WorkOutcome) *wire.Agent { return &wire.Agent{Report: &wire.WorkReport{Outcome: o}} }
	for _, c := range []struct {
		a    *wire.Agent
		next wire.AgentState
		why  *wire.EndedReason
		want string
	}{
		{report(wire.WorkOutcomeDone), wire.AgentStateFinished, nil, "done"},
		{report(wire.WorkOutcomeNeedsAnswer), wire.AgentStateFinished, nil, "needs_answer"},
		{report(wire.WorkOutcomeWaiting), wire.AgentStateFinished, nil, ""},
		{&wire.Agent{}, wire.AgentStateFinished, nil, "done"},
		{&wire.Agent{}, wire.AgentStateStopped, reason(wire.EndedReasonCancelled), "stopped"},
		{&wire.Agent{}, wire.AgentStateStopped, reason(wire.EndedReasonProcessDied), "failed"},
	} {
		if got := endedHow(c.a, c.next, c.why); got != c.want {
			t.Errorf("%+v %s: %q, want %q", c.a.Report, c.next, got, c.want)
		}
	}
}

// A block reported before a card in the same turn is still the turn's ending once the card
// is answered (#1432): the assessments' helpers and waits were lost to an edit's card.
func TestABlockOutlivesACardInTheSameTurn(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	waiting := &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting on the helper.", At: now(),
		Block: &wire.Block{Waits: []wire.Wait{{AgentID: store.NewUUID(), NameAtReport: "Helper"}}, Deadline: new(now())}}
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

// A wait on a time alone is wait_for_event on time.reached (#4843): check_again is gone,
// a list with time.reached and other events is refused, and the wait ends saying the time
// has come, not that it timed out.
func TestTimeReachedIsTheWaitOnATime(t *testing.T) {
	fakeRuntimes(t)
	was := eventHoldLimit
	eventHoldLimit = 300 * time.Millisecond
	defer func() { eventHoldLimit = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	title := func(s string) *string { return &s }
	lead := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Lead"), wire.AgentStateRunning, nil })
	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	for _, tool := range appToolCalls() {
		if tool.name == "check_again" {
			t.Fatal("check_again is still a tool")
		}
	}
	if text, isErr := m.tool(3, "wait_for_event", map[string]any{"events": []string{"time.reached", "lease.granted"}, "until_minutes": 30}); !isErr ||
		!strings.HasPrefix(text, "time.reached goes alone") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "wait_for_event", map[string]any{"events": "time.reached", "where": map[string]any{"pr": 1}, "until_minutes": 30}); !isErr ||
		!strings.HasPrefix(text, "time.reached takes no where") {
		t.Fatal(text)
	}
	if d.Store.Agent(lead.ID).EventWait != nil {
		t.Fatal("a refused wait was recorded")
	}
	text, _ := m.tool(5, "wait_for_event", map[string]any{"events": "time.reached", "until_minutes": 30})
	if !strings.HasPrefix(text, "Waiting until ") || !strings.Contains(text, "You'll be started again at that time.") {
		t.Fatal(text)
	}
	w := d.Store.Agent(lead.ID).EventWait
	if !isTimeWait(w) || w.Ending != nil {
		t.Fatalf("%+v", w)
	}
	status := d.waitStatus(d.Store.Agent(lead.ID))
	if status == nil || !strings.HasPrefix(status.Mark, "◷ Waiting until ") {
		t.Fatalf("%+v", status)
	}
	// An event of any name never wakes it.
	if waitMatches(w, wire.Event{Name: "time.reached", Position: w.From + 1}) {
		t.Fatal("time.reached matched an event")
	}
	past := wire.DateOf(time.Now().Add(-time.Second))
	d.change(lead.ID, func(a *wire.Agent) {
		w := *a.EventWait
		w.Deadline = &past
		a.EventWait = &w
	})
	d.waitDeadlinesPassed()
	if words := timedOutWords(w, past); !strings.HasPrefix(words, "The time you asked for has come (") {
		t.Fatal(words)
	}
	if w := d.Store.Agent(lead.ID).EventWait; w == nil || w.Ending == nil {
		t.Fatalf("the wait did not end: %+v", w)
	}
	// A workflow never triggers on it: a schedule runs at a time.
	if _, problem := parsePattern("time.reached", nil); !strings.Contains(problem, "is never raised") || !strings.Contains(problem, "schedule") {
		t.Fatal(problem)
	}
}

// Only one of a Block (a wait on agent.ended) and an EventWait (wait_for_event) is ever
// open at a time, in either order (#3094): the chat draws one wait card at the foot of the
// chat, not two.
func TestOnlyOneWaitAtATime(t *testing.T) {
	fakeRuntimes(t)
	was := eventHoldLimit
	eventHoldLimit = 300 * time.Millisecond
	defer func() { eventHoldLimit = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	title := func(s string) *string { return &s }
	dir := t.TempDir()
	seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Build"), wire.AgentStateRunning, nil })
	a := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Lead"), wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	onBuild := map[string]any{"events": "agent.ended", "where": map[string]any{"agent": []string{"Build"}}, "until_minutes": 30}

	text, _ := m.tool(2, "wait_for_event", onBuild)
	if !strings.Contains(text, "Recorded.") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(a.ID).Report; r == nil || !isOpenBlock(r) {
		t.Fatalf("no open block: %+v", r)
	}

	// wait_for_event on events closes the open block: it is replaced, not stacked.
	text, _ = m.tool(3, "wait_for_event", map[string]any{"events": "branch.moved", "where": map[string]any{"any": true}, "until_minutes": 10})
	if !strings.HasPrefix(text, "Still waiting for branch.moved") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(a.ID).Report; isOpenBlock(r) {
		t.Fatalf("the block is still open: %+v", r.Block)
	}
	if d.Store.Agent(a.ID).EventWait == nil {
		t.Fatal("no event wait was recorded")
	}

	// A wait on a session closes the open event wait the same way.
	text, _ = m.tool(4, "wait_for_event", onBuild)
	if !strings.Contains(text, "Recorded.") {
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
	stopped := func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonCancelled)
	}
	one := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Security review"); stopped(a) })
	two := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Performance review"); stopped(a) })
	ending := &wire.WaitEnding{At: now(), How: wire.WaitEndingHow{Stopped: &wire.WaitEndingHowStopped{Value: reason(wire.EndedReasonCancelled)}}}
	anyOf := wire.BlockWakeOnAny
	lead := seeded(t, d, dir, func(a *wire.Agent) {
		a.Title, a.State, a.EndedReason = title("Release"), wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for the reviews.", At: now(),
			Block: &wire.Block{WakeOn: &anyOf, Deadline: new(wire.DateOf(time.Now().Add(time.Hour))), Waits: []wire.Wait{
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

// Another agent's message to an agent waiting on agents is answered in a turn, and the
// wait goes on after it (#3173): the Scrum Master's message to a release cleared its wait
// on two reviews, so the release was never woken when they finished or when its time came.
func TestAWaitOutlivesAnotherAgentsMessage(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	title := func(s string) *string { return &s }
	review := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Review"), wire.AgentStateRunning, nil })
	check := seeded(t, d, dir, func(a *wire.Agent) { a.Title, a.State, a.EndedReason = title("Check"), wire.AgentStateRunning, nil })
	master := seeded(t, d, dir, func(a *wire.Agent) { a.Title = title("Scrum master") })
	lead := seeded(t, d, dir, func(a *wire.Agent) {
		a.Title, a.State, a.EndedReason = title("Release"), wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for the review and the check.", At: now(),
			Block: &wire.Block{Deadline: new(wire.DateOf(time.Now().Add(time.Hour))), Waits: []wire.Wait{
				{AgentID: review.ID, NameAtReport: "Review"}, {AgentID: check.ID, NameAtReport: "Check"},
			}}}
	})
	turnOver := func(n int) func() bool {
		return func() bool {
			l := d.live(lead.ID)
			l.mu.Lock()
			busy := l.running || l.inTurn
			l.mu.Unlock()
			return !busy && d.Store.Agent(lead.ID).State == wire.AgentStateFinished && len(userMessages(d, lead.ID)) == n
		}
	}
	message := func(text string) {
		d.change(lead.ID, func(a *wire.Agent) {
			a.QueuedPrompts = append(a.QueuedPrompts, wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(),
				From: wire.PromptOriginAgent, Sender: &wire.MessageSender{AgentID: master.ID, Title: "Scrum master"}, Attachments: []wire.Attachment{}})
		})
		d.live(lead.ID).kick()
	}
	message("Scrum master: a fix merged.")
	waitFor(t, "the message answered", turnOver(1))
	if r := d.Store.Agent(lead.ID).Report; !isOpenBlock(r) || r.Block == nil || len(r.Block.Waits) != 2 {
		t.Fatalf("the wait was lost: %+v", r)
	}
	// The review ends while the next message is answered, when there is no block for
	// closeWaits to find: the wait closes as the turn ends, and the release carries on.
	d.change(review.ID, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeDone, Message: "No dead code.", At: now()}
	})
	d.change(lead.ID, func(a *wire.Agent) {
		b := *a.Report.Block
		b.WakeOn = new(wire.BlockWakeOnAny)
		r := *a.Report
		r.Block = &b
		a.Report = &r
	})
	message("Scrum master: another fix merged.")
	waitFor(t, "the release resumed", func() bool {
		for _, u := range userMessages(d, lead.ID) {
			if strings.HasPrefix(u, "The wait you reported has cleared") && strings.Contains(u, "No dead code.") {
				return true
			}
		}
		return false
	})
	waitFor(t, "its turn over", turnOver(3))
}

// A block that waits on no session is a time-only one that check_again made before #4843:
// on load it is dropped, with no resume and no move up the list (#5152).
func TestATimeOnlyBlockIsDroppedOnLoad(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	old := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		r := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedReason = wire.AgentStateArchived, &r
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for CI.", At: now(),
			Block: &wire.Block{Waits: []wire.Wait{}, Deadline: new(wire.DateOf(time.Now().Add(-48 * time.Hour)))}}
	})
	d.resumeBlocks()
	got := d.Store.Agent(old.ID)
	if isOpenBlock(got.Report) || got.Report.Block.ClearedBy == nil || *got.Report.Block.ClearedBy != wire.BlockClearingDropped {
		t.Fatalf("still open: %+v", got.Report.Block)
	}
	if len(got.QueuedPrompts) > 0 {
		t.Fatalf("resumed: %+v", got.QueuedPrompts)
	}
	if got.LastActivityAt != old.LastActivityAt {
		t.Fatalf("moved up its list: %v, was %v", got.LastActivityAt, old.LastActivityAt)
	}
}

// A due block on an agent in a turn does not keep the block timer firing (#4687): aimed
// at its time, which had passed, the timer fired every 20 ms until the turn ended, and
// each pass copied and sorted every record. The block resumes as the turn ends.
func TestADueBlockInATurnFiresTheTimerOnce(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	lead := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn)
		a.Report = &wire.WorkReport{Outcome: wire.WorkOutcomeWaiting, Message: "Waiting for CI.", At: now(),
			Block: &wire.Block{Waits: []wire.Wait{{AgentID: store.NewUUID(), NameAtReport: "CI watcher"}},
				Deadline: new(wire.DateOf(time.Now().Add(-time.Minute)))}}
	})
	l := d.live(lead.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	fires := d.blockFires.Load()
	d.armBlockTimer()
	time.Sleep(300 * time.Millisecond)
	if n := d.blockFires.Load() - fires; n > 1 {
		t.Fatalf("the block timer fired %d times in 300 ms", n)
	}
	if r := d.Store.Agent(lead.ID).Report; !isOpenBlock(r) {
		t.Fatalf("resumed in its turn: %+v", r)
	}
	l.mu.Lock()
	l.inTurn = false
	l.mu.Unlock()
	l.kick()
	waitFor(t, "the block resumed", func() bool {
		for _, u := range userMessages(d, lead.ID) {
			if strings.HasPrefix(u, "The time you asked for has come.") {
				return true
			}
		}
		return false
	})
}
