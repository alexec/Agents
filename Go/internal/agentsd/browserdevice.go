package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/chromedp/cdproto/target"

	"github.com/agentloops-dev/agent-loops/Go/internal/browser"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A device profile for each session's tabs (#4086): browser_emulate_device makes the
// session's tabs a phone, a tablet or a desktop browser again, over CDP (browser/device.go),
// as @playwright/mcp's own --device does not work on the machine's browser. The profile is
// the session's: its tabs, and the tabs it opens, take it, and no other session's tab does
// (#3916). It holds until the session changes it, its tabs all close, or the browser stops.

const emulateDeviceName = "browser_emulate_device"

// emulateDeviceTool is browser_emulate_device as tools/list sends it, with the browser tools.
var emulateDeviceTool = json.RawMessage(`{"name":"browser_emulate_device","title":"Emulate a device",` +
	`"description":"Make this session's tabs in the browser a phone (Pixel 7: 412×839, touch), a tablet (Galaxy Tab S9: 640×1024, touch) or a desktop browser again, ` +
	`as a browser's developer tools do: the page's size and scale, touch, and Chrome on Android's user agent and client hints. ` +
	`It holds for this session's tabs, and the ones it opens, until you call it again or they close; other sessions' tabs do not change. ` +
	`An open page lays out again at once; navigate again for the site to see the new user agent. browser_resize changes only the size.",` +
	`"inputSchema":{"type":"object","properties":{"device":{"type":"string","enum":["phone","tablet","desktop"],"description":"The device; desktop takes the profile away."}},` +
	`"required":["device"]},"annotations":{"title":"Emulate a device","readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}}`)

// emulateDeviceCheck refuses a call that names no device, before the lease is taken.
func emulateDeviceCheck(args map[string]json.RawMessage) (*browser.Device, string) {
	var name string
	json.Unmarshal(args["device"], &name)
	d, ok := browser.DeviceNamed(name)
	if !ok {
		return nil, fmt.Sprintf("There is no device %q: give phone, tablet or desktop.", name)
	}
	return d, ""
}

// emulateDevice gives agent's session the device's profile, on each of its tabs now and on
// the cast its watchers see, and says what it did.
func (d *Daemon) emulateDevice(agent wire.UUID, device *browser.Device) (string, bool) {
	agent = sessionKey(agent)
	// The tab @playwright/mcp just opened for the session is told to agentsd a moment later.
	for i := 0; i < 20 && d.followsTabs() && d.sessionTab(agent) == ""; i++ {
		time.Sleep(100 * time.Millisecond)
	}
	d.tabsMu.Lock()
	t := d.tabs
	if t == nil {
		d.tabsMu.Unlock()
		return "The browser isn't running: call browser_navigate first.", true
	}
	if d.devices == nil {
		d.devices = map[wire.UUID]*browser.Device{}
	}
	if device == nil {
		delete(d.devices, agent)
	} else {
		d.devices[agent] = device
	}
	own := append([]target.ID(nil), d.ownTabs[agent]...)
	d.tabsMu.Unlock()
	// The cast gives up the page's size before the device takes it, and takes it back after
	// (Cast.SetDevice).
	if device != nil {
		d.castDeviceChanged(agent, device)
	}
	var failed []string
	for _, tab := range own {
		if err := t.Emulate(tab, device); err != nil {
			failed = append(failed, err.Error())
		}
	}
	if device == nil {
		d.castDeviceChanged(agent, nil)
	}
	if len(failed) > 0 && len(failed) == len(own) {
		return "The device did not change: " + strings.Join(failed, "; "), true
	}
	if device == nil {
		return "This session's tabs are a desktop browser again.", false
	}
	touch := ""
	if device.Touch {
		touch = ", touch"
	}
	return fmt.Sprintf("This session's tabs are a %s now: %d×%d CSS pixels at %g×%s, with Chrome on Android's user agent. "+
		"Open pages laid out again; navigate again for a site to see the new user agent.",
		device.Name, device.Width, device.Height, device.Scale, touch), false
}

// followsTabs is whether agentsd follows the browser's tabs now.
func (d *Daemon) followsTabs() bool {
	d.tabsMu.Lock()
	defer d.tabsMu.Unlock()
	return d.tabs != nil
}

// sessionDevice is the profile agent's session has, nil for none.
func (d *Daemon) sessionDevice(agent wire.UUID) *browser.Device {
	d.tabsMu.Lock()
	defer d.tabsMu.Unlock()
	return d.devices[sessionKey(agent)]
}

// giveTabDevice gives a tab that is now owner's the profile of owner's session: a tab it
// opened, or one that moved to it from a session with another profile.
func (d *Daemon) giveTabDevice(owner wire.UUID, tab target.ID) {
	d.tabsMu.Lock()
	t, device := d.tabs, d.devices[sessionKey(owner)]
	d.tabsMu.Unlock()
	if t == nil || device == nil && t.EmulatedAs(tab) == nil {
		return
	}
	// Away from the browser's own events, which must not wait on a call to it.
	go func() {
		if err := t.Emulate(tab, device); err != nil {
			log.Printf("browser: couldn't give a tab its session's device: %v", err)
		}
	}()
}

// castDeviceChanged lays the cast of agent's session out as its new profile.
func (d *Daemon) castDeviceChanged(agent wire.UUID, device *browser.Device) {
	w := &d.bw
	w.mu.Lock()
	var cast *browser.Cast
	if sc := w.screens[agent]; sc != nil {
		cast = sc.cast
	}
	w.mu.Unlock()
	if cast != nil {
		if err := cast.SetDevice(device); err != nil {
			log.Printf("browser: couldn't lay the watched page out as the device: %v", err)
		}
	}
}
