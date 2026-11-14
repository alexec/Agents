package agentsd

import (
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A host that its control plane forgot (machines/remove) starts no agent and runs no
// workflow (#4985): it was down when it was removed, so its lanes and its schedules are
// another machine's now, or nobody's. It says that it is not a member, and waits to join
// again.
//
// On a start, the host does not know yet: the uplink's first answer says. So a host that
// has a membership holds its pick-ups and its workflow clock until that answer comes, or
// for memberAnswerWait when the control plane cannot be reached.
type forgottenState struct {
	forgottenHere atomic.Bool
	// memberAwaiting is set while a start waits for the uplink's first answer.
	memberAwaiting   atomic.Bool
	memberAnswerOnce sync.Once
	memberAnswer     chan struct{}
	memberAnswerMu   sync.Mutex
}

// memberAnswerWait is how long a start waits for the control plane's first answer.
var memberAnswerWait = 20 * time.Second

func (d *Daemon) answerChan() chan struct{} {
	d.memberAnswerMu.Lock()
	defer d.memberAnswerMu.Unlock()
	if d.memberAnswer == nil {
		d.memberAnswer = make(chan struct{})
	}
	return d.memberAnswer
}

// AwaitMembership is told, before the uplink runs, that this start waits for its first
// answer; was is what the last run's control-join.json said, so a host it already
// refused as forgotten starts as one.
func (d *Daemon) AwaitMembership(wasForgotten bool) {
	d.answerChan()
	d.forgottenHere.Store(wasForgotten)
	d.memberAwaiting.Store(true)
}

// ControlAnswered is the uplink's answer: connected, or refused as forgotten. Any other
// failure (the control plane cannot be reached) says nothing about the membership.
func (d *Daemon) ControlAnswered(connected bool, forgotten bool) {
	switch {
	case forgotten:
		if !d.forgottenHere.Swap(true) {
			log.Printf("not a member: the control plane forgot this machine; no agent is picked up and no workflow runs until it joins again")
		}
	case connected:
		if d.forgottenHere.Swap(false) {
			log.Printf("a member again: the control plane took this machine back")
		}
	default:
		return
	}
	d.memberAnswerOnce.Do(func() { close(d.answerChan()) })
}

// WaitForMembership waits for the uplink's first answer, at most memberAnswerWait, then
// lets the workflow clock tick again.
func (d *Daemon) WaitForMembership() {
	if !d.memberAwaiting.Load() {
		return
	}
	select {
	case <-d.answerChan():
	case <-time.After(memberAnswerWait):
		log.Printf("membership: no answer from the control plane in %s; going on as the last run left it", memberAnswerWait)
	case <-d.ctx.Done():
	}
	d.memberAwaiting.Store(false)
}

// notAMember is whether the control plane forgot this host.
func (d *Daemon) notAMember() bool { return d.forgottenHere.Load() }

// membershipUnknown is whether a start still waits for the control plane's first answer.
func (d *Daemon) membershipUnknown() bool { return d.memberAwaiting.Load() }

// prEnded is the pull request a lane's labels name that is merged or closed (#4985), so a
// host that was down while it landed does not pick the lane up to push or comment for
// it: its label merged, or a P#n the forge says is no longer open. A forge that cannot
// be asked says nothing.
func (d *Daemon) prEnded(a *wire.Agent) (string, bool) {
	folder := folderPath(a)
	for _, l := range a.Labels {
		if l.Value == "merged" {
			return "its pull request is merged", true
		}
	}
	for _, l := range a.Labels {
		if !prLabel.MatchString(l.Value) {
			continue
		}
		node, ok := d.labelNode(folder, l.Value)
		if !ok {
			continue
		}
		ctx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
		detail, err := d.forgeItem(ctx, lineage.KindPR, wire.ForgeItemRequest{Node: node})
		cancel()
		if err != nil {
			continue
		}
		switch detail.Item.State {
		case "merged", "closed":
			return "its pull request " + l.Value + " is " + detail.Item.State, true
		}
	}
	return "", false
}
