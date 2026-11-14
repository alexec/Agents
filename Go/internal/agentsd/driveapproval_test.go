package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// askDrive turns the ask back on for one test: the package's tests start at Always Approve.
func askDrive(t *testing.T) {
	t.Helper()
	was := askDriveByDefault
	askDriveByDefault = true
	t.Cleanup(func() { askDriveByDefault = was })
}

// driveSetUp is a person's machine with the browser, and one agent's app client on it.
func driveSetUp(t *testing.T) (*Daemon, *mcpClient, wire.UUID) {
	t.Helper()
	askDrive(t)
	fakeBrowser(t)
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	d.SettingsDir = t.TempDir()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	return d, m, a.ID
}

// browserAsync is a browser call on its own goroutine, as an agent's held call.
func browserAsync(m *mcpClient, id int) chan browserReply {
	done := make(chan browserReply, 1)
	go func() { done <- m.browserTool(id, "browser_snapshot", nil) }()
	return done
}

func openDriveRequests(d *Daemon) int {
	n := 0
	for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
		if s := r.Detail.SecretUse; s != nil && (s.Use == wire.SecretUseBrowser || s.Use == wire.SecretUseScreen) {
			n++
		}
	}
	return n
}

// #4264: on a machine a person uses, the browser asks before each lease. Approve is for the
// lease, until the agent lets go of it; Deny refuses every call in the turn; the turn's end
// lets it ask again.
func TestTheBrowserAsksBeforeEachLease(t *testing.T) {
	answered, left := formHolds(t)
	d, m, agent := driveSetUp(t)

	done := browserAsync(m, 2)
	r := openSecretUse(t, d)
	s := r.Detail.SecretUse
	if r.Kind != wire.RequestKindApprove || s.Use != wire.SecretUseBrowser || s.Name != "the browser" || s.Place == "" ||
		!strings.HasPrefix(r.Title, "Use the browser on ") || r.AskedBy == nil || *r.AskedBy != agent {
		t.Fatalf("%+v %+v", r, s)
	}
	if d.holdsBrowser(agent) {
		t.Fatal("the lease was taken before a person approved it")
	}
	answerUse(t, d, r, secretUseOnce)
	if got := replyOf(t, done); got.IsError || !d.holdsBrowser(agent) {
		t.Fatalf("%+v", got)
	}
	// The same lease: no ask.
	if got := m.browserTool(3, "browser_snapshot", nil); got.IsError || openDriveRequests(d) != 0 {
		t.Fatalf("%+v asked again under the same lease", got)
	}

	// Let go of it: the next lease asks again, and a hold that ends says what to wait on.
	if said, _ := m.tool(4, "release_resource", map[string]any{"name": "browser:agents"}); !strings.Contains(said, "Released") {
		t.Fatal(said)
	}
	left()
	got := m.browserTool(5, "browser_snapshot", nil)
	r = openSecretUse(t, d)
	if got.IsError || !strings.Contains(replyText(got), `"request": "`+string(r.ID)+`"`) || d.holdsBrowser(agent) {
		t.Fatalf("%+v", got)
	}
	answered()

	// Deny: the call fails, and the rest of the turn does not ask again.
	answerUse(t, d, r, secretUseDeny)
	got = m.browserTool(6, "browser_snapshot", nil)
	if !got.IsError || !strings.Contains(replyText(got), "Do not ask again in this turn") || openDriveRequests(d) != 0 {
		t.Fatalf("%+v", got)
	}
	// The turn's end: the next turn may ask.
	d.endBrowserDrive(agent)
	left()
	m.browserTool(7, "browser_snapshot", nil)
	if openDriveRequests(d) != 1 {
		t.Fatal("the next turn did not ask")
	}
}

// Approve for This Session lasts across leases; Always Approve sets the machine's setting.
func TestTheBrowserApprovedForTheSessionOrAlways(t *testing.T) {
	formHolds(t)
	d, m, agent := driveSetUp(t)

	done := browserAsync(m, 2)
	answerUse(t, d, openSecretUse(t, d), secretUseSession)
	if got := replyOf(t, done); got.IsError {
		t.Fatalf("%+v", got)
	}
	m.tool(3, "release_resource", map[string]any{"name": "browser:agents"})
	if got := m.browserTool(4, "browser_snapshot", nil); got.IsError || openDriveRequests(d) != 0 {
		t.Fatalf("%+v asked again in the same session", got)
	}

	d.forgetSessionSecretUses(agent) // as its archive does
	m.tool(5, "release_resource", map[string]any{"name": "browser:agents"})
	done = browserAsync(m, 6)
	answerUse(t, d, openSecretUse(t, d), secretUseAlways)
	if got := replyOf(t, done); got.IsError || d.browserControlMode() != wire.DriveApprovalAlways {
		t.Fatalf("%+v %s", got, d.browserControlMode())
	}
}

// lease_resource of the screen asks too, and names it; the answer takes the lease.
func TestALeaseOfTheScreenAsks(t *testing.T) {
	formHolds(t)
	d, m, agent := driveSetUp(t)
	done := make(chan string, 1)
	go func() {
		said, _ := m.tool(2, "lease_resource", map[string]any{"name": "screen", "minutes": 5})
		done <- said
	}()
	r := openSecretUse(t, d)
	if r.Detail.SecretUse.Use != wire.SecretUseScreen || r.Detail.SecretUse.Name != "the screen" {
		t.Fatalf("%+v", r.Detail.SecretUse)
	}
	answerUse(t, d, r, secretUseOnce)
	if said := <-done; !strings.Contains(said, "You hold") || !d.holdsScreen(agent) {
		t.Fatal(said)
	}
	// Extending a lease it holds does not ask.
	if said, _ := m.tool(3, "lease_resource", map[string]any{"name": "screen", "minutes": 10}); !strings.Contains(said, "now until") || openDriveRequests(d) != 0 {
		t.Fatal(said)
	}
}

// drive_screen's ask names the app.
func TestDriveScreenAsksNamingTheApp(t *testing.T) {
	prepareDrive(t)
	formHolds(t)
	d, m, agent := driveSetUp(t)
	done := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "read"})
		done <- text
	}()
	r := openSecretUse(t, d)
	if s := r.Detail.SecretUse; s.Use != wire.SecretUseScreen || s.App == nil || *s.App != "TextEdit" || !strings.Contains(r.Title, "TextEdit") {
		t.Fatalf("%+v %+v", r, s)
	}
	answerUse(t, d, r, secretUseOnce)
	if text := <-done; text != "fake tree" || !d.holdsScreen(agent) {
		t.Fatal(text)
	}
}

// A machine only agents use never asks: a Codespace here.
func TestAMachineOnlyAgentsUseNeverAsks(t *testing.T) {
	t.Setenv("CODESPACES", "true")
	d, m, _ := driveSetUp(t)
	if got := m.browserTool(2, "browser_snapshot", nil); got.IsError || openDriveRequests(d) != 0 {
		t.Fatalf("%+v", got)
	}
	if d.browserControlMode() != wire.DriveApprovalAlways || d.desktopControlMode() != wire.DriveApprovalAlways {
		t.Fatal(d.browserControlMode(), d.desktopControlMode())
	}
	// Ask counts as Always Approve there: nobody answers.
	if _, err := d.saveBrowserControl(wire.DriveApprovalAsk); err != nil {
		t.Fatal(err)
	}
	m.tool(3, "release_resource", map[string]any{"name": "browser:agents"})
	if got := m.browserTool(4, "browser_snapshot", nil); got.IsError || openDriveRequests(d) != 0 {
		t.Fatalf("%+v", got)
	}
}

// Off: the browser tools are not listed, and are refused, naming where to turn it on.
func TestTheBrowserOffIsNotOffered(t *testing.T) {
	d, m, _ := driveSetUp(t)
	c := &Client{Role: RoleControl, d: d}
	var st wire.BrowserControlSettings
	if err := callAs(d, c, "browserControl/set", wire.BrowserControlSettings{Mode: wire.DriveApprovalOff}, &st); err != nil || st.Mode != wire.DriveApprovalOff {
		t.Fatalf("%+v %v", st, err)
	}
	if _, list := m.post("tools/list", nil, 2); strings.Contains(string(list["result"]), `"browser_navigate"`) {
		t.Fatal("listed while Off")
	}
	if got := m.browserTool(3, "browser_snapshot", nil); !got.IsError || replyText(got) != browserOffWords {
		t.Fatalf("%+v", got)
	}
}

// Only a person's own clients change the browser's setting (#4012's rule).
func TestBrowserControlSetRefusesEveryoneButThePerson(t *testing.T) {
	d, _, _ := driveSetUp(t)
	for _, role := range []Role{RoleAgent, RoleHostApp, RoleWindow, RoleStranger} {
		var st wire.BrowserControlSettings
		if err := asError(callAs(d, &Client{Role: role, d: d}, "browserControl/set", wire.BrowserControlSettings{Mode: wire.DriveApprovalAlways}, &st)); err == nil || err.Code != CodeNotPermitted {
			t.Fatalf("%s: %+v, wanted notPermitted", role, err)
		}
		if role.Allows("browserControl/set") {
			t.Fatalf("the %s role may call browserControl/set", role)
		}
	}
	if d.browserControlMode() != wire.DriveApprovalAsk {
		t.Fatal(d.browserControlMode())
	}
}

// callAs is one method's handler, as client c calls it.
func callAs(d *Daemon, c *Client, method string, in, out any) error {
	b, _ := json.Marshal(in)
	res, err := d.handlers[method](context.Background(), c, b)
	if err != nil {
		return err
	}
	rb, _ := json.Marshal(res)
	return json.Unmarshal(rb, out)
}
