package agentsd

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// A suspended person on their machine (#1002, slice 2b, T030, FR-018).

// suspendedNote is user/suspended for kim, or its end.
func suspendedNote(off bool) json.RawMessage {
	note := map[string]any{"user": "kim", "provider": "Acme Okta", "at": now()}
	if off {
		note["off"] = true
	}
	b, _ := json.Marshal(note)
	return b
}

// suspendedRefusal checks a personSuspended error.
func suspendedRefusal(t *testing.T, e *Error) {
	t.Helper()
	if e == nil || e.Code != wire.FailurePersonSuspended || e.Message != suspendedWords {
		t.Fatalf("not refused for the suspension: %+v", e)
	}
}

// The machine says it can hear user/suspended (host.suspend/1) in host/hello.
func TestAHostSaysItTakesASuspension(t *testing.T) {
	d, _ := start(t, t.TempDir())
	if !slices.Contains(d.Capabilities(), wire.CapHostSuspend1) {
		t.Fatal(d.Capabilities())
	}
}

// FR-018: two running turns stop within 5 s; a queued prompt waits; new work, a prompt and
// a workflow's run are refused; every agent and file stays. Off starts nothing by itself.
func TestASuspendedPersonsWorkStops(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	one, two := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(one, "notes.txt"), []byte("kept"), 0o644)
	a := startAgent(t, c, 1, one, "wait for me")
	b := startAgent(t, c, 2, two, "wait for me")
	waitFor(t, "both running", func() bool {
		return d.Store.Agent(a).State == wire.AgentStateRunning && d.Store.Agent(b).State == wire.AgentStateRunning
	})
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": a, "text": "later", "from": "person"})
	at := time.Now()
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(false))
	waitFor(t, "both stopped", func() bool { return !inFlight(d.Store.Agent(a).State) && !inFlight(d.Store.Agent(b).State) })
	if s := time.Since(at); s > 5*time.Second {
		t.Fatalf("stopped after %s", s)
	}
	suspendedRefusal(t, c.callError(t, 4, "agents/start", startParams(one, "claude", nil)))
	suspendedRefusal(t, c.callError(t, 5, "agents/prompt", map[string]any{"agentID": b, "text": "again"}))
	_, err := d.startFor(helperRequest("claude", one, "run", "", nil, nil, nil), startedBy{owner: wire.SessionLabelOwnerAgent})
	suspendedRefusal(t, asError(err))
	if q := d.Store.Agent(a).QueuedPrompts; len(q) != 1 || q[0].Text != "later" {
		t.Fatalf("the queued prompt went: %+v", q)
	}
	// Nothing is deleted.
	if d.Store.Agent(a) == nil || d.Store.Agent(b) == nil {
		t.Fatal("an agent went")
	}
	if b, err := os.ReadFile(filepath.Join(one, "notes.txt")); err != nil || string(b) != "kept" {
		t.Fatal("a file went", err)
	}
	// A restart keeps it.
	if _, err := os.Stat(filepath.Join(root, userSuspendedFile)); err != nil {
		t.Fatal(err)
	}
	d2 := &Daemon{Store: d.Store}
	if d2.suspension() == nil || d2.suspension().Provider != "Acme Okta" {
		t.Fatal("a restart forgot the suspension")
	}
	// Off: nothing starts by itself; the queued prompt waits for its person.
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(true))
	time.Sleep(300 * time.Millisecond)
	if q := d.Store.Agent(a).QueuedPrompts; len(q) != 1 || inFlight(d.Store.Agent(a).State) || inFlight(d.Store.Agent(b).State) {
		t.Fatal("something started by itself")
	}
	if _, err := os.Stat(filepath.Join(root, userSuspendedFile)); !os.IsNotExist(err) {
		t.Fatal("the state is still kept", err)
	}
	c.call(t, 6, "agents/start", startParams(one, "claude", nil))
}

// A suspended person's workflows are paused: a trigger is let go, by hand is refused, and none
// runs by itself when the suspension ends.
func TestASuspendedPersonsWorkflowsPause(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non: lease.granted\n---\nReview what changed.\n"), 0o644)
	approveAll(t, c, folder)
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(false))
	e := d.raise(wire.EventDraft{Name: "lease.granted", At: now(), Scope: macScope(), Sentence: "x was given build.",
		Details: map[string]string{"resource": "build"}})
	suspendedRefusal(t, c.callError(t, 2, "workflows/run", map[string]any{"folder": folder, "workflowID": "review"}))
	time.Sleep(300 * time.Millisecond)
	if got := d.event(e.Position); got != nil && len(got.Consequences) > 0 && got.Consequences[0].Fired != nil {
		t.Fatal("a suspended person's workflow fired")
	}
	if n := len(d.Store.Agents()); n != 0 {
		t.Fatalf("%d agents started", n)
	}
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(true))
	time.Sleep(300 * time.Millisecond)
	if n := len(d.Store.Agents()); n != 0 {
		t.Fatalf("%d agents started by themselves", n)
	}
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folder, "workflowID": "review"}), &s)
	if s.LastOutcome == nil || s.LastOutcome.Ran == nil {
		t.Fatalf("%+v", s)
	}
}

// The window's direct path (#1118) is cut off and refused while the person is suspended.
func TestASuspendedPersonsWindowIsRefusedDirectly(t *testing.T) {
	d, _ := start(t, t.TempDir())
	w, listed := newWindow(t)
	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listed}})
	path := serveLocal(t, d, RoleWindow)
	c, r, reply := prove(t, path, w)
	if reply.OK == nil {
		t.Fatalf("%+v", reply)
	}
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(false))
	c.SetDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, err := r.ReadString('\n'); err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				t.Fatal("the window was not cut off")
			}
			break // closed
		}
	}
	if _, _, reply := prove(t, path, w); reply.Refused != controllink.Suspended {
		t.Fatalf("%+v", reply)
	}
	d.Told(wire.NotifyUserSuspended.Name, suspendedNote(true))
	if _, _, reply := prove(t, path, w); reply.OK == nil {
		t.Fatalf("%+v", reply)
	}
}
