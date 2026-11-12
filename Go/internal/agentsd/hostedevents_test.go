package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	sdk "github.com/coder/acp-go-sdk"
)

// A hosted server's event subscriptions come through its one copy: one process for the
// sessions and the events, and let go when the subscriptions end (#4516).
func TestAHostedServersEventsComeThroughItsOneCopy(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	t.Setenv("FAKE_MCP_LEVELS", "1")
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	entry, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"gh": map[string]any{"command": self, "hosted": true}}})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), entry, 0o644)
	s, problem := d.eventServerNamed("gh", t.TempDir(), nil)
	if problem != "" || !s.hosted {
		t.Fatalf("the hosted entry's event server: %q, %+v", problem, s)
	}
	// A pool of the test's own: the daemon's ends a connection no subscription names.
	conns := newMCPEventConns(nil)
	conns.hosted = d.hostedEventConnect
	var events []mcpEventDef
	viaHost := false
	if err := conns.with(s, func(c *mcpEventConn) error {
		_, viaHost = c.c.(*hostedEventConn)
		var err error
		events, err = c.listEvents(conns.timeout)
		return err
	}); err != nil || len(events) != 1 || events[0].Name != "pr.opened" {
		t.Fatalf("events through the copy: %+v, %v", events, err)
	}
	if !viaHost {
		t.Fatal("the events run a copy of their own")
	}
	d.hostedMu.Lock()
	copies := len(d.hostedByKey)
	var h *hostedServer
	for _, one := range d.hostedByKey {
		h = one
	}
	pid := 0
	if h != nil && h.cmd != nil {
		pid = h.cmd.Process.Pid
	}
	d.hostedMu.Unlock()
	if copies != 1 || pid == 0 {
		t.Fatalf("%d hosted copies, pid %d", copies, pid)
	}

	// A session on the same entry is handed the same copy: still one process.
	got := d.hostedSwapped(d.sessionEntries(t.TempDir(), ""), 4242, "tok", "claude")
	if len(got) != 1 || got[0].Http == nil || d.hostedPid(got[0].Http.Url[len("http://127.0.0.1:4242"):]) != pid {
		t.Fatalf("the session is not handed the events' copy: %+v", got)
	}

	// The session and the events end: the copy is let go.
	d.hostedRelease("tok")
	conns.endAll()
	waitFor(t, "the copy let go", func() bool { return syscall.Kill(pid, 0) != nil })
}

// A start ends a process still left from the start before, so a hosted server never has two
// copies (#4516).
func TestAHostedStartEndsTheOldProcess(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	path, err := d.hostedUse(sdk.McpServerStdio{Name: "fake", Command: self, Args: []string{}, Env: []sdk.EnvVariable{}}, nil, t.TempDir(), "user")
	if err != nil {
		t.Fatal(err)
	}
	d.hostedMu.Lock()
	h := d.hostedByPath(path)
	d.hostedMu.Unlock()
	if _, err := d.hostedReady(h); err != nil {
		t.Fatal(err)
	}
	old := d.hostedPid(path)

	// A start while the old process still runs.
	if _, err := d.hostedStart(h); err != nil {
		t.Fatal(err)
	}
	if p := d.hostedPid(path); p == old || p == 0 {
		t.Fatalf("not started again: pid %d, was %d", p, old)
	}
	waitFor(t, "the old process ended", func() bool { return syscall.Kill(old, 0) != nil })
}

// #5023: a hosted copy's refusal keeps its data, so a GitHub sign-in that ended for a moment
// (the old token ended as the host renewed it) is tried again, as a direct server's is; it was
// read as a refusal for good, and every wait on github ended.
func TestAHostedRefusalKeepsItsReason(t *testing.T) {
	_, err := hostedReplyOf(json.RawMessage(`{"jsonrpc":"2.0","id":3,"error":{"code":-32012,` +
		`"message":"GitHub is not connected, or its sign-in ended","data":{"reason":"not connected"}}}`))
	if err == nil {
		t.Fatal("no error")
	}
	if e := mcpEventsErrorOf(hostedRefusal(err)); e.kind != "needsSignIn" {
		t.Fatalf("a sign-in that ended is %q, not tried again", e.kind)
	}
	// Another -32012 is still a refusal for good.
	_, err = hostedReplyOf(json.RawMessage(`{"error":{"code":-32012,"message":"no","data":{"reason":"no access"}}}`))
	if e := mcpEventsErrorOf(hostedRefusal(err)); e.kind != "forbidden" {
		t.Fatalf("got %q", e.kind)
	}
	// An error with no data has none, and a session still gets the data as JSON.
	_, err = hostedReplyOf(json.RawMessage(`{"error":{"code":-32603,"message":"boom"}}`))
	if err.Data != nil || hostedRefusal(err).data != nil {
		t.Fatalf("data from nowhere: %+v", err)
	}
	b, _ := json.Marshal(&Error{Code: -32012, Message: "m", Data: json.RawMessage(`{"reason":"not connected"}`)})
	if string(b) != `{"code":-32012,"message":"m","data":{"reason":"not connected"}}` {
		t.Fatal(string(b))
	}
}
