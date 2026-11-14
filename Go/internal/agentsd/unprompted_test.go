package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// An unprompted turn (#4323): a runtime's cycle of its own after its prompt was answered,
// as Claude's on a background command's end, is a turn, so the app's tools that need one
// work in it, and the agent is not Done until it ends.

// backgroundBuild starts an agent whose runtime answers its prompt, then works on its own
// until the file it returns is there; it is back once that cycle has begun.
func backgroundBuild(t *testing.T, words string) (*Daemon, *conn, wire.UUID, string) {
	t.Helper()
	fakeBrowser(t)
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	release := filepath.Join(t.TempDir(), "release")
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": words + release, "startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []string{}}}), &id)
	c.until(t, "the prompt's end", ended(id, wire.AgentStateFinished))
	c.until(t, "the runtime's own turn", ended(id, wire.AgentStateRunning))
	return d, c, id, release
}

func TestAHandOffWorksInATurnTheRuntimeBeganItself(t *testing.T) {
	d, c, id, release := backgroundBuild(t, "Run the build in the background, then wait for ")
	m := appClient(t, d, id)
	m.post("initialize", map[string]any{}, 1)
	answered := make(chan browserReply, 1)
	go func() { answered <- m.browserTool(2, "hand_to_person", captcha) }()
	req := pendingHandOff(t, c)
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept",
		"content": map[string]any{"outcome": "done"}})
	if r := <-answered; r.IsError {
		t.Fatalf("refused: %s", replyText(r))
	}
	if a := d.Store.Agent(id); a.State != wire.AgentStateRunning {
		t.Fatalf("%s while the runtime still works", a.State)
	}
	// The cycle's result ends it, with a report from its own last words.
	os.WriteFile(release, nil, 0o600)
	c.until(t, "the runtime's own turn's end", ended(id, wire.AgentStateFinished))
	a := d.Store.Agent(id)
	if a.Report == nil || a.Report.Message != "The build finished." {
		t.Fatalf("%+v", a.Report)
	}
	if l := d.live(id); func() bool { l.mu.Lock(); defer l.mu.Unlock(); return l.inTurn || l.unprompted }() {
		t.Fatal("still in a turn")
	}
}

// A cycle whose first words come as the prompt's turn still ends begins its own turn when
// that one has ended (#4568), and keeps those words for its report.
func TestACycleBegunAsThePromptEndsIsATurnOfItsOwn(t *testing.T) {
	hold := func(l *live) {
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			l.mu.Lock()
			late := l.late
			l.mu.Unlock()
			if late {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	promptAnswered.Store(&hold)
	defer promptAnswered.Store(nil)
	d, c, id, release := backgroundBuild(t, "Run the build in the background, then wait for ")
	if l := d.live(id); func() bool { l.mu.Lock(); defer l.mu.Unlock(); return !l.unprompted }() {
		t.Fatal("no turn of its own")
	}
	os.WriteFile(release, nil, 0o600)
	c.until(t, "the runtime's own turn's end", ended(id, wire.AgentStateFinished))
	if a := d.Store.Agent(id); a.Report == nil || a.Report.Message != "The build finished." {
		t.Fatalf("%+v", a.Report)
	}
}

func TestATurnTheRuntimeBeganEndsWhenItGoesQuiet(t *testing.T) {
	was := unpromptedQuiet
	unpromptedQuiet = 300 * time.Millisecond
	defer func() { unpromptedQuiet = was }()
	d, c, id, release := backgroundBuild(t, "Quietly run the build in the background, then wait for ")
	os.WriteFile(release, nil, 0o600)
	c.until(t, "the quiet end", ended(id, wire.AgentStateFinished))
	if a := d.Store.Agent(id); a.Report == nil || a.Report.Message != "The build finished." {
		t.Fatalf("%+v", a.Report)
	}
}

func TestAStopEndsATurnTheRuntimeBegan(t *testing.T) {
	d, c, id, _ := backgroundBuild(t, "Run the build in the background, then wait for ")
	c.call(t, 2, "agents/stop", map[string]any{"agentID": id})
	waitFor(t, "the stop", func() bool {
		a := d.Store.Agent(id)
		return a.State == wire.AgentStateStopped && a.EndedReason != nil && *a.EndedReason == wire.EndedReasonCancelled
	})
}

// A call from the runtime before any word of its own cycle begins the turn too.
func TestAnAskerBeginsATurnForALiveRuntime(t *testing.T) {
	d, c, id, release := backgroundBuild(t, "Run the build in the background, then wait for ")
	l := d.live(id)
	if !l.leaveUnprompted() {
		t.Fatal("no turn of its own")
	}
	if _, err := d.asker(id, "refused"); err != nil {
		t.Fatal(err)
	}
	if !l.leaveUnprompted() {
		t.Fatal("the call began no turn")
	}
	os.WriteFile(release, nil, 0o600)
	// The cycle's last words and result end a turn of their own: wait for it, so the
	// daemon writes nothing in its root as the test's folders go (#4568).
	c.until(t, "the runtime's own turn's end", ended(id, wire.AgentStateFinished))
}
