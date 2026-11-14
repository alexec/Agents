package agentsd

import (
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4985: a host that its control plane forgot starts no agent and runs no workflow, and a
// lane whose pull request landed while the host was down is not picked up.

func TestAForgottenHostPicksNobodyUp(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	id := leftWorking(t, root, wire.AgentStateRunning, "fake-session", nil)
	d, _ := start(t, root)
	defer d.Shutdown()
	d.AwaitMembership(false)
	if !d.membershipUnknown() {
		t.Fatal("a start that waits for its answer should not know its membership yet")
	}
	d.ControlAnswered(false, true)
	d.WaitForMembership()
	if d.membershipUnknown() || !d.notAMember() {
		t.Fatalf("unknown %v, not a member %v", d.membershipUnknown(), d.notAMember())
	}
	d.PickUpAfterRestart()
	if m := userMessages(d, id); len(m) != 0 {
		t.Fatalf("a forgotten host sent %q", m)
	}
	if len(d.resumingNow()) != 0 || d.interruptedCount() != 1 {
		t.Fatalf("resuming %v, interrupted %d", d.resumingNow(), d.interruptedCount())
	}
	// Taken back: a member again.
	d.ControlAnswered(true, false)
	if d.notAMember() {
		t.Fatal("still not a member after the control plane took it back")
	}
}

func TestAHostRefusedLastRunStartsAsForgotten(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	was := memberAnswerWait
	memberAnswerWait = 10 * time.Millisecond
	defer func() { memberAnswerWait = was }()
	d.AwaitMembership(true)
	// A failed dial says nothing about the membership.
	d.ControlAnswered(false, false)
	d.WaitForMembership()
	if !d.notAMember() || d.membershipUnknown() {
		t.Fatalf("not a member %v, unknown %v", d.notAMember(), d.membershipUnknown())
	}
}

func TestTheWorkflowClockWaitsForTheMembership(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	d.AwaitMembership(false)
	d.workflowMu.Lock()
	before := d.recordsLocked().LastTickAt
	d.workflowMu.Unlock()
	d.workflowTickOnce(time.Now().Add(time.Hour))
	d.workflowMu.Lock()
	after := d.recordsLocked().LastTickAt
	d.workflowMu.Unlock()
	if (before == nil) != (after == nil) || before != nil && *before != *after {
		t.Fatalf("a tick ran while the membership was unknown: %v then %v", before, after)
	}
}

func TestALaneWhosePullRequestMergedIsNotPickedUp(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	id := leftWorking(t, root, wire.AgentStateRunning, "fake-session", func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "P#12", AddedAt: now()}, {Value: "merged", AddedAt: now()}}
	})
	d, _ := start(t, root)
	defer d.Shutdown()
	d.PickUpAfterRestart()
	waitFor(t, "it left the queue of agents coming back", func() bool { return len(d.resumingNow()) == 0 })
	n := notes(d, id)
	if len(n) == 0 || !strings.HasPrefix(n[len(n)-1], "Not picked back up: its pull request is merged") {
		t.Fatalf("%q", n)
	}
	if m := userMessages(d, id); len(m) != 0 {
		t.Fatalf("a lane whose PR merged was sent %q", m)
	}
}
