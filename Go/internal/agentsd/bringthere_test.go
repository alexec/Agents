package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// bring_back (#2947): a branch of a folder on another machine comes back into the agent's
// repository through machines/sendFolder, with its uncommitted changes when asked, and only
// after the person's yes; an offline machine, or a branch it does not have, refuses before
// the person is asked.

func TestBringBackBringsTheBranchHere(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	// The other machine is this one, at another path: the steps go to its own methods.
	there := filepath.Join(canonical(t.TempDir()), "app")
	sendGit(t, filepath.Dir(there), nil, "clone", "-q", "-b", "fix-login", src, there)
	sendGit(t, there, nil, "config", "user.email", "t@example.com")
	sendGit(t, there, nil, "config", "user.name", "T")
	os.WriteFile(filepath.Join(there, "login.go"), []byte("package login\n"), 0o644)
	sendGit(t, there, nil, "add", "-A")
	sendGit(t, there, nil, "commit", "-q", "-m", "login")
	os.WriteFile(filepath.Join(there, "notes.txt"), []byte("not committed\n"), 0o644)
	head := sendGit(t, there, nil, "rev-parse", "HEAD")
	title := "fix-login"
	a := seeded(t, d, src, func(a *wire.Agent) {
		a.State, a.EndedReason, a.RuntimeID, a.Title = wire.AgentStateRunning, nil, "claude", &title
	})
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	var mu sync.Mutex
	var steps []string
	offline := false
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call := params.(wire.MachineWorkspaceCall)
		if call.Method != "machines/sendFolder" {
			return nil, &controllink.AskError{Code: -32010, Message: "Agents can’t ask that of the control plane."}
		}
		mu.Lock()
		defer mu.Unlock()
		if offline {
			return nil, &controllink.AskError{Code: wire.FailureHostOffline, Message: "pc is offline."}
		}
		b, _ := json.Marshal(call.Params)
		var s wire.MachineFolderSend
		json.Unmarshal(b, &s)
		var out wire.MachineFolderSent
		var err error
		switch {
		case s.Facts != nil:
			steps = append(steps, "facts")
			f, e := d.sendFacts(*s.Facts)
			out.Facts, err = &f, e
		case s.Pack != nil:
			steps = append(steps, "pack")
			p, e := d.sendPack(*s.Pack)
			out.Pack, err = &p, e
		case s.Read != nil:
			steps = append(steps, "read")
			r, e := d.sendRead(*s.Read)
			out.Read, err = &r, e
		}
		if err != nil {
			code, msg := errMessage(err)
			return nil, &controllink.AskError{Code: code, Message: msg}
		}
		r, _ := json.Marshal(out)
		return r, nil
	})
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	from := map[string]any{"machine": "pc", "folder": there, "changes": true}

	// Offline: refused before the card, saying how to start it.
	offline = true
	if text, isErr := m.tool(2, "bring_back", from); !isErr ||
		text != "Nothing was brought back from pc: pc is offline. Start it with start_machine, then try again." {
		t.Fatal(text)
	}
	mu.Lock()
	offline = false
	mu.Unlock()

	// A branch it does not have: refused before the card.
	if text, isErr := m.tool(3, "bring_back", map[string]any{"machine": "pc", "folder": there, "branch": "nope"}); !isErr ||
		text != "Nothing was brought back: "+there+" on pc has no branch nope." {
		t.Fatal(text)
	}

	answered := make(chan string, 1)
	go func() { text, _ := m.tool(4, "bring_back", from); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if f := pending[0].Mode.Form.Value; *f.Properties[0].Title != "Bring fix-login, with its uncommitted changes, back from "+there+" on pc into "+src+"?" {
		t.Fatal(*f.Properties[0].Title)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "facts,facts" {
		t.Fatalf("before the yes: %v", steps)
	}
	steps = nil
	mu.Unlock()
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"go": "yes"}})
	if text := <-answered; text != "Brought fix-login back from "+there+" on pc: it moved forward in "+src+". The uncommitted changes from pc are in "+src+"." {
		t.Fatal(text)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "pack,read,read" {
		t.Fatalf("%v", steps)
	}
	mu.Unlock()
	if got := sendGit(t, src, nil, "rev-parse", "HEAD"); got != head {
		t.Fatalf("here is at %s, not %s", got, head)
	}
	if b, _ := os.ReadFile(filepath.Join(src, "notes.txt")); string(b) != "not committed\n" {
		t.Fatalf("notes.txt here: %q", b)
	}
	for _, folder := range []string{d.incomingFolder(), d.outgoingFolder()} {
		if left, _ := os.ReadDir(folder); len(left) != 0 {
			t.Fatalf("left in %s: %v", folder, left)
		}
	}

	// Now uncommitted changes here: the changes are refused before the card.
	if text, isErr := m.tool(5, "bring_back", from); !isErr ||
		text != "Nothing was brought back: "+src+" has uncommitted changes. Commit or remove them to take the machine's." {
		t.Fatal(text)
	}
}
