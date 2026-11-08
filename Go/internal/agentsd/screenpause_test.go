package agentsd

import (
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Pause on touch (#3004, US3, T027): the person's own touch pauses drive_screen where it
// is, Resume lets it go on from there, and Take Over lets go of the screen at once and
// keeps the agent off it for the rest of the turn. Only the person's own clients answer.

type toolAnswer struct {
	text  string
	isErr bool
}

// touchedMidType starts a drive_screen type that the fake helper says was touched part way,
// and waits until the agent's record carries the pause.
func touchedMidType(t *testing.T, d *Daemon, m *mcpClient, id wire.UUID) chan toolAnswer {
	t.Helper()
	answered := make(chan toolAnswer, 1)
	go func() {
		text, isErr := m.tool(2, "drive_screen", map[string]any{"app": "TextEdit", "action": "type", "text": "touch:abc"})
		answered <- toolAnswer{text, isErr}
	}()
	waitFor(t, "the pause on its record", func() bool {
		a := d.Store.Agent(id)
		return a != nil && a.DesktopControlPause != nil
	})
	if p := d.Store.Agent(id).DesktopControlPause; p.App != "TextEdit" {
		t.Fatalf("%+v", p)
	}
	select {
	case got := <-answered:
		t.Fatalf("answered while paused: %+v", got)
	default:
	}
	return answered
}

func drivingAgent(t *testing.T) (*Daemon, wire.Agent, *mcpClient) {
	t.Helper()
	prepareDrive(t)
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	enableDesktopControl(t, d)
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	return d, a, m
}

func TestATouchPausesDriveScreenUntilThePersonResumesIt(t *testing.T) {
	d, a, m := drivingAgent(t)
	person := &Client{Role: RoleControl, d: d}
	answered := touchedMidType(t, d, m, a.ID)

	// An agent cannot resume itself.
	if e := asError(d.resumeScreen(&Client{Role: RoleAgent, d: d}, a.ID)); e == nil || e.Code != CodeNotPermitted {
		t.Fatalf("%+v, wanted notPermitted", e)
	}
	if err := d.resumeScreen(person, a.ID); err != nil {
		t.Fatal(err)
	}
	// It goes on from where it stopped: the fake answers ok to what is left.
	if got := <-answered; got.isErr || got.text != "Typed into TextEdit." {
		t.Fatalf("%+v", got)
	}
	if d.Store.Agent(a.ID).DesktopControlPause != nil {
		t.Fatal("the pause stayed on the record after Resume")
	}
	if e := asError(d.resumeScreen(person, a.ID)); e == nil || !strings.Contains(e.Message, "not paused") {
		t.Fatalf("%+v, wanted notPaused", e)
	}
}

func TestTakeOverLetsGoOfTheScreenForTheRestOfTheTurn(t *testing.T) {
	d, a, m := drivingAgent(t)
	person := &Client{Role: RoleDevice, d: d}
	answered := touchedMidType(t, d, m, a.ID)

	if e := asError(d.takeOverScreen(&Client{Role: RoleAgent, d: d}, a.ID)); e == nil || e.Code != CodeNotPermitted {
		t.Fatalf("%+v, wanted notPermitted", e)
	}
	if err := d.takeOverScreen(person, a.ID); err != nil {
		t.Fatal(err)
	}
	if got := <-answered; !got.isErr || !strings.Contains(got.text, "the person took over the screen") {
		t.Fatalf("%+v", got)
	}
	if d.holdsScreen(a.ID) {
		t.Fatal("the screen lease is still held after Take Over")
	}
	if d.Store.Agent(a.ID).DesktopControlPause != nil {
		t.Fatal("the pause stayed on the record after Take Over")
	}
	d.driveMu.Lock()
	_, running := d.drives[a.ID]
	d.driveMu.Unlock()
	if running {
		t.Fatal("agents-drive still running after Take Over")
	}

	// Not taken straight back in the same turn.
	if text, isErr := m.tool(3, "drive_screen", map[string]any{"app": "TextEdit", "action": "read"}); !isErr || !strings.Contains(text, "took over") {
		t.Fatalf("%v %q", isErr, text)
	}
	if d.holdsScreen(a.ID) {
		t.Fatal("drive_screen took the screen back after Take Over")
	}
	if e := asError(d.takeOverScreen(person, a.ID)); e == nil || !strings.Contains(e.Message, "does not hold the screen") {
		t.Fatalf("%+v, wanted notHeld", e)
	}

	// The next turn may drive again.
	d.endScreenDrive(a.ID)
	if text, isErr := m.tool(4, "drive_screen", map[string]any{"app": "TextEdit", "action": "read"}); isErr || text != "fake tree" {
		t.Fatalf("%v %q", isErr, text)
	}
}

func TestStopEndsAPausedDriveScreen(t *testing.T) {
	d, a, m := drivingAgent(t)
	answered := touchedMidType(t, d, m, a.ID)
	d.end(d.live(a.ID), wire.AgentStateStopped, wire.EndedReasonCancelled)
	if got := <-answered; !got.isErr {
		t.Fatalf("%+v", got)
	}
	if d.holdsScreen(a.ID) || d.Store.Agent(a.ID).DesktopControlPause != nil {
		t.Fatal("Stop left the screen held or the pause on the record")
	}
}

// pauseNotice is the pause's notice among the needs, if it is posted.
func pauseNotice(d *Daemon, id wire.UUID) *wire.Need {
	d.attentionMu.Lock()
	needs := d.needs()
	d.attentionMu.Unlock()
	for _, n := range needs {
		if n.ID.Notice != nil && *n.ID.Notice == pauseNoticePrefix+string(id) {
			return &n
		}
	}
	return nil
}

// US4, scenario 2: a pause sends a notice to a client in the background, and the notice
// goes when the pause does.
func TestAPausePostsANoticeUntilThePersonAnswers(t *testing.T) {
	d, a, m := drivingAgent(t)
	answered := touchedMidType(t, d, m, a.ID)
	n := pauseNotice(d, a.ID)
	if n == nil || n.Kind != wire.NeedKindNotice || n.AgentID == nil || *n.AgentID != a.ID ||
		!strings.Contains(n.Headline.H3, "TextEdit") {
		t.Fatalf("%+v", n)
	}
	if err := d.resumeScreen(&Client{Role: RoleControl, d: d}, a.ID); err != nil {
		t.Fatal(err)
	}
	<-answered
	if n := pauseNotice(d, a.ID); n != nil {
		t.Fatalf("the notice stayed after Resume: %+v", n)
	}
}

func TestAMutedChatsPausePostsNoNotice(t *testing.T) {
	d, a, m := drivingAgent(t)
	d.change(a.ID, func(a *wire.Agent) { yes := true; a.IsMuted = &yes })
	answered := touchedMidType(t, d, m, a.ID)
	if n := pauseNotice(d, a.ID); n != nil {
		t.Fatalf("%+v", n)
	}
	if err := d.takeOverScreen(&Client{Role: RoleControl, d: d}, a.ID); err != nil {
		t.Fatal(err)
	}
	<-answered
}
