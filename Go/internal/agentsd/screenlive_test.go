package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// nextLiveFrame is the next desktopControl/liveFrame c hears, or nil after wait.
func nextLiveFrame(t *testing.T, c *conn, wait time.Duration) *wire.DesktopControlLiveFrame {
	t.Helper()
	deadline := time.After(wait)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifyDesktopControlLiveFrame.Name {
				continue
			}
			var f wire.DesktopControlLiveFrame
			json.Unmarshal(m.Params, &f)
			return &f
		case <-deadline:
			return nil
		}
	}
}

// nextLive is the next live/frame c hears, or nil after wait.
func nextLive(t *testing.T, c *conn, wait time.Duration) *wire.LiveFrame {
	t.Helper()
	deadline := time.After(wait)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifyLiveFrame.Name {
				continue
			}
			var f wire.LiveFrame
			json.Unmarshal(m.Params, &f)
			return &f
		case <-deadline:
			return nil
		}
	}
}

// The live tile (#3004, US4, FR-011): a client showing an agent that holds the screen gets
// a frame after each action, and none while it is idle (#4139); one not showing it gets
// none, and no frame is ever in the agent's saved chat (FR-016).
func TestTheLiveTileGoesOnlyToClientsShowingTheAgent(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	d, showing := start(t, t.TempDir())
	defer d.Shutdown()
	other := newConn()
	go d.Accept(other)
	t.Cleanup(func() { close(other.in) })
	enableDesktopControl(t, d)
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	showing.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	other.call(t, 1, "presence/report", map[string]any{"active": true})
	agent := appClient(t, d, a.ID)
	agent.post("initialize", map[string]any{}, 1)

	if text, isErr := agent.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "click", "label": "Save"}); isErr {
		t.Fatal(text)
	}
	f := nextLiveFrame(t, showing, 5*time.Second)
	if f == nil || f.AgentID != a.ID || f.Image == nil || *f.Image != "ZmFrZQ==" || f.Locked != nil ||
		f.Narration == nil || *f.Narration != "Clicked Save in TextEdit." {
		t.Fatalf("no frame after the action: %+v", f)
	}
	// Idle: no frame comes without another action (#4139).
	if f := nextLiveFrame(t, showing, 300*time.Millisecond); f != nil {
		t.Fatalf("an idle frame: %+v", f)
	}
	if f := nextLiveFrame(t, other, 300*time.Millisecond); f != nil {
		t.Fatalf("a client not showing the agent got a frame: %+v", f)
	}
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	b, _ := json.Marshal(entries)
	if strings.Contains(string(b), "ZmFrZQ==") {
		t.Fatal("a frame is in the saved chat")
	}

	// The turn ends: the screen is let go, and the frames stop.
	d.endScreenDrive(a.ID)
	time.Sleep(100 * time.Millisecond)
	for nextLiveFrame(t, showing, 20*time.Millisecond) != nil {
	}
	if f := nextLiveFrame(t, showing, 300*time.Millisecond); f != nil {
		t.Fatalf("a frame after the screen was let go: %+v", f)
	}
}

// While the Mac's screen is locked the tile says so and carries no picture (FR-012).
func TestTheLiveTileShowsNoPictureWhileTheScreenIsLocked(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	d, showing := start(t, t.TempDir())
	defer d.Shutdown()
	enableDesktopControl(t, d)
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	showing.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	agent := appClient(t, d, a.ID)
	agent.post("initialize", map[string]any{}, 1)
	locked := "locked"
	d.eventMu.Lock()
	d.eventStateNow.PersonAway = &locked
	d.eventMu.Unlock()

	if text, isErr := agent.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "screenshot"}); isErr {
		t.Fatal(text)
	}
	f := nextLiveFrame(t, showing, 5*time.Second)
	if f == nil || f.Locked == nil || !*f.Locked || f.Image != nil ||
		f.Narration == nil || *f.Narration != "Screenshot of TextEdit." {
		t.Fatalf("not the locked placeholder: %+v", f)
	}
}

// live/frame (#4139): a frame of the screen within 2 seconds of a drive_screen action, only
// to a client with the agent's chat in front (an active report that shows it); one that
// shows it but is not active, or is active on another chat, gets none.
func TestLiveFrameOfTheScreenGoesOnlyToTheChatInFront(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	d, front := start(t, t.TempDir())
	defer d.Shutdown()
	behind, elsewhere := newConn(), newConn()
	go d.Accept(behind)
	go d.Accept(elsewhere)
	t.Cleanup(func() { close(behind.in); close(elsewhere.in) })
	enableDesktopControl(t, d)
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	front.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	behind.call(t, 1, "presence/report", map[string]any{"active": false, "showing": a.ID})
	elsewhere.call(t, 1, "presence/report", map[string]any{"active": true, "showing": "6E7A7E1C-9A35-4D87-8E0B-5E0F7F2A0B11"})
	agent := appClient(t, d, a.ID)
	agent.post("initialize", map[string]any{}, 1)

	if text, isErr := agent.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "click", "label": "Save"}); isErr {
		t.Fatal(text)
	}
	f := nextLive(t, front, 2*time.Second)
	if f == nil || f.Source != wire.LiveSourceScreen || f.AgentID != a.ID || f.Image == nil || *f.Image != "ZmFrZQ==" ||
		f.Narration == nil || *f.Narration != "Clicked Save in TextEdit." {
		t.Fatalf("no live frame in front within 2 seconds: %+v", f)
	}
	if f := nextLive(t, behind, 300*time.Millisecond); f != nil {
		t.Fatalf("a client not active got a live frame: %+v", f)
	}
	if f := nextLive(t, elsewhere, 300*time.Millisecond); f != nil {
		t.Fatalf("a client showing another chat got a live frame: %+v", f)
	}
}

// Frames go only while the agent drives (#4139): none more than liveDriveWindow after its
// last call, and none when no client has the chat in front.
func TestLiveFramesStopAfterTheDriveAndWithNoneInFront(t *testing.T) {
	old := liveDriveWindow.Swap(int64(100 * time.Millisecond))
	t.Cleanup(func() { liveDriveWindow.Store(old) })
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {})
	image := "ZmFrZQ=="
	frame := wire.LiveFrame{Source: wire.LiveSourceBrowser, AgentID: a.ID, Image: &image}

	ended := make(chan struct{}, 1)
	d.drove(a.ID, wire.LiveSourceBrowser, func() { ended <- struct{}{} })
	if d.sendLive(frame) {
		t.Fatal("a frame went with no client in front")
	}
	c.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	if !d.sendLive(frame) || nextLive(t, c, time.Second) == nil {
		t.Fatal("no frame while the agent drives and the chat is in front")
	}
	if d.sendLive(wire.LiveFrame{Source: wire.LiveSourceScreen, AgentID: a.ID, Image: &image}) {
		t.Fatal("a frame of a source the agent does not drive")
	}
	select {
	case <-ended:
	case <-time.After(2 * time.Second):
		t.Fatal("the drive did not end")
	}
	if d.sendLive(frame) {
		t.Fatal("a frame after the drive ended")
	}
	if f := nextLive(t, c, 200*time.Millisecond); f != nil {
		t.Fatalf("a frame after the drive ended: %+v", f)
	}
}
