package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A message wakes a session only when it may do no more without asking than the sender:
// one in a looser mode, with its sandbox not on while the sender's is, or, for a sender an
// agent started, one that has started sessions, keeps it queued until the person speaks.

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
	peer := seeded(t, d, dir, titledAs("Peer"))

	held := func(c *mcpClient, n int, to string, why string, target wire.UUID) {
		t.Helper()
		text, isErr := c.tool(n, "message_session", map[string]any{"to": to, "message": "do the work"})
		if isErr || text != "Sent to “"+to+"”, but it waits in that chat until the person speaks to it: "+why+"." {
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
		if isErr || text != "Sent to “"+to+"”, which is working on it now. A reply, if it sends one, comes to this session as a message." {
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

	// A helper may not wake a session that has started sessions, its own starter too.
	h := appClient(t, d, helper.ID)
	h.post("initialize", map[string]any{}, 1)
	held(h, 2, "Manager", "it has started sessions of its own, and you were started by a session", manager.ID)
	// But it wakes one that has started none.
	woken(h, 3, "Peer", peer.ID)

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
