package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// conn is a client's end of a connection, in memory.
type conn struct {
	in  chan string
	out chan string
}

func newConn() *conn { return &conn{in: make(chan string, 64), out: make(chan string, 64)} }

// Write gives up on a line nobody reads within 5 s: a test that has its answer stops
// reading, and a watch's notification blocked on it held Shutdown for ever.
func (c *conn) Write(line string) error {
	select {
	case c.out <- line:
	case <-time.After(5 * time.Second):
	}
	return nil
}
func (c *conn) In() <-chan string { return c.in }
func (c *conn) Close()            {}
func (c *conn) Device() string    { return "" }

func (c *conn) call(t testing.TB, id int, method string, params any) json.RawMessage {
	t.Helper()
	p, _ := json.Marshal(params)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	c.in <- string(b)
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-c.out:
			var m message
			json.Unmarshal([]byte(line), &m)
			if string(m.ID) != strings.TrimSpace(string(mustJSON(id))) {
				continue // a notification
			}
			if m.Error != nil {
				t.Fatalf("%s: %v", method, m.Error)
			}
			return m.Result
		case <-deadline:
			t.Fatalf("%s: no answer", method)
		}
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func start(t testing.TB, root string) (*Daemon, *conn) {
	t.Helper()
	return startWith(t, context.Background(), root)
}

// startWith is start on a context of the test's, as main's that a signal ends.
func startWith(t testing.TB, ctx context.Context, root string) (*Daemon, *conn) {
	t.Helper()
	d, err := New(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	// Last of these cleanups, before the root goes: what a test sets off (a turn's
	// ending, an assessment's score) writes into the root after the test has its answer.
	// A test that shuts the daemon down itself shuts it down again here, which does nothing.
	t.Cleanup(d.Shutdown)
	c := newConn()
	go d.Accept(c)
	t.Cleanup(func() { close(c.in) })
	t.Cleanup(d.stopFolderWatches)
	// A stopped runtime's turn still records how it ended: wait for that before the
	// root's TempDir goes, or the removal races a write into it.
	t.Cleanup(func() {
		for deadline := time.Now().Add(2 * time.Second); d.anyLive() && time.Now().Before(deadline); {
			time.Sleep(10 * time.Millisecond)
		}
	})
	return d, c
}

// anyLive is whether an agent's run loop is still running or in a turn.
func (d *Daemon) anyLive() bool {
	d.mu.Lock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	d.mu.Unlock()
	for _, l := range ls {
		l.mu.Lock()
		busy := l.running || l.inTurn
		l.mu.Unlock()
		if busy {
			return true
		}
	}
	return false
}

func TestPingAndAnUnknownMethod(t *testing.T) {
	_, c := start(t, t.TempDir())
	if r := c.call(t, 1, "daemon/ping", nil); string(r) != `{"ok":true}` {
		t.Fatalf("ping %s", r)
	}
	c.in <- `{"jsonrpc":"2.0","id":2,"method":"nothing/here"}`
	if line := <-c.out; !strings.Contains(line, "-32601") {
		t.Fatalf("%s", line)
	}
}

func TestAPanickingHandlerAnswersAnError(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.handlers["boom"] = func(context.Context, *Client, json.RawMessage) (any, error) {
		var m map[string]int
		m["x"] = 1
		return nil, nil
	}
	c.in <- `{"jsonrpc":"2.0","id":1,"method":"boom"}`
	if line := <-c.out; !strings.Contains(line, "-32603") {
		t.Fatalf("%s", line)
	}
	if r := c.call(t, 2, "daemon/ping", nil); string(r) != `{"ok":true}` {
		t.Fatal("the host stopped serving")
	}
}

// A root the Swift host wrote: its agent is listed with its folder, and its transcript
// pages as Swift pages it.
func TestASwiftRootIsServed(t *testing.T) {
	root := t.TempDir()
	fix := filepath.Join("..", "..", "..", "Packages", "AgentsKit", "Tests", "AgentsKitTests", "Fixtures", "legacy-agent")
	b, _ := os.ReadFile(filepath.Join(fix, "agent.json"))
	var head struct{ ID string }
	json.Unmarshal(b, &head)
	// The fixture's folder is a real one on the Mac it was made on: here, a folder of the
	// test's own, so the host never reads (or runs the workflows of) a real folder.
	b = []byte(strings.ReplaceAll(string(b), `"file:///Users/alexcollins/Agents/"`, `"`+string(store.FolderURL(t.TempDir()))+`/"`))
	if strings.Contains(string(b), "/Users/alexcollins") {
		t.Fatal("the fixture still names a real folder")
	}
	dir := filepath.Join(root, "agents", strings.ToUpper(head.ID))
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "agent.json"), b, 0o644)
	tb, _ := os.ReadFile(filepath.Join(fix, "transcript.jsonl"))
	os.WriteFile(filepath.Join(dir, "transcript.jsonl"), tb, 0o644)
	// The fixture's agent was left running: its record also says it stopped with the
	// daemon, a note and its ending (DaemonCore+Recovery).
	lines := strings.Count(string(tb), "\n") + 2

	d, c := start(t, root)
	// Stopped before the root goes: recovery may still be writing the agent's record.
	defer d.Shutdown()
	var agents []wire.Agent
	json.Unmarshal(c.call(t, 1, "agents/list", map[string]any{"includeArchived": true}), &agents)
	if len(agents) != 1 || string(agents[0].ID) != strings.ToUpper(head.ID) {
		t.Fatalf("agents %v", agents)
	}
	var folders []wire.FolderSummary
	json.Unmarshal(c.call(t, 2, "folders/list", map[string]any{"includeArchived": true}), &folders)
	if len(folders) != 1 || folders[0].Name == "" {
		t.Fatalf("folders %+v", folders)
	}
	var page wire.TranscriptPage
	json.Unmarshal(c.call(t, 3, "agents/transcript", map[string]any{"agentID": head.ID, "limit": 10}), &page)
	if page.Total != int64(lines) || page.FirstIndex != int64(lines-10) || len(page.Entries) != 10 {
		t.Fatalf("page total %d first %d entries %d (lines %d)", page.Total, page.FirstIndex, len(page.Entries), lines)
	}
	json.Unmarshal(c.call(t, 4, "agents/transcript", map[string]any{"agentID": head.ID, "limit": 10, "before": 5}), &page)
	if page.FirstIndex != 0 || len(page.Entries) != 5 {
		t.Fatalf("before 5: first %d entries %d", page.FirstIndex, len(page.Entries))
	}
}

func TestAddAFolder(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(t.TempDir(), "hello")
	os.Mkdir(work, 0o755)
	d, c := start(t, root)
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + work}), &s)
	if s.Name != "hello" || !s.Exists {
		t.Fatalf("%+v", s)
	}
	if ps := d.Store.Folders(); len(ps) != 1 || store.FolderPath(ps[0].Folder) != mustResolve(work) {
		t.Fatalf("records %+v", ps)
	}
	c.in <- `{"jsonrpc":"2.0","id":2,"method":"folders/add","params":{"folder":"file:///no/such/folder"}}`
	for line := range c.out {
		if strings.Contains(line, `"id":2`) {
			if !strings.Contains(line, "-32004") {
				t.Fatalf("%s", line)
			}
			break
		}
	}
}

func mustResolve(p string) string { r, _ := store.Resolve(p); return r }
