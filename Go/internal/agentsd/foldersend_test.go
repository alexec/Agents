package agentsd

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Send to ‹machine›… (#4613): folders/send answers at once and this host sends on its own,
// through machines/sendFolder, saying how it goes with send/changed; a window that connects
// mid-send finds it with folders/sends. A folder there with work of its own, or an offline
// machine, refuses at once, and nothing goes.

// nextSend is the next send/changed c hears, or nil after wait.
func nextSend(c *conn, wait time.Duration) *wire.SendNotification {
	deadline := time.After(wait)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifySendChanged.Name {
				continue
			}
			var n wire.SendNotification
			json.Unmarshal(m.Params, &n)
			return &n
		case <-deadline:
			return nil
		}
	}
}

func TestFoldersSendSendsOnItsOwn(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	// More than one part of machines/sendFolder, so the send says how far it is.
	big := make([]byte, sendThereParts+sendThereParts/2)
	rand.Read(big)
	os.WriteFile(filepath.Join(src, "big.bin"), big, 0o644)
	sendGit(t, src, nil, "add", "-A")
	sendGit(t, src, nil, "commit", "-q", "-m", "big")
	os.WriteFile(filepath.Join(src, "notes.txt"), []byte("not committed\n"), 0o644)
	head := sendGit(t, src, nil, "rev-parse", "HEAD")
	// The other machine is this one, at another path: the steps go to its own methods.
	there := filepath.Join(canonical(t.TempDir()), "app")

	var mu sync.Mutex
	var steps, who []string
	offline := false
	receiving := make(chan struct{})
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		// Only the send's steps: the host's other calls to the control plane go nowhere.
		call, ok := params.(wire.MachineWorkspaceCall)
		if !ok || call.Method != sendFolderMethod {
			return json.RawMessage(`{}`), nil
		}
		b, _ := json.Marshal(call.Params)
		mu.Lock()
		who = append(who, call.Agent)
		if offline {
			mu.Unlock()
			return nil, &controllink.AskError{Code: wire.FailureHostOffline, Message: "pc is offline."}
		}
		mu.Unlock()
		var s wire.MachineFolderSend
		json.Unmarshal(b, &s)
		var out wire.MachineFolderSent
		switch {
		case s.State != nil:
			mu.Lock()
			steps = append(steps, "state")
			mu.Unlock()
			st, err := d.receiveState(*s.State)
			if err != nil {
				return nil, err
			}
			out.State = &st
		case s.Upload != nil:
			mu.Lock()
			steps = append(steps, "upload")
			mu.Unlock()
			if err := d.receiveUpload(*s.Upload); err != nil {
				return nil, err
			}
		case s.Receive != nil:
			// Held until the test has seen the send under way.
			<-receiving
			mu.Lock()
			steps = append(steps, "receive")
			mu.Unlock()
			f, err := d.receive(*s.Receive)
			if err != nil {
				return nil, &controllink.AskError{Code: wire.FailureFolderInTheWay, Message: err.Error()}
			}
			out.Folder = &f
		}
		r, _ := json.Marshal(out)
		return r, nil
	})
	send := map[string]any{"folder": store.PathURL(src), "machine": "pc-id", "machineName": "pc", "destination": there,
		"branches": []string{"fix-login"}, "checkout": "fix-login", "includeChanges": true}

	// Offline: refused at once, and nothing is under way.
	offline = true
	if e := c.callError(t, 1, "folders/send", send); e.Message != "Nothing was sent to pc: pc is offline." {
		t.Fatal(e.Message)
	}
	mu.Lock()
	offline = false
	mu.Unlock()

	// It answers before the send is done.
	var s wire.SendSummary
	json.Unmarshal(c.call(t, 2, "folders/send", send), &s)
	if s.Machine != "pc-id" || s.MachineName != "pc" || s.Destination != there || s.Folder != store.PathURL(src) {
		t.Fatalf("%+v", s)
	}
	// The parts go, and each says how far the send is.
	var last *wire.SendNotification
	for last == nil || last.Sent < last.Total || last.Total == 0 {
		if last = nextSend(c, 10*time.Second); last == nil {
			t.Fatal("no send/changed")
		}
		if last.Finished {
			t.Fatalf("finished before the receive: %+v", last)
		}
	}
	if last.Send.ID != s.ID || last.Total < int64(len(big)) {
		t.Fatalf("%+v", last)
	}
	// A window that connects now finds it, and a second send to the same folder is refused.
	var under []wire.SendNotification
	json.Unmarshal(c.call(t, 3, "folders/sends", nil), &under)
	if len(under) != 1 || under[0].Send.ID != s.ID || under[0].Sent != last.Sent {
		t.Fatalf("%+v", under)
	}
	if e := c.callError(t, 4, "folders/send", send); e.Message != there+" on pc is already being sent." {
		t.Fatal(e.Message)
	}
	close(receiving)
	for last == nil || !last.Finished {
		if last = nextSend(c, 10*time.Second); last == nil {
			t.Fatal("no finished send/changed")
		}
	}
	if last.Problem != nil || last.Received == nil || last.Received.Folder.Folder != store.FolderURL(there) {
		t.Fatalf("%+v", last)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "state,upload,upload,upload,receive" {
		t.Fatalf("steps %v", steps)
	}
	for _, w := range who {
		if w != "You" {
			t.Fatalf("asked as %q", w)
		}
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
	json.Unmarshal(c.call(t, 5, "folders/sends", nil), &under)
	if len(under) != 0 {
		t.Fatalf("still under way: %+v", under)
	}

	// Work of its own there: refused at once, and nothing goes.
	os.WriteFile(filepath.Join(there, "mine.txt"), []byte("mine\n"), 0o644)
	if e := c.callError(t, 6, "folders/send", send); e.Message != "Nothing was sent to pc: "+there+" has changes of its own there." {
		t.Fatal(e.Message)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "state" {
		t.Fatalf("steps %v", steps)
	}
	mu.Unlock()
}
