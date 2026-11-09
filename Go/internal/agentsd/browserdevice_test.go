package agentsd

import (
	"strings"
	"testing"
)

// browser_emulate_device (#4086): listed with the browser tools, and refused for a device
// there is none of, or with no browser tabs to give it to.

func TestEmulateDeviceIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"browser_emulate_device"`) {
		t.Fatal("no browser_emulate_device")
	}
	if got := appToolMethod(emulateDeviceName); got != "browser/emulateDevice" {
		t.Fatal(got)
	}
}

func TestEmulateDeviceRefusesAnUnknownDevice(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	r := m.browserTool(2, emulateDeviceName, map[string]any{"device": "watch"})
	if !r.IsError || !strings.Contains(replyText(r), `no device "watch"`) {
		t.Fatalf("%+v", r)
	}
}

func TestEmulateDeviceNeedsTheBrowsersTabs(t *testing.T) {
	m, _, d := fillSetUp(t, nil)
	r := m.browserTool(2, emulateDeviceName, map[string]any{"device": "phone"})
	if !r.IsError || !strings.Contains(replyText(r), "isn't running") {
		t.Fatalf("%+v", r)
	}
	if len(d.devices) != 0 {
		t.Fatal("a profile kept with no tabs")
	}
}
