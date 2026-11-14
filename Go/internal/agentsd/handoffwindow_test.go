package agentsd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	goruntime "runtime"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The hand-off in the real window (#5208): the agents' Google Chrome window comes onto the
// screen and to the front for the person, and goes back, with the app before it, when the
// card comes down.

// fakeWindow is the agents' browser window and agents-drive's "front", as a test sees them.
type fakeWindow struct {
	mu      sync.Mutex
	shown   []string
	hidden  []string
	fronted []int
	showErr error
}

func (w *fakeWindow) calls() (shown, hidden []string, fronted []int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.shown), slices.Clone(w.hidden), slices.Clone(w.fronted)
}

// chromePid and beforePid are the agents' Chrome, and the app in front before the hand-off.
const (
	chromePid = 4242
	beforePid = 77
)

func realWindow(t *testing.T) *fakeWindow {
	t.Helper()
	if goruntime.GOOS != "darwin" {
		t.Skip("the real window is a Mac's (agents-drive)")
	}
	helper := filepath.Join(t.TempDir(), "agents-drive")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	w := &fakeWindow{}
	oldHelper, oldShow, oldHide, oldFront := driveHelper, showBrowserWindow, hideBrowserWindow, frontApp
	driveHelper = func() string { return helper }
	showBrowserWindow = func(_ *Daemon, _ context.Context, tab string) (int, error) {
		w.mu.Lock()
		defer w.mu.Unlock()
		if w.showErr != nil {
			return 0, w.showErr
		}
		w.shown = append(w.shown, tab)
		return chromePid, nil
	}
	hideBrowserWindow = func(_ *Daemon, _ context.Context, tab string) error {
		w.mu.Lock()
		defer w.mu.Unlock()
		w.hidden = append(w.hidden, tab)
		return nil
	}
	frontApp = func(pid int) (int, error) {
		w.mu.Lock()
		defer w.mu.Unlock()
		w.fronted = append(w.fronted, pid)
		return beforePid, nil
	}
	t.Cleanup(func() { driveHelper, showBrowserWindow, hideBrowserWindow, frontApp = oldHelper, oldShow, oldHide, oldFront })
	return w
}

func TestAHandOffInTheRealWindow(t *testing.T) {
	w := realWindow(t)
	m, c, d, id := handOffSetUp(t)
	inTurn(d, id)
	press := map[string]any{"step": "Press and hold the button", "reason": "Microsoft asks a person to prove they're human."}
	answered := make(chan browserReply, 1)
	go func() { answered <- m.browserTool(2, "hand_to_person", press) }()
	req := pendingHandOff(t, c)
	if h := req.HandOff; h == nil || h.Window == nil || *h.Window != "the agents' Chrome window, in front" {
		t.Fatalf("%+v", req.HandOff)
	}
	if shown, hidden, fronted := w.calls(); len(shown) != 1 || len(hidden) != 0 || !slices.Equal(fronted, []int{chromePid}) {
		t.Fatalf("shown %v, hidden %v, fronted %v", shown, hidden, fronted)
	}
	if !d.holdsScreen(id) {
		t.Fatal("the window is in front with no screen lease")
	}
	// The turn's end keeps the screen while the person has the window.
	d.endScreenDrive(id)
	if !d.holdsScreen(id) {
		t.Fatal("the turn's end gave the screen away while the person has the window")
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept", "content": map[string]any{"outcome": "done"}})
	if r := <-answered; r.IsError || !strings.HasPrefix(replyText(r), `The person did "Press and hold the button".`) {
		t.Fatalf("%+v", r)
	}
	if _, hidden, fronted := w.calls(); len(hidden) != 1 || !slices.Equal(fronted, []int{chromePid, beforePid}) {
		t.Fatalf("hidden %v, fronted %v", hidden, fronted)
	}
	if d.holdsScreen(id) {
		t.Fatal("the screen is still held after Done")
	}
}

// When another agent has the screen, or the window cannot come onto it, the card is the
// screencast's, as before: Open the page, and no screen lease kept.
func TestAHandOffWithNoRealWindow(t *testing.T) {
	w := realWindow(t)
	m, c, d, id := handOffSetUp(t)
	inTurn(d, id)
	other := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	if _, err := d.leaseResource(other.ID, screenNowArgs); err != nil || !d.holdsScreen(other.ID) {
		t.Fatal(err)
	}
	answered := make(chan browserReply, 1)
	go func() { answered <- m.browserTool(2, "hand_to_person", captcha) }()
	req := pendingHandOff(t, c)
	if req.HandOff == nil || req.HandOff.Window != nil {
		t.Fatalf("%+v", req.HandOff)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept", "content": map[string]any{"outcome": "done"}})
	<-answered
	d.releaseResource(other.ID, screenLeaseName)

	w.mu.Lock()
	w.showErr = errors.New("the browser has no window to show")
	w.mu.Unlock()
	go func() { answered <- m.browserTool(3, "hand_to_person", captcha) }()
	req = pendingHandOff(t, c)
	if req.HandOff == nil || req.HandOff.Window != nil {
		t.Fatalf("%+v", req.HandOff)
	}
	if d.holdsScreen(id) {
		t.Fatal("kept the screen for a window that did not show")
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept", "content": map[string]any{"outcome": "done"}})
	<-answered
	if shown, hidden, fronted := w.calls(); len(shown) != 0 || len(hidden) != 0 || len(fronted) != 0 {
		t.Fatalf("shown %v, hidden %v, fronted %v", shown, hidden, fronted)
	}
}

func TestRealWindowWords(t *testing.T) {
	if got := realWindowWords("https://accounts.google.com/v3/signin"); got != "the agents' Chrome window, in front (accounts.google.com)" {
		t.Fatal(got)
	}
	if got := realWindowWords(""); got != "the agents' Chrome window, in front" {
		t.Fatal(got)
	}
}
