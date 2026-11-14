package agentsd

import (
	"context"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Desktop control (#3004, US2, FR-004, T020; #4264): <settings>/desktop-control.json,
// {enabled, mode}. Ask, Always Approve or Off (driveapproval.go): Ask when never set on a
// machine a person uses. While it is Off, drive_screen is not offered and is refused
// (screencalls.go). Only the person's own clients can change it: never an agent, an MCP tool
// or a workflow, which reach a host method only over the agent socket role.

const desktopControlFile = "desktop-control.json"

// desktopControlOffWords is drive_screen's refusal while the switch is Off: the rule, and
// where to turn it on.
const desktopControlOffWords = "Nothing was driven: Desktop control is off on this Mac, so no agent may drive its apps. " +
	"The person can turn it on in Settings ▸ Desktop control."

// desktopControlOn is whether drive_screen may run here: Ask or Always Approve.
func (d *Daemon) desktopControlOn() bool { return d.desktopControlMode() != wire.DriveApprovalOff }

// offersDriveScreen is whether tools/list offers drive_screen: a Mac with agents-drive
// beside this binary, and the switch on.
func (d *Daemon) offersDriveScreen() bool {
	return d.desktopControlAvailable() && d.desktopControlOn()
}

// desktopControlState is desktopControl/state.
func (d *Daemon) desktopControlState() wire.DesktopControlSettings {
	m := d.desktopControlMode()
	return wire.DesktopControlSettings{Enabled: m != wire.DriveApprovalOff, Mode: &m}
}

// setDesktopControl is desktopControl/set. A client from before #4264 sends only enabled:
// On is Always Approve, as it was.
func (d *Daemon) setDesktopControl(c *Client, in wire.DesktopControlSettings) (wire.DesktopControlSettings, error) {
	if !personsClient(c) {
		return wire.DesktopControlSettings{}, &Error{Code: CodeNotPermitted, Message: "Only your own clients can turn desktop control on or off."}
	}
	m := wire.DriveApprovalOff
	switch {
	case in.Mode != nil:
		if !validDriveApproval(*in.Mode) {
			return wire.DesktopControlSettings{}, Invalid("Desktop control is ask, always or off.")
		}
		m = *in.Mode
	case in.Enabled:
		m = wire.DriveApprovalAlways
	}
	return d.saveDesktopControl(m)
}

func (d *Daemon) registerDesktopControl() {
	On(d, wire.CallDesktopControlState, func(_ context.Context, _ *Client, _ wire.Empty) (wire.DesktopControlSettings, error) {
		return d.desktopControlState(), nil
	})
	On(d, wire.CallDesktopControlSet, func(_ context.Context, c *Client, in wire.DesktopControlSettings) (wire.DesktopControlSettings, error) {
		return d.setDesktopControl(c, in)
	})
}
