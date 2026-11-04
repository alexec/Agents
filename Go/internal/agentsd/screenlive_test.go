package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
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

// The live tile (#3004, US4, FR-011): a client showing an agent that holds the screen gets
// a frame after each action and again while it is idle; one not showing it gets none, and
// no frame is ever in the agent's saved chat (FR-016).
func TestTheLiveTileGoesOnlyToClientsShowingTheAgent(t *testing.T) {
	prepareDrive(t)
	fakeRuntimes(t)
	old := liveFrameIdle.Swap(int64(50 * time.Millisecond))
	t.Cleanup(func() { liveFrameIdle.Store(old) })
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
	// Idle: frames keep coming without another action.
	if f := nextLiveFrame(t, showing, 5*time.Second); f == nil || f.Image == nil ||
		f.Narration == nil || *f.Narration != "Clicked Save in TextEdit." {
		t.Fatalf("no idle frame: %+v", f)
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
