package agentsd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// fakeSlackMCP is a chat server over streamable HTTP with events: list_channels lists three
// channels and asks for nothing, post_message asks for a channel. calls counts its tools/call.
func fakeSlackMCP(t *testing.T, calls *atomic.Int32) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		result := `{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"events":{}}}`
		switch m.Method {
		case "tools/list":
			result = `{"tools":[{"name":"post_message","inputSchema":{"type":"object","required":["channel"]}},` +
				`{"name":"list_channels","inputSchema":{"type":"object"}}]}`
		case mcpEventsListMethod:
			result = `{"events":[{"name":"slack.message"},{"name":"slack.mention"}]}`
		case "tools/call":
			calls.Add(1)
			result = `{"content":[{"type":"text","text":"{\"channels\":[{\"name\":\"general\"},{\"name\":\"dev\"},{\"name\":\"ops\"}]}"}]}`
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%d,"result":%s}`, *m.ID, result)
	}))
	t.Cleanup(s.Close)
	return s
}

// The Messaging slot (#1787) is None, and done, until a messaging connector reaches the
// folder; then each one proves itself with one real read (its channel list) and says the
// events it declares; a read is not made again within five minutes; a connector that cannot
// be reached fails the slot only when none read; and None is a skip a person can take back.
func TestTheMessagingSlotReadsEachChatConnector(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	read := func(id int, reading string) (wire.ConnectorSlot, wire.ConnectorSetup) {
		var setup wire.ConnectorSetup
		json.Unmarshal(c.call(t, id, "connectors/setup", map[string]any{"folder": folder, "reading": reading}), &setup)
		return slotsByKind(setup)[wire.ConnectorSlotKindMessaging], setup
	}

	s, setup := read(2, "fresh")
	if s.State != wire.ConnectorSlotStateSkipped || s.Choice != "None" || len(s.Servers) != 0 || s.MessagingServers != nil {
		t.Fatalf("no connector: %+v", s)
	}
	none := setup.Done

	var calls atomic.Int32
	slack := fakeSlackMCP(t, &calls)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {
		"slack": {"type": "http", "url": "`+slack.URL+`"},
		"gmail": {"type": "http", "url": "http://127.0.0.1:1/mcp"},
		"kb": {"type": "http", "url": "https://kb.example.com/mcp"}}}`), 0o644)
	s, setup = read(3, "cached")
	if s.State != wire.ConnectorSlotStateRead || s.Choice != "Slack and Email" || !slices.Equal(s.Servers, []string{"slack", "gmail"}) ||
		len(s.MessagingServers) != 2 || setup.Done != none {
		t.Fatalf("read: %+v (done %d, was %d)", s, setup.Done, none)
	}
	got := s.MessagingServers[0]
	if got.Word != "Slack" || got.State != wire.MessagingServerStateRead || got.Proof == nil || got.Proof.Title != "3 channels" ||
		got.Proof.At == nil || !slices.Equal(got.Events, []string{"slack.message", "slack.mention"}) {
		t.Fatalf("slack: %+v %+v", got, got.Proof)
	}
	if s.Proof == nil || s.Proof.Title != "3 channels" {
		t.Fatalf("the slot's proof: %+v", s.Proof)
	}
	if g := s.MessagingServers[1]; g.Word != "Email" || g.State != wire.MessagingServerStateFailed || g.Message == nil {
		t.Fatalf("gmail: %+v", g)
	}

	if s, _ = read(4, "cached"); s.State != wire.ConnectorSlotStateRead || calls.Load() != 1 {
		t.Fatalf("read again within five minutes: %+v, %d calls", s, calls.Load())
	}

	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {
		"gmail": {"type": "http", "url": "http://127.0.0.1:1/mcp"}}}`), 0o644)
	if s, _ = read(5, "fresh"); s.State != wire.ConnectorSlotStateFailed || s.Message == nil {
		t.Fatalf("none read: %+v", s)
	}

	json.Unmarshal(c.call(t, 6, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "messaging", "skipped": true}), &setup)
	if s = slotsByKind(setup)[wire.ConnectorSlotKindMessaging]; s.State != wire.ConnectorSlotStateSkipped || s.Choice != "Email" ||
		!slices.Equal(s.Servers, []string{"gmail"}) {
		t.Fatalf("skipped: %+v", s)
	}
	json.Unmarshal(c.call(t, 7, "connectors/setup/skip", map[string]any{"folder": folder, "slot": "messaging", "skipped": false}), &setup)
	if s = slotsByKind(setup)[wire.ConnectorSlotKindMessaging]; s.State == wire.ConnectorSlotStateSkipped {
		t.Fatalf("set up again: %+v", s)
	}
}

func TestMessagingProof(t *testing.T) {
	for _, c := range []struct{ raw, noun, want string }{
		{`{"structuredContent":{"folders":[{},{}]},"content":[]}`, "folders", "2 folders"},
		{`{"content":[{"type":"text","text":"[{\"id\":1}]"}]}`, "channels", "1 channel"},
		{`{"content":[{"type":"text","text":"general, dev\nmore"}]}`, "channels", "general, dev"},
		{`{"content":[]}`, "spaces", "0 spaces"},
	} {
		p, err := messagingProof(json.RawMessage(c.raw), c.noun)
		if err != nil || p.Title != c.want {
			t.Errorf("%s: %+v %v, want %q", c.raw, p, err, c.want)
		}
	}
	if _, err := messagingProof(json.RawMessage(`{"isError":true,"content":[{"type":"text","text":"not_authed"}]}`), "channels"); err == nil ||
		err.Error() != "It said: not_authed" {
		t.Errorf("an error: %v", err)
	}
	if name, noun := messagingListTool([]messagingTool{{"get_channel_history", true}, {"slack_list_channels", false}}); name != "slack_list_channels" || noun != "channels" {
		t.Errorf("list tool: %s %s", name, noun)
	}
	if w, ok := messagingKindOf("mail", "npx @gongrzhe/server-gmail-autoauth-mcp"); !ok || w != "Email" {
		t.Errorf("gmail: %q %v", w, ok)
	}
	if _, ok := messagingKindOf("github", "github-mcp"); ok {
		t.Error("github is not messaging")
	}
}
