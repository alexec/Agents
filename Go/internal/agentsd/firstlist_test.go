package agentsd

import (
	"encoding/json"
	"strings"
	"testing"
)

// The calls before a connection's first list (#4891) are counted in the order they come,
// once, and only for a client that draws a list.
func TestFirstListCountsTheCallsBeforeIt(t *testing.T) {
	d := &Daemon{handlers: map[string]Handler{}}
	c := &Client{Role: RoleWindow, conn: newConn(), d: d}
	for _, m := range []string{"daemon/hello", "presence/set"} {
		if line := d.noteFirstList(c, m, nil); line != "" {
			t.Fatalf("%s logged %q before the list", m, line)
		}
	}
	// An archived page is not the first list.
	if line := d.noteFirstList(c, "agents/list", json.RawMessage(`{"includeArchived":true}`)); line != "" {
		t.Fatalf("an archived page logged %q", line)
	}
	line := d.noteFirstList(c, "client/catchUp", json.RawMessage(`{}`))
	if want := "first list: mac after 3 calls: daemon/hello, presence/set, agents/list"; line != want {
		t.Fatalf("got %q, want %q", line, want)
	}
	if again := d.noteFirstList(c, "agents/list", nil); again != "" {
		t.Fatalf("a second list logged %q", again)
	}
}

func TestFirstListKeepsABoundedListOfNames(t *testing.T) {
	d := &Daemon{handlers: map[string]Handler{}}
	c := &Client{Role: RoleWindow, conn: newConn(), d: d}
	for range firstListNames + 5 {
		d.noteFirstList(c, "daemon/ping", nil)
	}
	line := d.noteFirstList(c, "agents/list", nil)
	if !strings.Contains(line, "after 37 calls") || !strings.HasSuffix(line, ", …") ||
		strings.Count(line, "daemon/ping") != firstListNames {
		t.Fatalf("got %q", line)
	}
}

func TestFirstListSaysNothingForAnAgent(t *testing.T) {
	d := &Daemon{handlers: map[string]Handler{}}
	c := &Client{Role: RoleAgent, conn: newConn(), d: d}
	if line := d.noteFirstList(c, "agents/list", nil); line != "" {
		t.Fatalf("an agent's list logged %q", line)
	}
}
