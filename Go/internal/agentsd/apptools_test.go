package agentsd

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports AppToolsEndpointTests and what AppServiceTests hold of the tools this host does:
// a token per runtime in its header, 404 for one nobody holds, sessions from initialize,
// the Swift host's tools word for word, and a call that changes the agent's own record.

type mcpClient struct {
	t       *testing.T
	url     string
	token   string
	session string
}

func (m *mcpClient) post(method string, params any, id int) (int, map[string]json.RawMessage) {
	m.t.Helper()
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	req, _ := http.NewRequest("POST", m.url, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+m.token)
	req.Header.Set("Content-Type", "application/json")
	if m.session != "" {
		req.Header.Set("Mcp-Session-Id", m.session)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		m.t.Fatal(err)
	}
	defer res.Body.Close()
	if s := res.Header.Get("Mcp-Session-Id"); s != "" {
		m.session = s
	}
	b, _ := io.ReadAll(res.Body)
	var out map[string]json.RawMessage
	json.Unmarshal(b, &out)
	return res.StatusCode, out
}

func appClient(t *testing.T, d *Daemon, id wire.UUID) *mcpClient {
	t.Helper()
	servers := d.mcpServersFor(id)
	if len(servers) != 1 || servers[0].Http == nil || servers[0].Http.Name != "agents" {
		t.Fatalf("%+v", servers)
	}
	h := servers[0].Http
	if !strings.HasPrefix(h.Url, "http://127.0.0.1:") || !strings.HasSuffix(h.Url, "/mcp/agents") || len(h.Headers) != 1 {
		t.Fatalf("%+v", h)
	}
	return &mcpClient{t: t, url: h.Url, token: strings.TrimPrefix(h.Headers[0].Value, "Bearer ")}
}

func TestTheAppsToolsAreServedToEachRuntime(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "Mine", Owner: wire.SessionLabelOwnerPerson, AddedAt: now()}}
	})
	m := appClient(t, d, a.ID)

	stranger := &mcpClient{t: t, url: m.url, token: "nobody"}
	if code, _ := stranger.post("initialize", map[string]any{}, 1); code != 404 {
		t.Fatalf("a stranger's token: %d", code)
	}
	code, init := m.post("initialize", map[string]any{"protocolVersion": "2025-03-26"}, 1)
	if code != 200 || m.session == "" || !strings.Contains(string(init["result"]), `"protocolVersion":"2025-03-26"`) {
		t.Fatalf("%d %s", code, init["result"])
	}
	_, list := m.post("tools/list", nil, 2)
	var tools struct {
		Tools []struct {
			Name        string                     `json:"name"`
			Description string                     `json:"description"`
			InputSchema map[string]json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	json.Unmarshal(list["result"], &tools)
	// drive_screen is the one tool this host may not offer at all, on a host with no
	// agents-drive beside it (#3004, host.desktop-control/1): this runner has none.
	want := len(appToolCalls())
	if !d.desktopControlAvailable() {
		want--
	}
	if len(tools.Tools) != want || tools.Tools[0].Name != "show_file" || tools.Tools[0].Description == "" ||
		!strings.Contains(string(tools.Tools[0].InputSchema["properties"]), `"description"`) {
		t.Fatalf("%s", list["result"])
	}

	call := func(id int, args map[string]any) (string, bool) {
		_, r := m.post("tools/call", map[string]any{"name": "mcp__agents__set_session_labels", "arguments": args}, id)
		var res struct {
			Content []struct{ Text string } `json:"content"`
			IsError bool                    `json:"isError"`
		}
		json.Unmarshal(r["result"], &res)
		return res.Content[0].Text, res.IsError
	}
	if text, isErr := call(3, map[string]any{"add": "review"}); isErr || text != "This session's labels: Mine, review." {
		t.Fatal(text)
	}
	if got := d.Store.Agent(a.ID).Labels; got[1].Owner != wire.SessionLabelOwnerAgent {
		t.Fatalf("%+v", got)
	}
	if text, isErr := call(4, map[string]any{"remove": []string{"mine"}}); !isErr || text != "Nothing changed: The label Mine belongs to the person, so an agent cannot change it." {
		t.Fatal(text)
	}
	if text, isErr := call(5, map[string]any{}); !isErr || text != "Nothing changed: give labels in add, remove, or both." {
		t.Fatal(text)
	}
	if _, r := m.post("tools/call", map[string]any{"name": "no_such"}, 6); !strings.Contains(string(r["error"]), "No tool called no_such.") {
		t.Fatalf("%s", r["error"])
	}

	// A new runtime is a new token: the old one is a server that is not there.
	old := *m
	appClient(t, d, a.ID)
	if code, _ := old.post("ping", nil, 7); code != 404 {
		t.Fatalf("the old token: %d", code)
	}
	// A browser page is not for this.
	req, _ := http.NewRequest("POST", m.url, strings.NewReader("{}"))
	req.Header.Set("Origin", "https://example.com")
	if res, _ := http.DefaultClient.Do(req); res.StatusCode != 403 {
		t.Fatal(res.StatusCode)
	}
}
