package agentsd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// fakeDriveSource answers every request with {"ok":true}, never touching a real screen:
// enough to test drive_screen's lease, queue and Stop plumbing without Accessibility or
// Screen Recording granted to anything (mirroring lease_resource's own queuing test,
// TestAgentsTakeTurnsWithAResource).
const fakeDriveSource = `package main

import (
	"bufio"
	"encoding/json"
	"os"
)

func main() {
	r := bufio.NewReader(os.Stdin)
	for {
		frame, err := r.ReadBytes(0)
		if err != nil {
			return
		}
		var req map[string]any
		json.Unmarshal(frame[:len(frame)-1], &req)
		res := map[string]any{"ok": true, "trusted": true}
		switch req["action"] {
		case "screenshot":
			res["image"] = "ZmFrZQ=="
		case "read":
			res["tree"] = "fake tree"
		}
		b, _ := json.Marshal(res)
		b = append(b, 0)
		os.Stdout.Write(b)
	}
}
`

var (
	builtDrive     string
	builtDriveErr  error
	buildDriveOnce sync.Once
)

// prepareDrive gives this test a fake agents-drive, built once per run with `go build`
// (available inside the container Go/scripts/go.sh itself runs tests in), or a skip where
// there is none.
func prepareDrive(t *testing.T) {
	t.Helper()
	buildDriveOnce.Do(func() {
		goBin, err := exec.LookPath("go")
		if err != nil {
			builtDriveErr = err
			return
		}
		dir, err := os.MkdirTemp("", "agents-drive-fake")
		if err != nil {
			builtDriveErr = err
			return
		}
		src := filepath.Join(dir, "main.go")
		if err := os.WriteFile(src, []byte(fakeDriveSource), 0o600); err != nil {
			builtDriveErr = err
			return
		}
		out := filepath.Join(dir, "agents-drive")
		if b, err := exec.Command(goBin, "build", "-o", out, src).CombinedOutput(); err != nil {
			builtDriveErr = &exec.Error{Name: "go build " + string(b), Err: err}
			return
		}
		builtDrive = out
	})
	if builtDriveErr != nil {
		t.Skipf("no agents-drive to drive with: %v", builtDriveErr)
	}
	old := driveHelper
	driveHelper = func() string { return builtDrive }
	t.Cleanup(func() { driveHelper = old })
}

// enableDesktopControl turns the switch on directly, the way setDesktopControl's own
// write does (desktop-control.json, research R5), so a test of drive_screen itself does
// not also have to drive desktopControl/set.
func enableDesktopControl(t *testing.T, d *Daemon) {
	t.Helper()
	os.MkdirAll(d.SettingsDir, 0o700)
	if err := os.WriteFile(filepath.Join(d.SettingsDir, "desktop-control.json"), []byte(`{"enabled":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDriveScreenTakesTheScreenLeaseAndQueuesBehindAnotherAgent(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	enableDesktopControl(t, d)
	dir := t.TempDir()
	first := seeded(t, d, dir, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	firstClient := appClient(t, d, first.ID)
	secondAgent := seeded(t, d, dir, nil)
	second := appClient(t, d, secondAgent.ID)
	firstClient.post("initialize", map[string]any{}, 1)
	second.post("initialize", map[string]any{}, 1)

	// First call takes the lease and drives at once.
	if text, isErr := firstClient.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "screenshot"}); isErr || text != "Screenshot of TextEdit." {
		t.Fatal(text)
	}
	if text, _ := firstClient.tool(3, "list_resources", nil); !strings.Contains(text, "Yours:\n- Holding Screen, mouse and keyboard (screen) until ") {
		t.Fatal(text)
	}

	// A second agent calling it queues behind the first, exactly as lease_resource's own
	// callers do, and is not driven yet.
	if text, _ := second.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "screenshot"}); !strings.HasSuffix(text,
		"You are 1st in line. You will get a lease.granted event when it is yours. End your turn, and you will be started again with it.") {
		t.Fatal(text)
	}
	w := d.Store.Agent(secondAgent.ID).EventWait
	if name, ok := lineWaitResource(w, secondAgent.ID); !ok || name != "screen" {
		t.Fatalf("%+v", w)
	}

	// Stop ends the first agent's turn: it frees the lease (and its agents-drive) at once,
	// the way pressing Stop must (US1's independent test).
	d.end(d.live(first.ID), wire.AgentStateStopped, wire.EndedReasonCancelled)
	d.driveMu.Lock()
	_, stillRunning := d.drives[first.ID]
	d.driveMu.Unlock()
	if stillRunning {
		t.Fatal("agents-drive still tracked for the stopped agent")
	}
	waitFor(t, "the wake in its chat", func() bool {
		for _, u := range userMessages(d, secondAgent.ID) {
			if strings.HasPrefix(u, "The event you were waiting for happened.\n\nlease.granted at ") && strings.Contains(u, "\nresource: screen") {
				return true
			}
		}
		return false
	})

	// Granted, a new call drives at once.
	second = appClient(t, d, secondAgent.ID)
	second.post("initialize", map[string]any{}, 1)
	if text, isErr := second.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "read"}); isErr || text != "fake tree" {
		t.Fatal(text)
	}
}

// notTrustedDriveSource is a second fake agents-drive, answering "access" with
// trusted: false and everything else with ok: true.
const notTrustedDriveSource = `package main

import (
	"bufio"
	"encoding/json"
	"os"
)

func main() {
	r := bufio.NewReader(os.Stdin)
	for {
		frame, err := r.ReadBytes(0)
		if err != nil {
			return
		}
		var req map[string]any
		json.Unmarshal(frame[:len(frame)-1], &req)
		res := map[string]any{"ok": true, "trusted": false}
		b, _ := json.Marshal(res)
		b = append(b, 0)
		os.Stdout.Write(b)
	}
}
`

// buildFakeDrive compiles source into a throwaway agents-drive, or skips the test when
// there is no "go" to build it with.
func buildFakeDrive(t *testing.T, source string) string {
	t.Helper()
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skipf("no agents-drive to drive with: %v", err)
	}
	dir := t.TempDir()
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "agents-drive")
	if b, err := exec.Command(goBin, "build", "-o", out, src).CombinedOutput(); err != nil {
		t.Skipf("no agents-drive to drive with: %v %s", err, b)
	}
	return out
}

// TestDriveScreenRefusesAccessibilityNotGrantedUntilTrusted (#3004, US2, FR-005): once
// desktop control is on, drive_screen still refuses until Accessibility is granted, before
// the "screen" lease is ever taken; granted, the same call succeeds with no further prompt.
func TestDriveScreenRefusesAccessibilityNotGrantedUntilTrusted(t *testing.T) {
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	enableDesktopControl(t, d)
	dir := t.TempDir()
	agent := seeded(t, d, dir, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })

	notTrusted := buildFakeDrive(t, notTrustedDriveSource)
	old := driveHelper
	driveHelper = func() string { return notTrusted }
	t.Cleanup(func() { driveHelper = old })

	text, err := d.driveScreen(agent.ID, map[string]json.RawMessage{"app": json.RawMessage(`"TextEdit"`), "action": json.RawMessage(`"screenshot"`)})
	if err == nil || !strings.Contains(err.Error(), "Accessibility") || !strings.Contains(err.Error(), "System Settings") {
		t.Fatalf("%v, %v", text, err)
	}
	d.leaseMu.Lock()
	d.loadLeases()
	held := d.book.Entries[wire.ResourceName("screen")] != nil && holderIndex(d.book.Entries[wire.ResourceName("screen")], agent.ID) >= 0
	d.leaseMu.Unlock()
	if held {
		t.Fatal("the screen lease was taken while Accessibility is not granted")
	}

	// Granted (a fresh helper that answers trusted: true, mirroring the Mac granting it to
	// the same long-lived process without this test's two different fakes colliding):
	// succeeds.
	d.releaseScreenDrive(agent.ID)
	trusted := buildFakeDrive(t, fakeDriveSource)
	driveHelper = func() string { return trusted }
	text, err = d.driveScreen(agent.ID, map[string]json.RawMessage{"app": json.RawMessage(`"TextEdit"`), "action": json.RawMessage(`"screenshot"`)})
	if err != nil || text != "Screenshot of TextEdit." {
		t.Fatalf("%v, %v", text, err)
	}
}
