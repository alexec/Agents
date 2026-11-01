package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Desktop control is Off until the person turns it on (#3004, US2, FR-004, T019): while it
// is Off, drive_screen is refused before it takes the screen lease or starts agents-drive,
// and it is not offered at all. Only the person's own clients can turn it on.

func TestDriveScreenIsRefusedWhileDesktopControlIsOff(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	// Off by default: not offered, even on a host with agents-drive beside it (only a Mac
	// is one; offeredTools' own case is in apptools_test.go).
	_, list := m.post("tools/list", nil, 2)
	if strings.Contains(string(list["result"]), `"drive_screen"`) {
		t.Fatal("drive_screen offered while desktop control is Off")
	}

	// And refused when called anyway, naming the rule and where to turn it on.
	text, isErr := m.tool(3, "drive_screen", map[string]any{"app": "TextEdit", "action": "type", "text": "rm -rf ~\n"})
	if !isErr || !strings.Contains(text, "Desktop control is off") || !strings.Contains(text, "Settings") {
		t.Fatalf("%v %q", isErr, text)
	}
	d.driveMu.Lock()
	_, started := d.drives[a.ID]
	d.driveMu.Unlock()
	if started {
		t.Fatal("agents-drive started while desktop control is Off")
	}
	if held, _ := m.tool(4, "list_resources", nil); strings.Contains(held, "Holding Screen") {
		t.Fatal(held)
	}

	// On: offered, and it drives.
	if _, err := d.setDesktopControl(&Client{Role: RoleControl, d: d}, wire.DesktopControlSettings{Enabled: true}); err != nil {
		t.Fatal(err)
	}
	_, list = m.post("tools/list", nil, 5)
	if d.desktopControlAvailable() && !strings.Contains(string(list["result"]), `"drive_screen"`) {
		t.Fatal("drive_screen not offered once desktop control is on")
	}
	if text, isErr := m.tool(6, "drive_screen", map[string]any{"app": "TextEdit", "action": "read"}); isErr || text != "fake tree" {
		t.Fatal(text)
	}
}

func TestDesktopControlIsSavedAndReadBack(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	var st wire.DesktopControlSettings
	json.Unmarshal(c.call(t, 1, "desktopControl/state", nil), &st)
	if st.Enabled {
		t.Fatalf("%+v, wanted Off by default", st)
	}
	json.Unmarshal(c.call(t, 2, "desktopControl/set", wire.DesktopControlSettings{Enabled: true}), &st)
	if !st.Enabled || !d.desktopControlOn() {
		t.Fatalf("%+v", st)
	}
	b, err := os.ReadFile(filepath.Join(d.SettingsDir, "desktop-control.json"))
	var saved struct {
		Enabled bool `json:"enabled"`
	}
	if err != nil || json.Unmarshal(b, &saved) != nil || !saved.Enabled {
		t.Fatalf("%s %v", b, err)
	}
	json.Unmarshal(c.call(t, 3, "desktopControl/set", wire.DesktopControlSettings{Enabled: false}), &st)
	if st.Enabled || d.desktopControlOn() {
		t.Fatalf("%+v", st)
	}
}

// TestDesktopControlSetRefusesTheAgentSocketRole: an MCP tool call and a workflow run both
// reach a host method only over the agent socket role (no app tool or workflow action calls
// desktopControl/set), so the handler's own gate and the role table cover all three, the
// same shape as TestSetYoursRefusesTheAgentSocketRole.
func TestDesktopControlSetRefusesTheAgentSocketRole(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	for _, role := range []Role{RoleAgent, RolePairing, RoleHostApp, RoleWindow, RoleStranger} {
		_, err := d.setDesktopControl(&Client{Role: role, d: d}, wire.DesktopControlSettings{Enabled: true})
		if e := asError(err); e == nil || e.Code != CodeNotPermitted {
			t.Fatalf("%s: %+v, wanted notPermitted", role, err)
		}
		if role.Allows("desktopControl/set") {
			t.Fatalf("the %s role may call desktopControl/set", role)
		}
	}
	if d.desktopControlOn() {
		t.Fatal("turned on by a refused caller")
	}
	for _, tc := range appToolCalls() {
		if strings.Contains(strings.ToLower(tc.name), "desktop") {
			t.Fatalf("an app tool reaches desktop control: %s", tc.name)
		}
	}
}
