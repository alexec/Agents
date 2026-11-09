package agentsd

import (
	"context"
	"encoding/base64"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

const testSimulator = "6E7A7E1C-9A35-4D87-8E0B-5E0F7F2A0B12"

// fakeSimulator puts a simulator in place of simctl: its screen is picture, its name iPhone 17.
// It says how many times its screen was read.
func fakeSimulator(t *testing.T, picture *atomic.Value) *atomic.Int64 {
	t.Helper()
	var reads atomic.Int64
	shot, name := simulatorLiveShot, simulatorNameOf
	pace, window := simulatorLivePace.Swap(int64(20*time.Millisecond)), liveDriveWindow.Swap(int64(300*time.Millisecond))
	simulatorLiveShot = func(_ context.Context, udid string, height int) (wire.SimulatorScreen, error) {
		reads.Add(1)
		if udid != testSimulator || height != simulatorLiveHeight {
			t.Errorf("read %s at %d", udid, height)
		}
		return wire.SimulatorScreen{Jpeg: []byte(picture.Load().(string)), Width: 295, Height: 640}, nil
	}
	simulatorNameOf = func(context.Context, string) string { return "iPhone 17" }
	t.Cleanup(func() {
		simulatorLiveShot, simulatorNameOf = shot, name
		simulatorLivePace.Store(pace)
		liveDriveWindow.Store(window)
	})
	return &reads
}

// A simulator lease (#4222) says which simulator: simulator:<udid> or the UDID alone, in any
// case, is one resource of kind simulator.
func TestASimulatorLeaseNamesTheSimulator(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	for _, given := range []string{"simulator:" + testSimulator, " " + strings.ToLower(testSimulator) + " "} {
		name, kind, _, ok := d.resolveResource(given)
		if !ok || kind != "simulator" || name != wire.ResourceName("simulator:"+strings.ToLower(testSimulator)) {
			t.Fatalf("%q: %s %s", given, name, kind)
		}
	}
	if _, kind, _, _ := d.resolveResource("simulator"); kind != "named" {
		t.Fatalf("a bare simulator is %s", kind)
	}
}

// live/frame of a simulator (#4222): a frame within 2 seconds of the lease, and of each
// changed picture, to the client with the chat in front only; none more than liveDriveWindow
// after the last change; and with nobody in front, the screen is not read at all.
func TestLiveFrameOfASimulatorGoesWhileItsHolderDrivesIt(t *testing.T) {
	fakeRuntimes(t)
	var picture atomic.Value
	picture.Store("first")
	reads := fakeSimulator(t, &picture)
	d, front := start(t, t.TempDir())
	defer d.Shutdown()
	behind := newConn()
	go d.Accept(behind)
	t.Cleanup(func() { close(behind.in) })
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	behind.call(t, 1, "presence/report", map[string]any{"active": false, "showing": a.ID})
	agent := appClient(t, d, a.ID)
	agent.post("initialize", map[string]any{}, 1)

	// Nobody in front: the lease reads nothing.
	if text, _ := agent.tool(2, "lease_resource", map[string]any{"name": testSimulator}); !strings.HasPrefix(text, "You hold iPhone 17 until ") {
		t.Fatal(text)
	}
	time.Sleep(100 * time.Millisecond)
	if n := reads.Load(); n != 0 {
		t.Fatalf("read the screen %d times with nobody in front", n)
	}
	if !d.holdsLease(a.ID, wire.ResourceName("simulator:"+strings.ToLower(testSimulator))) {
		t.Fatal("not held")
	}
	// Leased again, the grant's drive is new: with the chat in front, a frame within 2 seconds.
	agent.tool(3, "release_resource", map[string]any{"name": "simulator:" + testSimulator})
	front.call(t, 1, "presence/report", map[string]any{"active": true, "showing": a.ID})
	agent.tool(4, "lease_resource", map[string]any{"name": "simulator:" + testSimulator})
	want := func(image string) {
		t.Helper()
		f := nextLive(t, front, 2*time.Second)
		if f == nil || f.Source != wire.LiveSourceSimulator || f.AgentID != a.ID || f.Image == nil ||
			*f.Image != base64.StdEncoding.EncodeToString([]byte(image)) || f.Title == nil || *f.Title != "iPhone 17" ||
			f.Width == nil || *f.Width != 295 || f.Height == nil || *f.Height != 640 {
			t.Fatalf("no frame of %q within 2 seconds: %+v", image, f)
		}
	}
	want("first")
	if f := nextLive(t, behind, 200*time.Millisecond); f != nil {
		t.Fatalf("a client not active got a frame: %+v", f)
	}
	// The same picture is no new frame.
	if f := nextLive(t, front, 200*time.Millisecond); f != nil {
		t.Fatalf("a frame of the same picture: %+v", f)
	}
	// A changed picture is a drive: a frame within 2 seconds.
	picture.Store("second")
	want("second")
	// Still for longer than the drive window: no frame.
	time.Sleep(400 * time.Millisecond)
	if f := nextLive(t, front, 200*time.Millisecond); f != nil {
		t.Fatalf("a frame with no drive: %+v", f)
	}
	picture.Store("third")
	want("third")
	// Back in front after the drive window, the first picture is only a start: no frame.
	front.call(t, 2, "presence/report", map[string]any{"active": false, "showing": a.ID})
	time.Sleep(400 * time.Millisecond)
	picture.Store("away")
	front.call(t, 3, "presence/report", map[string]any{"active": true, "showing": a.ID})
	if f := nextLive(t, front, 300*time.Millisecond); f != nil {
		t.Fatalf("a frame more than the drive window after the last drive: %+v", f)
	}
	picture.Store("back")
	want("back")

	// Let go: the screen is not read any more.
	agent.tool(5, "release_resource", map[string]any{"name": testSimulator})
	time.Sleep(100 * time.Millisecond)
	after := reads.Load()
	picture.Store("fourth")
	time.Sleep(200 * time.Millisecond)
	if n := reads.Load(); n != after {
		t.Fatalf("read the screen %d more times after the release", n-after)
	}
	if f := nextLive(t, front, 100*time.Millisecond); f != nil {
		t.Fatalf("a frame after the release: %+v", f)
	}
}
