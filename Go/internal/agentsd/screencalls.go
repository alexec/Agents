package agentsd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// drive_screen (#3004, US1): an agent drives a named app through its own screen, mouse and
// keyboard, for a task no API reaches. It takes the "screen" lease the same way
// lease_resource does (leasecalls.go's resolveResource already knows "screen"), reusing
// its grant/queue path rather than inventing a second one (research R4); a second agent
// calling it queues exactly as lease_resource's own callers do. agents-drive is the
// sibling helper that does the actual driving (research R1), one process per agent
// holding the lease, talked to over a NUL-delimited JSON request/reply protocol on its
// stdin/stdout, started on first use and ended when the lease is let go or the turn ends.

// driveHelper is agents-drive's path: beside this binary, mirroring watchHelper
// (watch_darwin.go). A var so a test can swap it for one it built itself.
var driveHelper = func() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "agents-drive")
}

// driveProcess is one running agents-drive, talked to one request at a time.
type driveProcess struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	out   *bufio.Reader
	mu    sync.Mutex
}

// screenDriveState is the Daemon's own agents-drive processes, one per agent holding the
// "screen" lease. Under driveMu.
type screenDriveState struct {
	driveMu sync.Mutex
	drives  map[wire.UUID]*driveProcess
}

func (p *driveProcess) call(req map[string]any) (map[string]any, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	b, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	b = append(b, 0)
	if _, err := p.stdin.Write(b); err != nil {
		return nil, fmt.Errorf("agents-drive: %w", err)
	}
	frame, err := p.out.ReadBytes(0)
	if err != nil {
		return nil, fmt.Errorf("agents-drive: %w", err)
	}
	var res map[string]any
	if err := json.Unmarshal(frame[:len(frame)-1], &res); err != nil {
		return nil, fmt.Errorf("agents-drive: %w", err)
	}
	return res, nil
}

func (p *driveProcess) stop() {
	p.stdin.Close()
	done := make(chan struct{})
	go func() { p.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		p.cmd.Process.Kill()
	}
}

// screenDriveFor is this agent's agents-drive, started on first use.
func (d *Daemon) screenDriveFor(agent wire.UUID) (*driveProcess, error) {
	d.driveMu.Lock()
	defer d.driveMu.Unlock()
	if d.drives == nil {
		d.drives = map[wire.UUID]*driveProcess{}
	}
	if p, ok := d.drives[agent]; ok {
		return p, nil
	}
	helper := driveHelper()
	if fi, err := os.Stat(helper); helper == "" || err != nil || fi.Mode()&0o111 == 0 {
		return nil, fmt.Errorf("agents-drive is not beside this host")
	}
	cmd := exec.Command(helper)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &driveProcess{cmd: cmd, stdin: stdin, out: bufio.NewReader(stdout)}
	d.drives[agent] = p
	return p, nil
}

// releaseScreenDrive ends this agent's agents-drive, if one is running. Called when the
// "screen" lease is let go and when its turn ends, so no process outlives either.
func (d *Daemon) releaseScreenDrive(agent wire.UUID) {
	d.driveMu.Lock()
	p := d.drives[agent]
	delete(d.drives, agent)
	d.driveMu.Unlock()
	if p != nil {
		p.stop()
	}
}

// stopScreenDrives ends every agents-drive this host started (Daemon.Shutdown).
func (d *Daemon) stopScreenDrives() {
	d.driveMu.Lock()
	ps := d.drives
	d.drives = nil
	d.driveMu.Unlock()
	for _, p := range ps {
		p.stop()
	}
}

// endScreenDrive is what Stop, and every other turn ending, does to a "screen" lease and
// its agents-drive: both let go at once, the same shape dropAppTokens already gives every
// other app tool's state on an ending (turns.go's end).
func (d *Daemon) endScreenDrive(agent wire.UUID) {
	d.releaseScreenDrive(agent)
	d.leaseMu.Lock()
	d.loadLeases() // every other turn ends without ever leasing anything: d.book may be nil.
	e := d.book.Entries[wire.ResourceName("screen")]
	held := e != nil && holderIndex(e, agent) >= 0
	d.leaseMu.Unlock()
	if held {
		d.releaseResource(agent, map[string]json.RawMessage{"name": json.RawMessage(`"screen"`)})
	}
}

// desktopControlAvailable is host.desktop-control/1: a Mac, with agents-drive beside this
// binary (research R1). Gates drive_screen out of tools/list on every other host (#3004).
func (d *Daemon) desktopControlAvailable() bool {
	if goruntime.GOOS != "darwin" {
		return false
	}
	helper := driveHelper()
	fi, err := os.Stat(helper)
	return helper != "" && err == nil && fi.Mode()&0o111 != 0
}

var driveScreenActions = map[string]bool{"screenshot": true, "click": true, "type": true, "key": true, "read": true}

// driveScreen is drive_screen.
func (d *Daemon) driveScreen(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	app := argString(args, "app")
	action := argString(args, "action")
	if strings.TrimSpace(app) == "" || !driveScreenActions[action] {
		return "", Invalid("Nothing was driven: say `app`, and `action` (screenshot, click, type, key or read).")
	}
	if d.Store.Agent(agent) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}
	// Off by default (FR-004): refused before the lease is taken or agents-drive starts.
	if !d.desktopControlOn() {
		return "", &Error{Code: CodeNotPermitted, Message: desktopControlOffWords}
	}
	reply, err := d.leaseResource(agent, map[string]json.RawMessage{"name": json.RawMessage(`"screen"`)})
	if err != nil {
		return "", err
	}
	d.leaseMu.Lock()
	e := d.book.Entries[wire.ResourceName("screen")]
	held := e != nil && holderIndex(e, agent) >= 0
	d.leaseMu.Unlock()
	if !held {
		// Queued behind another agent: told its place, started again on lease.granted.
		return reply, nil
	}
	p, err := d.screenDriveFor(agent)
	if err != nil {
		// Can never work this turn either: give back the lease rather than leave it held
		// uselessly.
		d.endScreenDrive(agent)
		return "", &Error{Message: "drive_screen: " + err.Error()}
	}
	req := map[string]any{"action": action, "app": app}
	if label := argString(args, "label"); label != "" {
		req["label"] = label
	}
	if raw, ok := args["x"]; ok {
		var x float64
		json.Unmarshal(raw, &x)
		req["x"] = x
	}
	if raw, ok := args["y"]; ok {
		var y float64
		json.Unmarshal(raw, &y)
		req["y"] = y
	}
	if text := argString(args, "text"); text != "" {
		req["text"] = text
	}
	if keyName := argString(args, "keyName"); keyName != "" {
		req["keyName"] = keyName
	}
	res, err := p.call(req)
	if err != nil {
		// A dead helper takes nothing else with it: drop it so the next call starts fresh.
		d.releaseScreenDrive(agent)
		return "", &Error{Message: "drive_screen: " + err.Error()}
	}
	ok, _ := res["ok"].(bool)
	if !ok {
		msg, _ := res["error"].(string)
		if msg == "" {
			msg = "agents-drive refused that."
		}
		return "", &Error{Message: msg}
	}
	switch action {
	case "screenshot":
		data, _ := res["image"].(string)
		d.appMu.Lock()
		if d.images == nil {
			d.images = map[wire.UUID]pendingImage{}
		}
		d.images[agent] = pendingImage{Data: data, Mime: "image/jpeg"}
		d.appMu.Unlock()
		return "Screenshot of " + app + ".", nil
	case "read":
		tree, _ := res["tree"].(string)
		return tree, nil
	case "click":
		if label := argString(args, "label"); label != "" {
			return "Clicked " + label + " in " + app + ".", nil
		}
		return fmt.Sprintf("Clicked %s at %s,%s.", app, string(args["x"]), string(args["y"])), nil
	case "type":
		return "Typed into " + app + ".", nil
	default: // "key"
		return "Pressed " + argString(args, "keyName") + " in " + app + ".", nil
	}
}
