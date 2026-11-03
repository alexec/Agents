package agentsd

import (
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The live tile (#3004, US4, research R7): while an agent holds the "screen" lease, every
// client showing it gets desktopControl/liveFrame, a downscaled still of the whole screen,
// after each drive_screen action and at least every liveFrameIdle while it is idle
// (FR-011), with the narration: drive_screen's own reply to the last action ("Clicked Save
// in TextEdit."), kept in memory only. A frame goes only to the clients showing the agent (d.showers, the gate
// tellEntry uses), is held only while it is sent, and never reaches d.record or a file
// (FR-016, SC-005). While the screen is locked a frame says locked and has no image
// (FR-012): nothing is captured at all.

// liveFrameIdle is how often the tile is refreshed while drive_screen is idle: under
// FR-011's 5 seconds. A var so a test can shorten it.
var liveFrameIdle = 4 * time.Second

// watchLive sends this agent's idle frames until its agents-drive stops.
func (d *Daemon) watchLive(agent wire.UUID, p *driveProcess) {
	t := time.NewTicker(liveFrameIdle)
	defer t.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-t.C:
			d.sendLiveFrame(agent, "", "")
		}
	}
}

// sendLiveFrame sends one frame to the clients showing agent, if it holds the screen and
// anyone shows it. image is a still drive_screen has already taken; empty asks this
// agent's agents-drive for one (its "frame" action, which does not arm the touch watch).
// said is the action's narration; empty keeps the last one.
func (d *Daemon) sendLiveFrame(agent wire.UUID, image, said string) {
	d.driveMu.Lock()
	if said != "" {
		if d.screenSaid == nil {
			d.screenSaid = map[wire.UUID]string{}
		}
		d.screenSaid[agent] = said
	}
	said = d.screenSaid[agent]
	d.driveMu.Unlock()
	showers := d.showers(agent)
	if len(showers) == 0 || !d.holdsScreen(agent) {
		return
	}
	f := wire.DesktopControlLiveFrame{AgentID: agent, CapturedAt: now()}
	if said != "" {
		f.Narration = &said
	}
	if d.personAway() == "locked" {
		locked := true
		f.Locked = &locked
	} else {
		if image == "" {
			d.driveMu.Lock()
			p := d.drives[agent]
			d.driveMu.Unlock()
			if p == nil {
				return
			}
			// No picture (Screen Recording not granted, a helper gone): the frame still goes,
			// with the narration, and the tile says it waits for a picture.
			if res, err := p.call(map[string]any{"action": "frame"}); err == nil {
				if ok, _ := res["ok"].(bool); ok {
					image, _ = res["image"].(string)
				}
			}
		}
		if image != "" {
			f.Image = &image
		}
	}
	sendEach(d, wire.NotifyDesktopControlLiveFrame, func(c *Client) (wire.DesktopControlLiveFrame, bool) {
		return f, showers[c.ID]
	})
}

// liveFrameAfter refreshes the tile once an action is done (FR-011's 2 seconds), without
// holding up the tool call's reply.
func (d *Daemon) liveFrameAfter(agent wire.UUID, image, said string) {
	safe.Go("live frame", func() { d.sendLiveFrame(agent, image, said) })
}
