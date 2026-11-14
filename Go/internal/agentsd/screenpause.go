package agentsd

import (
	"context"
	"encoding/json"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Pause on touch (#3004, US3, FR-007, FR-008): the moment the person moves the real mouse
// or presses a real key while an agent holds the "screen" lease, agents-drive says `touch`
// and the agent's drive_screen stops where it is. The agent's record carries
// desktopControlPause, so every client showing it offers Resume and Take Over: Resume lets
// the waiting call go on from where it stopped; Take Over lets go of the lease at once, and
// drive_screen is refused for the rest of that turn, so the agent does not take the screen
// straight back. Nothing here outlives the turn (data-model.md, "Pause on touch").

// screenPause is one paused agent's wait: done closes on Resume, Take Over or the turn's
// end, and outcome says which.
type screenPause struct {
	done    chan struct{}
	outcome string // "resumed", "takenOver" or "ended"
}

// The words drive_screen answers with when the person takes the screen back.
const (
	desktopControlTakenOverWords = "Nothing more was driven: the person took over the screen, and the screen lease is let go. " +
		"Do not drive the screen again in this turn; say what is left to do, and let the person carry on."
	desktopControlNotPausedWords = "That agent is not paused, so there is nothing to resume."
	desktopControlNotHeldWords   = "That agent does not hold the screen, so there is nothing to take over."
	desktopControlEndedWords     = "Nothing more was driven: the turn ended while the screen was paused."
)

// noteScreenApp keeps the app this agent last drove, for the pause its next touch makes.
func (d *Daemon) noteScreenApp(agent wire.UUID, app string) {
	d.driveMu.Lock()
	defer d.driveMu.Unlock()
	if d.screenApps == nil {
		d.screenApps = map[wire.UUID]string{}
	}
	d.screenApps[agent] = app
}

// pauseScreen is FR-007: the person touched the mouse or keyboard. Once per pause, and
// only while the agent holds the screen: one still in line has a helper (the Accessibility
// gate starts it) but is driving nothing.
func (d *Daemon) pauseScreen(agent wire.UUID) {
	if !d.holdsScreen(agent) {
		return
	}
	d.driveMu.Lock()
	if d.pauses == nil {
		d.pauses = map[wire.UUID]*screenPause{}
	}
	if _, already := d.pauses[agent]; already {
		d.driveMu.Unlock()
		return
	}
	d.pauses[agent] = &screenPause{done: make(chan struct{})}
	app := d.screenApps[agent]
	d.driveMu.Unlock()
	// The notice first: a client that sees the pause on the record finds its notice too.
	d.postPauseNotice(agent, app)
	d.change(agent, func(a *wire.Agent) {
		a.DesktopControlPause = &wire.DesktopControlPause{App: app, PausedAt: now()}
	})
}

// pauseNoticePrefix starts a pause notice's id; the rest is the agent's id.
const pauseNoticePrefix = "pause:"

// postPauseNotice is US4's scenario 2: a pause waits for the person, so a client in the
// background gets a notice, as the agent's notify does. Not from the person's notice
// bucket, as a disk notice is not: it comes once per pause. Not for a muted chat, and
// dropped while the chat is in front of the person (noticeNeedsLocked).
func (d *Daemon) postPauseNotice(agent wire.UUID, app string) {
	if d.muted(&agent) {
		return
	}
	what := "the screen"
	if app != "" {
		what = app
	}
	d.attentionMu.Lock()
	d.notices = append(d.notices, postedNotice{id: pauseNoticePrefix + string(agent), agentID: agent, raised: now(),
		h3: "Paused driving " + what + " when you touched the mouse or keyboard. Resume or Take Over."})
	d.attentionMu.Unlock()
	d.reconsider()
}

// withdrawPauseNotice takes back this agent's pause notice, when it is posted.
func (d *Daemon) withdrawPauseNotice(agent wire.UUID) {
	id := pauseNoticePrefix + string(agent)
	d.attentionMu.Lock()
	kept := d.notices[:0]
	gone := false
	for _, n := range d.notices {
		if n.id == id {
			gone = true
			continue
		}
		kept = append(kept, n)
	}
	d.notices = kept
	d.attentionMu.Unlock()
	if gone {
		d.reconsider()
	}
}

// endScreenPause ends this agent's pause, if there is one, with outcome; and clears the
// card from its record either way, so a card a crash left behind goes with the next answer.
func (d *Daemon) endScreenPause(agent wire.UUID, outcome string) bool {
	d.driveMu.Lock()
	p := d.pauses[agent]
	delete(d.pauses, agent)
	if p != nil {
		p.outcome = outcome
		close(p.done)
	}
	d.driveMu.Unlock()
	d.withdrawPauseNotice(agent)
	if a := d.Store.Agent(agent); a != nil && a.DesktopControlPause != nil {
		d.change(agent, func(a *wire.Agent) { a.DesktopControlPause = nil })
	}
	return p != nil
}

// waitWhilePaused holds a drive_screen call while its agent is paused: nil once the person
// resumes it, the take-over refusal once they take over, and an error when the turn ends.
// After a touched reply the pause can be over before the call gets here (#3295): the turn
// ended then if the agent no longer holds the screen.
func (d *Daemon) waitWhilePaused(agent wire.UUID, touched bool) error {
	d.driveMu.Lock()
	taken := d.takenOver[agent]
	p := d.pauses[agent]
	d.driveMu.Unlock()
	if taken {
		return &Error{Code: CodeNotPermitted, Message: desktopControlTakenOverWords}
	}
	if p == nil {
		if touched && !d.holdsScreen(agent) {
			return &Error{Message: desktopControlEndedWords}
		}
		return nil
	}
	<-p.done
	switch p.outcome {
	case "resumed":
		return nil
	case "takenOver":
		return &Error{Code: CodeNotPermitted, Message: desktopControlTakenOverWords}
	default:
		return &Error{Message: desktopControlEndedWords}
	}
}

// tookOver is whether the person took the screen back from this agent in this turn.
func (d *Daemon) tookOver(agent wire.UUID) bool {
	d.driveMu.Lock()
	defer d.driveMu.Unlock()
	return d.takenOver[agent]
}

// holdsScreen is whether this agent holds the "screen" lease now.
func (d *Daemon) holdsScreen(agent wire.UUID) bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	d.loadLeases()
	e := d.book.Entries[wire.ResourceName("screen")]
	return e != nil && holderIndex(e, agent) >= 0
}

// personsOwn is the gate on Resume and Take Over: the person's own clients, never an agent.
func personsOwn(c *Client) error {
	if c == nil || (c.Role != RoleControl && c.Role != RoleDevice) {
		return &Error{Code: CodeNotPermitted, Message: "Only your own clients can resume an agent or take the screen back."}
	}
	return nil
}

// resumeScreen is desktopControl/resume.
func (d *Daemon) resumeScreen(c *Client, agent wire.UUID) error {
	if err := personsOwn(c); err != nil {
		return err
	}
	if !d.endScreenPause(agent, "resumed") {
		return Invalid(desktopControlNotPausedWords)
	}
	return nil
}

// takeOverScreen is desktopControl/takeOver (FR-008): the lease is let go at once, paused
// or not, and drive_screen is refused for the rest of the turn.
func (d *Daemon) takeOverScreen(c *Client, agent wire.UUID) error {
	if err := personsOwn(c); err != nil {
		return err
	}
	if !d.holdsScreen(agent) {
		d.endScreenPause(agent, "ended") // a card left behind goes too
		return Invalid(desktopControlNotHeldWords)
	}
	d.driveMu.Lock()
	if d.takenOver == nil {
		d.takenOver = map[wire.UUID]bool{}
	}
	d.takenOver[agent] = true
	d.driveMu.Unlock()
	d.endScreenPause(agent, "takenOver")
	d.letGoOfScreen(agent)
	return nil
}

func (d *Daemon) registerDesktopControlPause() {
	On(d, wire.CallDesktopControlResume, func(_ context.Context, c *Client, in wire.AgentRequest) (wire.Empty, error) {
		return wire.Empty{}, d.resumeScreen(c, in.AgentID)
	})
	On(d, wire.CallDesktopControlTakeOver, func(_ context.Context, c *Client, in wire.AgentRequest) (wire.Empty, error) {
		return wire.Empty{}, d.takeOverScreen(c, in.AgentID)
	})
}

// screenLeaseName is the "screen" resource, as releaseResource takes it.
var screenLeaseName = map[string]json.RawMessage{"name": json.RawMessage(`"screen"`)}
