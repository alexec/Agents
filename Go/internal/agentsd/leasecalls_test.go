package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports LeaseCallTests: an agent's lease, refused or waited for, handed on at a release to
// the call still waiting, and the place kept when the call has waited as long as it may.

func (m *mcpClient) tool(id int, name string, args map[string]any) (string, bool) {
	m.t.Helper()
	_, r := m.post("tools/call", map[string]any{"name": "mcp__agents__" + name, "arguments": args}, id)
	var res struct {
		Content []struct{ Text string } `json:"content"`
		IsError bool                    `json:"isError"`
	}
	json.Unmarshal(r["result"], &res)
	if len(res.Content) == 0 {
		m.t.Fatalf("%s: %s", name, r["error"])
	}
	return res.Content[0].Text, res.IsError
}

func TestAgentsTakeTurnsWithAResource(t *testing.T) {
	was := leaseWaitLimit
	leaseWaitLimit = 2 * time.Second
	defer func() { leaseWaitLimit = was }()
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	titled := func(title string) func(*wire.Agent) {
		return func(a *wire.Agent) { a.Title = &title }
	}
	first := appClient(t, d, seeded(t, d, dir, titled("Build it")).ID)
	second := appClient(t, d, seeded(t, d, dir, titled("Test it")).ID)
	first.post("initialize", map[string]any{}, 1)
	second.post("initialize", map[string]any{}, 1)

	if text, _ := first.tool(2, "lease_resource", map[string]any{"name": "Build", "minutes": 10}); !strings.HasPrefix(text, "You hold Build until ") ||
		!strings.Contains(text, "(10 minutes)") {
		t.Fatal(text)
	}
	if text, _ := first.tool(3, "lease_resource", map[string]any{"name": "build", "minutes": "20"}); !strings.HasPrefix(text, "You still hold Build, now until ") {
		t.Fatal(text)
	}
	if text, _ := second.tool(2, "lease_resource", map[string]any{"name": "build", "wait": false}); !strings.HasPrefix(text, "Build is held by “Build it” until ") ||
		!strings.HasSuffix(text, ". You are not in line.") {
		t.Fatal(text)
	}
	// Waiting: the release hands it to the call still open.
	answered := make(chan string, 1)
	go func() { text, _ := second.tool(3, "lease_resource", map[string]any{"name": "build"}); answered <- text }()
	waitFor(t, "the second in line", func() bool {
		d.leaseMu.Lock()
		defer d.leaseMu.Unlock()
		e := d.book.Entries["build"]
		return e != nil && len(e.Line) == 1 && len(d.openLeaseCalls) == 1
	})
	if text, _ := first.tool(4, "release_resource", map[string]any{"name": "Build"}); text != "Released Build. It has gone to “Test it”." {
		t.Fatal(text)
	}
	if text := <-answered; !strings.HasPrefix(text, "Build is yours now, until ") || !strings.Contains(text, "You waited ") {
		t.Fatal(text)
	}
	text, _ := second.tool(4, "list_resources", nil)
	if !strings.HasPrefix(text, "Yours:\n- Holding Build (build) until ") || !strings.Contains(text, "On this Mac:\n- screen — Screen, mouse and keyboard: free.") ||
		!strings.Contains(text, "- Build (named by an agent): held by you until ") {
		t.Fatal(text)
	}
	// A call that waits as long as it may keeps its place.
	go func() { text, _ := first.tool(5, "lease_resource", map[string]any{"name": "build"}); answered <- text }()
	if text := <-answered; !strings.HasSuffix(text, "You are 1st in line and keep your place. Call lease_resource again to go on waiting, or end your turn — you will be started again when it is yours.") {
		t.Fatal(text)
	}
	if text, _ := first.tool(6, "release_resource", map[string]any{"name": "build"}); text != "You left the line for Build." {
		t.Fatal(text)
	}
	if text, isErr := first.tool(7, "release_resource", map[string]any{}); !isErr || text != "Nothing was released: say which resource, in `name`." {
		t.Fatal(text)
	}
}

func TestOrdinals(t *testing.T) {
	for n, want := range map[int]string{1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 11: "11th", 12: "12th", 13: "13th", 21: "21st", 112: "112th"} {
		if ordinal(n) != want {
			t.Errorf("%d: %s", n, ordinal(n))
		}
	}
}
