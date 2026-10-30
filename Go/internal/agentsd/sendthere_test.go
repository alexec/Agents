package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// start_session with send (#2929): the branch the agent is on, with its uncommitted
// changes, goes to the folder on the other machine through machines/sendFolder before the
// start, and only after the person's yes; a folder there with work of its own, or an
// offline machine, refuses before the person is asked.

func TestStartSessionSendsTheBranchFirst(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	os.WriteFile(filepath.Join(src, "login.go"), []byte("package login\n"), 0o644)
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "login")
	os.WriteFile(filepath.Join(src, "notes.txt"), []byte("not committed\n"), 0o644)
	head := sendGit(t, src, nil, "rev-parse", "HEAD")
	title := "fix-login"
	a := seeded(t, d, src, func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	// The other machine is this one, at another path: the steps go to its own methods.
	there := filepath.Join(canonical(t.TempDir()), "app")

	var mu sync.Mutex
	var steps []string
	var starts []wire.MachineSessionStart
	offline := false
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call := params.(wire.MachineWorkspaceCall)
		b, _ := json.Marshal(call.Params)
		mu.Lock()
		defer mu.Unlock()
		switch call.Method {
		case "machines/sendFolder":
			if offline {
				return nil, &controllink.AskError{Code: wire.FailureHostOffline, Message: "pc is offline."}
			}
			var s wire.MachineFolderSend
			json.Unmarshal(b, &s)
			var out wire.MachineFolderSent
			switch {
			case s.State != nil:
				steps = append(steps, "state")
				st, err := d.receiveState(*s.State)
				if err != nil {
					return nil, err
				}
				out.State = &st
			case s.Upload != nil:
				steps = append(steps, "upload")
				if err := d.receiveUpload(*s.Upload); err != nil {
					return nil, err
				}
			case s.Receive != nil:
				steps = append(steps, "receive")
				f, err := d.receive(*s.Receive)
				if err != nil {
					return nil, &controllink.AskError{Code: wire.FailureFolderInTheWay, Message: err.Error()}
				}
				out.Folder = &f
			}
			r, _ := json.Marshal(out)
			return r, nil
		case "machines/startSession":
			var s wire.MachineSessionStart
			json.Unmarshal(b, &s)
			starts = append(starts, s)
			return json.RawMessage(`"11111111-2222-3333-4444-555555555555"`), nil
		}
		return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
	})
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	on := map[string]any{"prompt": "Check the Windows bug", "machine": "pc", "folder": there, "send": true}

	// Offline: refused before the card, saying how to start it.
	offline = true
	if text, isErr := m.tool(2, "start_session", on); !isErr ||
		text != "Nothing was sent or started on pc: pc is offline. Start it with start_machine, then try again." {
		t.Fatal(text)
	}
	mu.Lock()
	offline = false
	mu.Unlock()

	answered := make(chan string, 1)
	go func() { text, _ := m.tool(3, "start_session", on); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *f.Properties[0].Title != "Send fix-login, with its uncommitted changes, to "+there+" on pc, then start a session there to “Check the Windows bug”?" {
		t.Fatal(*f.Properties[0].Title)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "state" {
		t.Fatalf("before the yes: %v", steps)
	}
	mu.Unlock()
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; !strings.HasPrefix(text, "Sent fix-login, with its uncommitted changes, to "+there+" on pc. Started “Check the Windows bug” on pc") {
		t.Fatal(text)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "state,upload,upload,receive" || len(starts) != 1 || starts[0].Start.Cwd != store.PathURL(there) {
		t.Fatalf("%v %+v", steps, starts)
	}
	steps = nil
	mu.Unlock()
	if got := sendGit(t, there, nil, "rev-parse", "HEAD"); got != head {
		t.Fatalf("there is at %s, not %s", got, head)
	}
	if b, _ := os.ReadFile(filepath.Join(there, "notes.txt")); string(b) != "not committed\n" {
		t.Fatalf("notes.txt there: %q", b)
	}
	if left, _ := os.ReadDir(d.outgoingFolder()); len(left) != 0 {
		t.Fatalf("left in Outgoing: %v", left)
	}

	// Work of its own there: refused before the card, and nothing goes.
	os.WriteFile(filepath.Join(there, "mine.txt"), []byte("mine\n"), 0o644)
	if text, isErr := m.tool(4, "start_session", on); !isErr ||
		text != "Nothing was sent or started on pc: "+there+" has changes of its own there." {
		t.Fatal(text)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "state" || len(starts) != 1 {
		t.Fatalf("%v %d", steps, len(starts))
	}
	mu.Unlock()

	// On no branch: nothing is asked of the control plane.
	sendGit(t, src, nil, "checkout", "-q", "--detach")
	if text, isErr := m.tool(5, "start_session", on); !isErr || !strings.HasPrefix(text, "Nothing was sent or started: ") ||
		!strings.HasSuffix(text, "is on no branch. Check out a branch to send.") {
		t.Fatal(text)
	}
}
