package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A message wakes a session only when it may do no more without asking than the sender:
// one in a looser mode, or with its sandbox not on while the sender's is, keeps it queued
// until the person speaks. A session another session started takes messages only from it.

func inMode(mode string) func(*wire.Agent) {
	return func(a *wire.Agent) {
		cat := "mode"
		v, _ := json.Marshal(mode)
		a.AdvertisedOptions = []wire.ConfigOption{{ID: "mode", Name: "Mode", Type: "select", Category: &cat, CurrentValue: v}}
	}
}

func titledAs(title string, edits ...func(*wire.Agent)) func(*wire.Agent) {
	return func(a *wire.Agent) {
		a.Title = &title
		for _, e := range edits {
			e(a)
		}
	}
}

func TestMessageWakesOnlyAnAgentNoLooser(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	// Its many turns would fill what the window is told.
	go func() {
		for range c.out {
		}
	}()
	dir := t.TempDir()
	sandboxed := func(a *wire.Agent) {
		a.EffectiveSandbox = &wire.EffectiveSandbox{State: wire.SandboxStateOn, Requested: wire.SandboxChoiceOn}
	}
	lead := seeded(t, d, dir, titledAs("Lead", inMode("default")))
	loose := seeded(t, d, dir, titledAs("Loose", inMode("bypassPermissions"), func(a *wire.Agent) {
		wf := "nightly"
		a.StartedByWorkflow = &wf
	}))
	strict := seeded(t, d, dir, titledAs("Strict", inMode("plan")))
	boxed := seeded(t, d, dir, titledAs("Boxed", sandboxed))
	open := seeded(t, d, dir, titledAs("Open"))
	manager := seeded(t, d, dir, titledAs("Manager"))
	helper := seeded(t, d, dir, titledAs("Helper", func(a *wire.Agent) { a.StartedByAgent = &manager.ID }))
	sibling := seeded(t, d, dir, titledAs("Sibling", func(a *wire.Agent) { a.StartedByAgent = &manager.ID }))
	peer := seeded(t, d, dir, titledAs("Peer"))

	held := func(c *mcpClient, n int, to string, why string, target wire.UUID) {
		t.Helper()
		text, isErr := c.tool(n, "message_session", map[string]any{"to": to, "message": "do the work"})
		if isErr || text != "Sent to “"+to+"”, but it waits in that chat until the person speaks to it: "+why+"."+queuedMessageNote {
			t.Fatal(text)
		}
		a := d.Store.Agent(target)
		if len(a.QueuedPrompts) != 1 || a.State != wire.AgentStateFinished || d.hasTurn(a) {
			t.Fatalf("%+v", a)
		}
	}
	woken := func(c *mcpClient, n int, to string, target wire.UUID) {
		t.Helper()
		text, isErr := c.tool(n, "message_session", map[string]any{"to": to, "message": "do the work"})
		if isErr || text != "Sent to “"+to+"”, which is working on it now. A reply, if it sends one, comes to this session as a message."+queuedMessageNote {
			t.Fatal(text)
		}
		waitFor(t, "the message in "+to+"'s chat", func() bool {
			u := userMessages(d, target)
			return len(u) > 0 && u[len(u)-1] == "do the work"
		})
		waitFor(t, to+"'s turn over", func() bool { return d.Store.Agent(target).State == wire.AgentStateFinished })
	}

	m := appClient(t, d, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	// A looser mode: queued, not woken.
	held(m, 2, "Loose", "it runs in bypassPermissions, which lets it do more without asking than yours (default)", loose.ID)
	// A stricter one wakes.
	woken(m, 3, "Strict", strict.ID)

	// A sandbox not on, while the sender's is.
	b := appClient(t, d, boxed.ID)
	b.post("initialize", map[string]any{}, 1)
	held(b, 2, "Open", "its command sandbox is not on, and yours is", open.ID)

	// A helper wakes its own starter (#1695), and a session that has started none.
	h := appClient(t, d, helper.ID)
	h.post("initialize", map[string]any{}, 1)
	woken(h, 2, "Manager", manager.ID)
	woken(h, 3, "Peer", peer.ID)

	// Another session's helper, a sibling too, is refused, and nothing is queued.
	refused := func(c *mcpClient, n int, to string, target wire.UUID) {
		t.Helper()
		text, isErr := c.tool(n, "message_session", map[string]any{"to": to, "message": "do the work"})
		if !isErr || text != "Nothing was sent: “"+to+"” was started by “Manager”, and a session started by another session takes messages only from it. Send this to “Manager”." {
			t.Fatal(text)
		}
		if a := d.Store.Agent(target); len(a.QueuedPrompts) != 0 || len(userMessages(d, target)) != 0 {
			t.Fatalf("%+v", a)
		}
	}
	refused(m, 4, "Helper", helper.ID)
	refused(h, 4, "Sibling", sibling.ID)

	// The person speaking to it sends the held message, then theirs.
	if err := d.enqueue(loose.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: "go on", From: wire.PromptOriginPerson}, false); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both in Loose's chat", func() bool {
		return strings.Join(userMessages(d, loose.ID), "|") == "do the work|go on"
	})
}

func TestNextTurnPassesHeldMessagesOver(t *testing.T) {
	q := func(id string, from wire.PromptOrigin) wire.QueuedPrompt {
		return wire.QueuedPrompt{ID: wire.UUID(id), Text: id, From: from, Attachments: []wire.Attachment{}}
	}
	held := map[wire.UUID]bool{"m": true}
	// The app's words behind a held message go, and it stays.
	turn, rest, ok := nextTurn([]wire.QueuedPrompt{q("m", wire.PromptOriginAgent), q("a", wire.PromptOriginApp)}, held)
	if !ok || turn.Text != "a" || len(rest) != 1 || rest[0].ID != "m" {
		t.Fatal(turn, rest, ok)
	}
	// Only held: nothing goes.
	if _, rest, ok := nextTurn(rest, held); ok || len(rest) != 1 {
		t.Fatal(rest, ok)
	}
	// With the person's words queued too, it goes first.
	turn, rest, ok = nextTurn([]wire.QueuedPrompt{q("m", wire.PromptOriginAgent), q("p", wire.PromptOriginPerson)}, held)
	if !ok || turn.Text != "m" || len(rest) != 1 || rest[0].ID != "p" {
		t.Fatal(turn, rest, ok)
	}
}

// A session that set the sender going takes its messages at once, whatever its mode: it
// started the sender, or ran the workflow the sender belongs to (#1728). Others still wait.
func TestMessageWakesTheSessionThatSetTheSenderGoing(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	go func() {
		for range c.out {
		}
	}()
	dir := t.TempDir()
	lead := seeded(t, d, dir, titledAs("Lead", inMode("bypassPermissions")))
	runner := seeded(t, d, dir, titledAs("Runner", inMode("bypassPermissions")))
	other := seeded(t, d, dir, titledAs("Other", inMode("bypassPermissions")))
	lane := seeded(t, d, dir, titledAs("Lane", inMode("default"), func(a *wire.Agent) { a.StartedByAgent = &lead.ID }))
	ran := seeded(t, d, dir, titledAs("Release", inMode("auto"), func(a *wire.Agent) {
		wf := "release"
		a.StartedByWorkflow = &wf
	}))
	scheduled := seeded(t, d, dir, titledAs("Nightly", inMode("auto"), func(a *wire.Agent) {
		wf := "nightly"
		a.StartedByWorkflow = &wf
	}))
	d.workflowMu.Lock()
	d.noteRanByLocked(ran.ID, runner.ID)
	d.workflowMu.Unlock()

	send := func(from wire.UUID, to string) string {
		t.Helper()
		m := appClient(t, d, from)
		m.post("initialize", map[string]any{}, 1)
		text, isErr := m.tool(2, "message_session", map[string]any{"to": to, "message": "done: " + string(from)})
		if isErr {
			t.Fatal(text)
		}
		return text
	}
	delivered := func(from wire.UUID, to string, target wire.UUID) {
		t.Helper()
		if text := send(from, to); text != "Sent to “"+to+"”, which is working on it now. A reply, if it sends one, comes to this session as a message."+queuedMessageNote {
			t.Fatal(text)
		}
		waitFor(t, "the message in "+to+"'s chat", func() bool {
			u := userMessages(d, target)
			return len(u) > 0 && u[len(u)-1] == "done: "+string(from)
		})
		waitFor(t, to+"'s turn over", func() bool { return d.Store.Agent(target).State == wire.AgentStateFinished })
	}
	held := func(from wire.UUID, to string, target wire.UUID, why string) {
		t.Helper()
		if text := send(from, to); text != "Sent to “"+to+"”, but it waits in that chat until the person speaks to it: "+why+"."+queuedMessageNote {
			t.Fatal(text)
		}
		a := d.Store.Agent(target)
		if len(a.QueuedPrompts) != 1 || d.hasTurn(a) {
			t.Fatalf("%+v", a)
		}
	}
	// Its starter, and the session that ran its workflow, take it at once.
	delivered(lane.ID, "Lead", lead.ID)
	delivered(ran.ID, "Runner", runner.ID)
	// A session it did not start, and one whose workflow it did not run, still wait.
	held(lane.ID, "Other", other.ID, "it runs in bypassPermissions, which lets it do more without asking than yours (default)")
	held(scheduled.ID, "Runner", runner.ID, "it runs in bypassPermissions, which lets it do more without asking than yours (auto)")
}
