package agentsd

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Make my agents' bot (#3858): the host gives the manifest, turns the code GitHub gave back into
// the App's key, keeps the key in its own store, and gives a client only the bot's name and
// where to install it.
func TestMakingTheAgentsBot(t *testing.T) {
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	pemText := string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)}))
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/app-manifests/the-code/conversions":
			w.WriteHeader(http.StatusCreated)
			fmt.Fprintf(w, `{"id":42,"slug":"alexec-agents","owner":{"login":"alexec"},"pem":%q}`, pemText)
		case "/app/installations":
			fmt.Fprint(w, `[{"id":7,"account":{"login":"alexec","type":"User"},"repository_selection":"selected"}]`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer gh.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.newBotClient = func() *connections.BotClient { return &connections.BotClient{API: gh.URL, HTTP: gh.Client()} }

	if msg := c.callErr(t, 1, "connections/bot/start", map[string]any{}); !strings.Contains(msg, "Connect GitHub first") {
		t.Fatalf("with no GitHub: %q", msg)
	}
	_ = file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "gho_x", ConnectedAt: time.Now()})

	var none wire.ConnectionBot
	mustUnmarshal(t, c.call(t, 2, "connections/bot", map[string]any{}), &none)
	if none.Made {
		t.Fatalf("a bot before one was made: %+v", none)
	}
	var s wire.ConnectionBotStart
	mustUnmarshal(t, c.call(t, 3, "connections/bot/start", map[string]any{"origin": "https://agentloops.dev"}), &s)
	if !strings.HasPrefix(s.Action, "https://github.com/settings/apps/new?state=") || !strings.Contains(s.Manifest, `"alexec-agents"`) || !strings.Contains(s.State, ".") {
		t.Fatalf("start: %+v", s)
	}
	if msg := c.callErr(t, 4, "connections/bot/complete", map[string]any{"state": "another", "code": "the-code"}); !strings.Contains(msg, "another request") {
		t.Fatalf("another state: %q", msg)
	}
	raw := c.call(t, 5, "connections/bot/complete", map[string]any{"state": s.State, "code": "the-code"})
	if strings.Contains(string(raw), "PRIVATE KEY") {
		t.Fatalf("the key went to the client: %s", raw)
	}
	var made wire.ConnectionBot
	mustUnmarshal(t, raw, &made)
	if !made.Made || deref(made.Name) != "alexec-agents[bot]" || deref(made.InstallURL) != "https://github.com/apps/alexec-agents/installations/new" {
		t.Fatalf("made: %s", raw)
	}
	kept, ok, _ := file.Get(connections.GitHubBot)
	if b, isBot := connections.BotOf(kept); !ok || !isBot || b.PrivateKey != pemText || b.Person != "alexec" {
		t.Fatalf("kept: %+v", kept)
	}
	if msg := c.callErr(t, 6, "connections/bot/complete", map[string]any{"state": s.State, "code": "the-code"}); !strings.Contains(msg, "another request") {
		t.Fatalf("the same state twice: %q", msg)
	}

	raw = c.call(t, 7, "connections/bot", map[string]any{})
	var shown wire.ConnectionBot
	mustUnmarshal(t, raw, &shown)
	if strings.Contains(string(raw), "PRIVATE KEY") || !shown.Made || len(shown.Installations) != 1 || shown.Installations[0].Account != "alexec" {
		t.Fatalf("connections/bot: %s", raw)
	}
	var gone wire.ConnectionBot
	mustUnmarshal(t, c.call(t, 8, "connections/bot/remove", map[string]any{}), &gone)
	if _, ok, _ := file.Get(connections.GitHubBot); ok || gone.Made {
		t.Fatalf("removed: %+v", gone)
	}
}

func mustUnmarshal(t *testing.T, raw json.RawMessage, into any) {
	t.Helper()
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
}
