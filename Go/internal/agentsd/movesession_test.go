package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// move_session (#3717): a session goes on on another machine with its id, labels and
// transcript, after its branch and its uncommitted changes; this machine lets it go.

// movingPair is two machines on one fake control plane: here, where the agents ask, and
// there, which takes the sendFolder steps. It records the steps.
func movingPair(t *testing.T) (here, there *Daemon, c *conn, steps func() []string) {
	t.Helper()
	here, c = start(t, t.TempDir())
	t.Cleanup(here.Shutdown)
	there, _ = start(t, t.TempDir())
	t.Cleanup(there.Shutdown)
	var mu sync.Mutex
	var seen []string
	here.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, ok := params.(wire.MachineWorkspaceCall)
		b, _ := json.Marshal(call.Params)
		if !ok || call.Method != "machines/sendFolder" {
			return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
		}
		var s wire.MachineFolderSend
		json.Unmarshal(b, &s)
		var out wire.MachineFolderSent
		step := ""
		var err error
		switch {
		case s.State != nil:
			step = "state"
			var st wire.ReceiveState
			st, err = there.receiveState(*s.State)
			out.State = &st
		case s.Upload != nil:
			step = "upload"
			err = there.receiveUpload(*s.Upload)
		case s.Receive != nil:
			step = "receive"
			var f wire.FolderSummary
			f, err = there.receive(*s.Receive)
			out.Folder = &f
		case s.MoveIn != nil:
			step = "moveIn"
			in := *s.MoveIn
			in.From.Machine = "mac"
			err = there.moveIn(in)
		}
		mu.Lock()
		seen = append(seen, step)
		mu.Unlock()
		if err != nil {
			code, msg := errMessage(err)
			return nil, &controllink.AskError{Code: code, Message: msg}
		}
		r, _ := json.Marshal(out)
		return r, nil
	})
	return here, there, c, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(seen)
	}
}

func TestMoveSessionTakesAHelperThereWithItsWork(t *testing.T) {
	here, there, c, steps := movingPair(t)
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	os.WriteFile(filepath.Join(src, "login.go"), []byte("package login\n"), 0o644)
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "login")
	os.WriteFile(filepath.Join(src, "notes.txt"), []byte("not committed\n"), 0o644)
	head := sendGit(t, src, nil, "rev-parse", "HEAD")
	lead := seeded(t, here, src, nil)
	title := "Fix login"
	helper := seeded(t, here, src, func(a *wire.Agent) {
		a.Title, a.StartedByAgent = &title, &lead.ID
		a.Labels = []wire.SessionLabel{{Value: "#3717", Owner: wire.SessionLabelOwnerAgent, AddedAt: now()}}
	})
	here.record(helper.ID, runtimeNote("What it did here."))
	here.record(helper.ID, wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: "Fix the login page"}})
	m := appClient(t, here, lead.ID)
	m.post("initialize", map[string]any{}, 1)
	inTurn(here, lead.ID)
	folder := filepath.Join(canonical(t.TempDir()), "app")
	args := map[string]any{"machine": "pc", "folder": folder, "session": string(helper.ID)}

	answered := make(chan string, 1)
	go func() { text, _ := m.tool(2, "move_session", args); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		select {
		case text := <-answered:
			t.Fatal(text)
		default:
		}
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *f.Properties[0].Title != "Move the session “Fix login” to pc, with fix-login and its uncommitted changes, into "+
		folder+" there? It goes on there with this conversation." {
		t.Fatal(*f.Properties[0].Title)
	}
	if got := strings.Join(steps(), ","); got != "state" {
		t.Fatalf("before the yes: %s", got)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; !strings.HasPrefix(text, "Moved “Fix login” to pc, in "+folder+", with fix-login and its uncommitted changes (id "+string(helper.ID)+"). It waits there") {
		t.Fatal(text)
	}
	if got := strings.Join(steps(), ","); got != "state,state,upload,upload,receive,upload,moveIn" {
		t.Fatal(got)
	}

	// The work is there.
	if got := sendGit(t, folder, nil, "rev-parse", "HEAD"); got != head {
		t.Fatalf("there is at %s, not %s", got, head)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, "notes.txt")); string(b) != "not committed\n" {
		t.Fatalf("notes.txt there: %q", b)
	}
	// The session is there, as it was, and goes on in that machine's root.
	if here.Store.Agent(helper.ID) != nil {
		t.Fatal("this machine still has it")
	}
	a := there.Store.Agent(helper.ID)
	if a == nil {
		t.Fatal("the machine there does not have it")
	}
	if store.FolderPath(a.Cwd) != folder || a.State != wire.AgentStateFinished || a.MadeInRoot == nil || *a.MadeInRoot != there.Store.RootID ||
		a.MovedFrom == nil || a.MovedFrom.Machine != "mac" || len(a.Labels) != 1 || a.Labels[0].Value != "#3717" || a.Title == nil || *a.Title != title {
		t.Fatalf("%+v", a)
	}
	if notes := runtimeNotes(there, a.ID); !slices.Contains(notes, "What it did here.") || !slices.Contains(notes, "Moved here from mac, into "+folder+".") {
		t.Fatal(notes)
	}
	if p := there.branchPreface(a); p == nil || !strings.Contains(*p, "This conversation goes on from mac") || !strings.Contains(*p, "Fix the login page") {
		t.Fatalf("preface: %q", *p)
	}
	// Its starter here still reaches it there.
	if s := here.thereNamed(lead.ID, string(helper.ID)); s == nil || s.Machine != "pc" {
		t.Fatalf("%+v", s)
	}
	if left, _ := os.ReadDir(here.outgoingFolder()); len(left) != 0 {
		t.Fatalf("left in Outgoing: %v", left)
	}

	// Not one of the lead's: refused before anything is asked.
	other := seeded(t, here, src, nil)
	if text, isErr := m.tool(3, "move_session", map[string]any{"machine": "pc", "folder": folder, "session": string(other.ID)}); !isErr ||
		!strings.HasPrefix(text, "Nothing was moved: that is one of the person's own sessions.") {
		t.Fatal(text)
	}
}

func TestMoveSessionMovesItselfWhenTheTurnEnds(t *testing.T) {
	here, there, c, steps := movingPair(t)
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "big-build")
	me := seeded(t, here, src, func(a *wire.Agent) {
		a.State, a.EndedReason = wire.AgentStateRunning, nil
		id := "runtime-conversation"
		a.RuntimeSessionID = &id
	})
	folder := filepath.Join(canonical(t.TempDir()), "app")
	m := appClient(t, here, me.ID)
	m.post("initialize", map[string]any{}, 1)
	inTurn(here, me.ID)
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "move_session", map[string]any{"machine": "pc", "folder": folder})
		answered <- text
	}()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		select {
		case text := <-answered:
			t.Fatal(text)
		default:
		}
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; !strings.HasPrefix(text, "You move to pc when this turn ends") {
		t.Fatal(text)
	}
	if got := strings.Join(steps(), ","); got != "state" {
		t.Fatal(got)
	}
	// Taken back when the turn does not finish.
	here.afterTurnMachineMove(me.ID, wire.AgentStateStopped)
	if here.Store.Agent(me.ID) == nil || !slices.Contains(runtimeNotes(here, me.ID), "Did not move to pc: the turn did not finish. It stays here.") {
		t.Fatal(runtimeNotes(here, me.ID))
	}
	// Asked again, and made when it finishes: it carries on there in a conversation of its own.
	before := len(runtimeNotes(here, me.ID))
	here.machineMoves.Store(me.ID, machineMove{machine: "pc", folder: folder, asker: me.ID})
	here.change(me.ID, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateFinished, reason(wire.EndedReasonEndTurn) })
	here.afterTurnMachineMove(me.ID, wire.AgentStateFinished)
	waitFor(t, "the move", func() bool {
		if notes := runtimeNotes(here, me.ID); len(notes) > before && strings.HasPrefix(notes[len(notes)-1], "Did not move") {
			t.Fatal(notes[len(notes)-1])
		}
		return there.Store.Agent(me.ID) != nil && here.Store.Agent(me.ID) == nil
	})
	a := there.Store.Agent(me.ID)
	if a.RuntimeSessionID != nil && *a.RuntimeSessionID == "runtime-conversation" {
		t.Fatal("the runtime's conversation id came along")
	}
	if a.MovedFrom == nil || a.MovedFrom.Machine != "mac" {
		t.Fatalf("%+v", a.MovedFrom)
	}
	carried := func(s string) bool {
		return strings.HasPrefix(s, "You have moved to this machine") && strings.Contains(s, "on the branch big-build") && strings.HasSuffix(s, carryOn)
	}
	if !slices.ContainsFunc(userMessages(there, me.ID), carried) && !slices.ContainsFunc(a.QueuedPrompts, func(q wire.QueuedPrompt) bool { return carried(q.Text) }) {
		t.Fatalf("no carry-on: %v %+v", userMessages(there, me.ID), a.QueuedPrompts)
	}
}

// Move to Machine… (#3790): the person moves a session with agents/moveToMachine, with no
// card, and an archived one is refused before anything is asked.
func TestPersonMovesASessionToAMachine(t *testing.T) {
	here, there, c, steps := movingPair(t)
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	os.WriteFile(filepath.Join(src, "notes.txt"), []byte("not committed\n"), 0o644)
	a := seeded(t, here, src, nil)
	folder := filepath.Join(canonical(t.TempDir()), "app")

	var answer wire.MoveToMachineAnswer
	if err := json.Unmarshal(c.call(t, 1, "agents/moveToMachine", map[string]any{"agentID": a.ID, "machine": "pc", "folder": folder}), &answer); err != nil {
		t.Fatal(err)
	}
	if answer.Folder != folder || answer.CarriesOn {
		t.Fatalf("%+v", answer)
	}
	if got := strings.Join(steps(), ","); got != "state,state,upload,upload,receive,upload,moveIn" {
		t.Fatal(got)
	}
	if here.Store.Agent(a.ID) != nil || there.Store.Agent(a.ID) == nil {
		t.Fatal("the session did not move")
	}
	if b, _ := os.ReadFile(filepath.Join(folder, "notes.txt")); string(b) != "not committed\n" {
		t.Fatalf("notes.txt there: %q", b)
	}

	// No folder, and none of the project's there: the person is asked for one, by the machine's name.
	other := seeded(t, here, src, nil)
	if msg := c.callError(t, 3, "agents/moveToMachine", map[string]any{"agentID": other.ID, "machine": "7d4aih78", "machineName": "Workstation"}).Message; msg !=
		"Nothing was moved: this project has no one folder on Workstation. Give the folder there, as an absolute path." {
		t.Fatal(msg)
	}

	archived := seeded(t, here, src, func(a *wire.Agent) {
		r := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedReason = wire.AgentStateArchived, &r
	})
	before := len(steps())
	if msg := c.callError(t, 2, "agents/moveToMachine", map[string]any{"agentID": archived.ID, "machine": "pc", "folder": folder}).Message; !strings.HasSuffix(msg, "is archived. Unarchive it first.") {
		t.Fatal(msg)
	}
	if len(steps()) != before {
		t.Fatal(steps())
	}
}
