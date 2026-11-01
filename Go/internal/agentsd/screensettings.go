package agentsd

import (
	"context"

	"github.com/alexec/agents/Go/wire"
)

// Desktop control's Off switch (#3004, US2, FR-004, T020): <settings>/desktop-control.json,
// {enabled: bool}, Off when unset. While it is Off, drive_screen is not offered and is
// refused (screencalls.go). Only the person's own clients can turn it on: never an agent,
// an MCP tool or a workflow, which reach a host method only over the agent socket role.

const desktopControlFile = "desktop-control.json"

// desktopControlOffWords is drive_screen's refusal while the switch is Off: the rule, and
// where to turn it on.
const desktopControlOffWords = "Nothing was driven: Desktop control is off on this Mac, so no agent may drive its apps. " +
	"The person can turn it on in Settings ▸ Desktop control."

// desktopControlOn is whether the person has turned desktop control on.
func (d *Daemon) desktopControlOn() bool {
	var st wire.DesktopControlSettings
	d.readSetting(desktopControlFile, &st)
	return st.Enabled
}

// offersDriveScreen is whether tools/list offers drive_screen: a Mac with agents-drive
// beside this binary, and the switch on.
func (d *Daemon) offersDriveScreen() bool {
	return d.desktopControlAvailable() && d.desktopControlOn()
}

// setDesktopControl is desktopControl/set.
func (d *Daemon) setDesktopControl(c *Client, in wire.DesktopControlSettings) (wire.DesktopControlSettings, error) {
	if c == nil || (c.Role != RoleControl && c.Role != RoleDevice) {
		return wire.DesktopControlSettings{}, &Error{Code: CodeNotPermitted, Message: "Only your own clients can turn desktop control on or off."}
	}
	st := wire.DesktopControlSettings{Enabled: in.Enabled}
	if err := d.writeSetting(desktopControlFile, st); err != nil {
		return wire.DesktopControlSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: desktopControlFile + ": " + err.Error()}
	}
	return st, nil
}

func (d *Daemon) registerDesktopControl() {
	On(d, wire.CallDesktopControlState, func(_ context.Context, _ *Client, _ wire.Empty) (wire.DesktopControlSettings, error) {
		return wire.DesktopControlSettings{Enabled: d.desktopControlOn()}, nil
	})
	On(d, wire.CallDesktopControlSet, func(_ context.Context, c *Client, in wire.DesktopControlSettings) (wire.DesktopControlSettings, error) {
		return d.setDesktopControl(c, in)
	})
}
