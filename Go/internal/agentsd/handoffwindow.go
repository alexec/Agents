package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"os/exec"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The hand-off in the real window (#5208, spike #5127). When the agents' browser is Google
// Chrome (#5207), its window is real, just below the screen. hand_to_person then gives the
// person that window, not the screencast: the "screen" lease is taken, the window with the
// agent's tab comes onto the screen and Chrome to the front, and the card says so. The
// person does the step there: a press-and-hold check, a Touch ID or iCloud Keychain passkey
// prompt, a CAPTCHA, none of which the screencast carries. When the card comes down (Done,
// Can't do it, or the hand-off ends any other way), the window goes back below the screen,
// the app that was in front before comes back, and the lease is let go.
//
// When it cannot (Chrome for Testing, another host than a Mac, no agents-drive, the screen
// held by another agent), the card is as before: Open the page, on the screencast.

// handOffWindowState is the Daemon's hand-offs in the real window, by the card's request id.
type handOffWindowState struct {
	windowMu sync.Mutex
	windows  map[wire.UUID]windowHandOff
}

// windowHandOff is one window on the screen for the person, and what puts things back.
type windowHandOff struct {
	agent wire.UUID
	tab   string
	// chrome is Google Chrome's pid; previous is the app that was in front before it.
	chrome, previous int
	// leased is whether the hand-off took the "screen" lease, so it lets it go.
	leased bool
}

// windowWaitsLongest is the most moving the window and bringing an app to the front may take.
const windowWaitsLongest = 5 * time.Second

// showBrowserWindow and hideBrowserWindow move the agents' browser window onto the screen
// and back below it; a test gives its own.
var (
	showBrowserWindow = func(d *Daemon, ctx context.Context, tab string) (int, error) { return d.browser.ShowWindow(ctx, tab) }
	hideBrowserWindow = func(d *Daemon, ctx context.Context, tab string) error { return d.browser.HideWindow(ctx, tab) }
)

// frontApp brings the app with this pid to the front, with agents-drive's "front", and says
// the pid that was in front before. A test gives its own.
var frontApp = func(pid int) (int, error) {
	cmd := exec.Command(driveHelper())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return 0, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 0, err
	}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	defer func() {
		stdin.Close()
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			cmd.Process.Kill()
		}
	}()
	frame, _ := json.Marshal(map[string]any{"action": "front", "pid": pid})
	if _, err := stdin.Write(append(frame, 0)); err != nil {
		return 0, err
	}
	type answer struct {
		OK       bool   `json:"ok"`
		Error    string `json:"error"`
		Previous int    `json:"previous"`
	}
	got := make(chan answer, 1)
	go func() {
		var a answer
		if b, err := bufio.NewReader(stdout).ReadBytes(0); err == nil {
			json.Unmarshal(b[:len(b)-1], &a)
		} else {
			a.Error = "agents-drive said nothing"
		}
		got <- a
	}()
	select {
	case a := <-got:
		if !a.OK {
			return a.Previous, errors.New(a.Error)
		}
		return a.Previous, nil
	case <-time.After(windowWaitsLongest):
		cmd.Process.Kill()
		return 0, fmt.Errorf("agents-drive did not answer in %s", windowWaitsLongest)
	}
}

// screenNowArgs is the "screen" lease, now or not at all: a hand-off does not wait in line.
var screenNowArgs = map[string]json.RawMessage{"name": json.RawMessage(`"screen"`), "wait": json.RawMessage(`false`)}

// showHandOffWindow gives the person the real window for the hand-off request, and says the
// window as the card names it; false when the card stays on the screencast.
func (d *Daemon) showHandOffWindow(agent, request wire.UUID) (string, bool) {
	if d.browser == nil || !d.desktopControlAvailable() {
		return "", false
	}
	held := d.holdsScreen(agent)
	if !held {
		if _, err := d.leaseResource(agent, screenNowArgs); err != nil || !d.holdsScreen(agent) {
			// Another agent has the screen: the person gets the screencast.
			return "", false
		}
	}
	letGo := func() {
		if !held && d.holdsScreen(agent) {
			d.releaseResource(agent, screenLeaseName)
		}
	}
	tab := string(d.sessionTab(agent))
	ctx, cancel := context.WithTimeout(context.Background(), windowWaitsLongest)
	defer cancel()
	chrome, err := showBrowserWindow(d, ctx, tab)
	if err != nil {
		letGo()
		return "", false
	}
	previous, err := frontApp(chrome)
	if err != nil {
		log.Printf("browser: the hand-off's window is on the screen, but Chrome did not come to the front: %v", err)
		if err := hideBrowserWindow(d, ctx, tab); err != nil {
			log.Printf("browser: couldn't put the window back below the screen: %v", err)
		}
		letGo()
		return "", false
	}
	d.windowMu.Lock()
	if d.windows == nil {
		d.windows = map[wire.UUID]windowHandOff{}
	}
	d.windows[request] = windowHandOff{agent: agent, tab: tab, chrome: chrome, previous: previous, leased: !held}
	d.windowMu.Unlock()
	log.Printf("browser: the hand-off's window is in front (Chrome pid %d, before it pid %d)", chrome, previous)
	return realWindowWords(d.sessionTabURL(agent)), true
}

// realWindowWords is the window as the card names it: "the agents' Chrome window, in front
// (accounts.google.com)".
func realWindowWords(page string) string {
	said := "the agents' Chrome window, in front"
	if u, err := url.Parse(page); err == nil && u.Hostname() != "" {
		said += " (" + u.Hostname() + ")"
	}
	return said
}

// hideHandOffWindow is the card for request come down: its window goes back below the
// screen, the app that was in front before comes back, and the "screen" lease is let go.
// It does nothing for a card that had no window.
func (d *Daemon) hideHandOffWindow(request wire.UUID) {
	d.windowMu.Lock()
	w, ok := d.windows[request]
	delete(d.windows, request)
	d.windowMu.Unlock()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), windowWaitsLongest)
	defer cancel()
	if err := hideBrowserWindow(d, ctx, w.tab); err != nil {
		log.Printf("browser: couldn't put the hand-off's window back below the screen: %v", err)
	}
	if w.previous > 0 && w.previous != w.chrome {
		if _, err := frontApp(w.previous); err != nil {
			log.Printf("browser: the app that was in front before the hand-off (pid %d) did not come back: %v", w.previous, err)
		}
	}
	if w.leased && d.holdsScreen(w.agent) {
		d.releaseResource(w.agent, screenLeaseName)
	}
}

// windowHandedOff is whether the person has one of agent's windows: its "screen" lease
// stays past its turn's end, as browser:agents does, until the card comes down.
func (d *Daemon) windowHandedOff(agent wire.UUID) bool {
	d.windowMu.Lock()
	defer d.windowMu.Unlock()
	for _, w := range d.windows {
		if w.agent == agent && w.leased {
			return true
		}
	}
	return false
}
