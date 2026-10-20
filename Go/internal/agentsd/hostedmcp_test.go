package agentsd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"slices"
	"strconv"
	"syscall"
	"testing"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// A hosted server is one process shared by every session, served on the app's endpoint
// with each session's token, started again when it stops, and let go when nobody uses it
// (#488, #1138).
func TestAHostedServerIsSharedRestartedAndLetGo(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("AGENTS_FAKE_MCP", "1")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	port, err := d.startAppTools()
	if err != nil {
		t.Fatal(err)
	}
	server := sdk.McpServerStdio{Name: "fake", Command: self, Args: []string{}, Env: []sdk.EnvVariable{}}
	pathA, err := d.hostedUse(server, nil, t.TempDir(), "token-a")
	if err != nil {
		t.Fatal(err)
	}
	pathB, _ := d.hostedUse(server, nil, t.TempDir(), "token-b")
	if pathA != pathB {
		t.Fatalf("two paths for one server: %s, %s", pathA, pathB)
	}
	url := "http://127.0.0.1:" + strconv.Itoa(port) + pathA
	post := func(token, session, body string) (*http.Response, map[string]json.RawMessage) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, url, bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+token)
		if session != "" {
			req.Header.Set("Mcp-Session-Id", session)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]json.RawMessage
		json.NewDecoder(resp.Body).Decode(&out)
		return resp, out
	}
	initialize := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`
	resp, out := post("token-a", "", initialize)
	session := resp.Header.Get("Mcp-Session-Id")
	var init struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	json.Unmarshal(out["result"], &init)
	if session == "" || init.ProtocolVersion != "2025-03-26" {
		t.Fatalf("initialize: session %q, %s", session, out["result"])
	}
	tools := func(token, session string) int {
		t.Helper()
		_, out := post(token, session, `{"jsonrpc":"2.0","id":7,"method":"tools/list"}`)
		var r struct {
			Tools []any `json:"tools"`
		}
		json.Unmarshal(out["result"], &r)
		if string(out["id"]) != "7" {
			t.Fatalf("the client's id is not given back: %s", out["id"])
		}
		return len(r.Tools)
	}
	if n := tools("token-a", session); n != 2 {
		t.Fatalf("tools/list: %d tools", n)
	}
	pid := d.hostedPid(pathA)
	// The host's copy is told it is the host's: only it has a server's person-only tools.
	d.hostedMu.Lock()
	env := d.hostedByPath(pathA).cmd.Env
	d.hostedMu.Unlock()
	if !slices.Contains(env, githubmcp.HostedEnv+"=1") {
		t.Fatalf("the hosted copy has no %s", githubmcp.HostedEnv)
	}
	respB, _ := post("token-b", "", initialize)
	if n := tools("token-b", respB.Header.Get("Mcp-Session-Id")); n != 2 || d.hostedPid(pathA) != pid {
		t.Fatalf("the second session: %d tools, pid %d then %d", n, pid, d.hostedPid(pathA))
	}
	if resp, _ := post("stranger", "", initialize); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a token that does not use the route: %d", resp.StatusCode)
	}
	if resp, _ := post("token-a", "not-a-session", initialize); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a session it does not know: %d", resp.StatusCode)
	}
	var snap wire.HostedMCPSnapshot
	json.Unmarshal(c.call(t, 1, "mcp/hosted", nil), &snap)
	if len(snap.Servers) != 1 || snap.Servers[0].State != wire.HostedMCPStateRunning || snap.Servers[0].Users != 2 {
		t.Fatalf("mcp/hosted: %+v", snap.Servers)
	}

	// It stops while in use: restarting, then running again, as a new process.
	syscall.Kill(pid, syscall.SIGKILL)
	waitFor(t, "restarting", func() bool { return d.hostedState(pathA) == wire.HostedMCPStateRestarting })
	waitFor(t, "running again", func() bool { return d.hostedState(pathA) == wire.HostedMCPStateRunning })
	if p := d.hostedPid(pathA); p == pid || p == 0 {
		t.Fatalf("not started again: pid %d", p)
	}
	if s := d.hostedStatus(nil, "fake"); s == nil || s.Restarts != 1 || s.LastError == nil {
		t.Fatalf("status after a restart: %+v", s)
	}
	if n := tools("token-a", session); n != 2 {
		t.Fatalf("the session after a restart: %d tools", n)
	}

	// Nobody uses it: let go.
	pid = d.hostedPid(pathA)
	d.hostedRelease("token-a")
	d.hostedRelease("token-b")
	if d.hostedState(pathA) != wire.HostedMCPStateIdle || d.hostedPid(pathA) != 0 {
		t.Fatalf("not idle once released: %s", d.hostedState(pathA))
	}
	waitFor(t, "ended", func() bool { return syscall.Kill(pid, 0) != nil })
	if resp, _ := post("token-a", "", initialize); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a released token: %d", resp.StatusCode)
	}
}

// A session is handed a hosted entry as an http server on the endpoint, its token as the
// bearer, and one the host has no room for as it is.
func TestASessionIsHandedAHostedServersRoute(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	// An entry that says it is the host's copy is not, in a session.
	hostedEnv := []sdk.EnvVariable{{Name: githubmcp.HostedEnv, Value: "1"}, {Name: "KEEP", Value: "1"}}
	stdio := sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "shared", Command: "/bin/cat", Args: []string{}, Env: hostedEnv}}
	entries := []sessionEntry{
		{mcpEntry: mcpEntry{name: "shared", server: stdio, hosted: true}, cwd: t.TempDir()},
		{mcpEntry: mcpEntry{name: "own", server: sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: "own", Command: "/bin/cat", Env: hostedEnv}}}},
	}
	notHosts := func(s sdk.McpServer) bool {
		return s.Stdio != nil && len(s.Stdio.Env) == 1 && s.Stdio.Env[0].Name == "KEEP"
	}
	got := d.hostedSwapped(entries, 4242, "tok", "claude")
	if got[0].Http == nil || got[0].Http.Name != "shared" || got[0].Http.Headers[0].Value != "Bearer tok" ||
		got[0].Http.Url[:len("http://127.0.0.1:4242/mcp/hosted/")] != "http://127.0.0.1:4242/mcp/hosted/" {
		t.Fatalf("hosted: %+v", got[0])
	}
	if !notHosts(got[1]) {
		t.Fatalf("not hosted: %+v", got[1])
	}
	// "shared" and seven others: the host's limit.
	for i := range hostedLimit - 1 {
		other := sdk.McpServerStdio{Name: "n" + strconv.Itoa(i), Command: "/bin/cat"}
		if _, err := d.hostedUse(other, nil, "", "user"); err != nil {
			t.Fatal(err)
		}
	}
	// "shared" is already in use, so a second session still has it.
	if got := d.hostedSwapped(entries[:1], 4242, "tok2", "claude"); got[0].Http == nil {
		t.Fatalf("a server in use was refused: %+v", got[0])
	}
	d.hostedRelease("tok")
	d.hostedRelease("tok2")
	if _, err := d.hostedUse(sdk.McpServerStdio{Name: "last", Command: "/bin/cat"}, nil, "", "user"); err != nil {
		t.Fatal(err)
	}
	if got := d.hostedSwapped(entries[:1], 4242, "tok3", "claude"); !notHosts(got[0]) {
		t.Fatalf("over the limit, not handed as it is without %s: %+v", githubmcp.HostedEnv, got[0])
	}
	if len(stdio.Stdio.Env) != 2 {
		t.Fatal("the entry itself was changed")
	}
}

func (d *Daemon) hostedByPath(path string) *hostedServer {
	return d.hostedByRoute[path[len(hostedPathPrefix):]]
}

func (d *Daemon) hostedPid(path string) int {
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if h := d.hostedByPath(path); h != nil && h.cmd != nil && h.cmd.Process != nil {
		return h.cmd.Process.Pid
	}
	return 0
}

func (d *Daemon) hostedState(path string) wire.HostedMCPState {
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if h := d.hostedByPath(path); h != nil {
		return h.state
	}
	return ""
}
