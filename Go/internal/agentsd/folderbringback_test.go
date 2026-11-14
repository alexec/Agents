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

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Bring Back from ‹machine›… (#4640): folders/bringBackFrom answers at once and this host
// brings the branches back on its own, through machines/sendFolder, saying how it goes with
// bringBack/changed; a window that connects mid-way finds it with folders/bringingBack. An
// offline machine, or a branch it does not have, refuses at once, and nothing comes.

// nextBringBack is the next bringBack/changed c hears, or nil after wait.
func nextBringBack(c *conn, wait time.Duration) *wire.BringBackNotification {
	deadline := time.After(wait)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if m.Method != wire.NotifyBringBackChanged.Name {
				continue
			}
			var n wire.BringBackNotification
			json.Unmarshal(m.Params, &n)
			return &n
		case <-deadline:
			return nil
		}
	}
}

func TestFoldersBringBackFromBringsOnItsOwn(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	src := repo(t)
	sendGit(t, src, nil, "checkout", "-q", "-b", "fix-login")
	// The other machine is this one, at another path: the steps go to its own methods.
	there := filepath.Join(canonical(t.TempDir()), "app")
	sendGit(t, filepath.Dir(there), nil, "clone", "-q", "-b", "fix-login", src, there)
	sendGit(t, there, nil, "config", "user.email", "t@example.com")
	sendGit(t, there, nil, "config", "user.name", "T")
	// More than one part of folders/sendRead, so the bring-back says how far it is.
	big := make([]byte, sendPartSize+sendPartSize/2)
	rand.Read(big)
	os.WriteFile(filepath.Join(there, "big.bin"), big, 0o644)
	sendGit(t, there, nil, "add", "-A")
	sendGit(t, there, nil, "commit", "-q", "-m", "big")
	os.WriteFile(filepath.Join(there, "notes.txt"), []byte("not committed\n"), 0o644)
	head := sendGit(t, there, nil, "rev-parse", "HEAD")

	var mu sync.Mutex
	var steps, who []string
	offline := false
	held := make(chan struct{})
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		// Only the bring-back's steps: the host's other calls to the control plane go nowhere.
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
		var err error
		step := ""
		switch {
		case s.Facts != nil:
			step = "facts"
			f, e := d.sendFacts(*s.Facts)
			out.Facts, err = &f, e
		case s.Pack != nil:
			step = "pack"
			p, e := d.sendPack(*s.Pack)
			out.Pack, err = &p, e
		case s.Read != nil:
			step = "read"
			r, e := d.sendRead(*s.Read)
			out.Read, err = &r, e
			// The last part is held until the test has seen the bring-back under way.
			if e == nil && r.End && len(r.Data) > 0 && len(r.Data) < sendPartSize && s.Read.Offset > 0 {
				<-held
			}
		}
		mu.Lock()
		steps = append(steps, step)
		mu.Unlock()
		if err != nil {
			code, msg := errMessage(err)
			return nil, &controllink.AskError{Code: code, Message: msg}
		}
		r, _ := json.Marshal(out)
		return r, nil
	})
	from := map[string]any{"folder": store.PathURL(src), "machine": "pc-id", "machineName": "pc", "source": there,
		"branches": []string{"fix-login"}, "includeChanges": true}

	// Offline: refused at once, and nothing is under way.
	mu.Lock()
	offline = true
	mu.Unlock()
	if e := c.callError(t, 1, "folders/bringBackFrom", from); e.Message != "Nothing was brought back from pc: pc is offline." {
		t.Fatal(e.Message)
	}
	mu.Lock()
	offline = false
	mu.Unlock()

	// A branch it does not have: refused at once.
	nope := map[string]any{}
	for k, v := range from {
		nope[k] = v
	}
	nope["branches"] = []string{"nope"}
	if e := c.callError(t, 2, "folders/bringBackFrom", nope); e.Message != "Nothing was brought back from pc: "+there+" on pc has no branch nope." {
		t.Fatal(e.Message)
	}
	mu.Lock()
	steps = nil
	mu.Unlock()

	// It answers before the bring-back is done.
	var s wire.BringBackSummary
	json.Unmarshal(c.call(t, 3, "folders/bringBackFrom", from), &s)
	if s.Machine != "pc-id" || s.MachineName != "pc" || s.Source != there || s.Folder != store.PathURL(src) {
		t.Fatalf("%+v", s)
	}
	// The parts come, and each says how far it is.
	var last *wire.BringBackNotification
	for last == nil || last.Total == 0 || last.Read < int64(sendPartSize) {
		if last = nextBringBack(c, 10*time.Second); last == nil {
			t.Fatal("no bringBack/changed")
		}
		if last.Finished {
			t.Fatalf("finished before the last part: %+v", last)
		}
	}
	if last.BringBack.ID != s.ID || last.Total < int64(len(big)) {
		t.Fatalf("%+v", last)
	}
	// A window that connects now finds it, and a second bring-back into the same folder is
	// refused.
	var under []wire.BringBackNotification
	json.Unmarshal(c.call(t, 4, "folders/bringingBack", nil), &under)
	if len(under) != 1 || under[0].BringBack.ID != s.ID || under[0].Read != last.Read {
		t.Fatalf("%+v", under)
	}
	if e := c.callError(t, 5, "folders/bringBackFrom", from); e.Message != shortPath(src)+" is already bringing back." {
		t.Fatal(e.Message)
	}
	close(held)
	for last == nil || !last.Finished {
		if last = nextBringBack(c, 10*time.Second); last == nil {
			t.Fatal("no finished bringBack/changed")
		}
	}
	if last.Problem != nil || last.Result == nil || strings.Join(last.Result.Moved, ",") != "fix-login" || !last.Result.Applied {
		t.Fatalf("%+v", last)
	}
	mu.Lock()
	if strings.Join(steps, ",") != "facts,pack,read,read,read" {
		t.Fatalf("steps %v", steps)
	}
	for _, w := range who {
		if w != "You" {
			t.Fatalf("asked as %q", w)
		}
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
	json.Unmarshal(c.call(t, 6, "folders/bringingBack", nil), &under)
	if len(under) != 0 {
		t.Fatalf("still under way: %+v", under)
	}

	// Now uncommitted changes here: the bring-back stops, says why, and changes nothing.
	json.Unmarshal(c.call(t, 7, "folders/bringBackFrom", from), &s)
	for last = nil; last == nil || !last.Finished; {
		if last = nextBringBack(c, 10*time.Second); last == nil {
			t.Fatal("no finished bringBack/changed")
		}
	}
	if last.Problem == nil || !strings.HasPrefix(*last.Problem, "Nothing came back into "+filepath.Base(src)+" from pc: ") {
		t.Fatalf("%+v", last)
	}
	if got := sendGit(t, src, nil, "rev-parse", "HEAD"); got != head {
		t.Fatalf("here moved to %s", got)
	}
}
