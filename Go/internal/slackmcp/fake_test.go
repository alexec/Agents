package slackmcp

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/slack-go/slack"
)

// fakeSlack is Slack's Web API and its Socket Mode, on this machine: enough for the tools
// and the listener. It answers a method from its table, keeps each call's form, and sends
// the envelopes given to send over the open socket, keeping the acks.

type fakeSlack struct {
	t      *testing.T
	server *httptest.Server
	// answers is a method's answer; ok:true when it has none.
	answers map[string]any

	mu    sync.Mutex
	calls map[string][]url.Values
	acks  []string
	// envelopes go out on the socket, once it is open.
	envelopes chan map[string]any
}

const (
	fakeTeam = "T1"
	fakeBot  = "UBOT"
)

func newFakeSlack(t *testing.T) *fakeSlack {
	f := &fakeSlack{t: t, calls: map[string][]url.Values{}, envelopes: make(chan map[string]any, 16), answers: map[string]any{
		"auth.test":        map[string]any{"ok": true, "team_id": fakeTeam, "user_id": fakeBot},
		"users.info":       map[string]any{"ok": true, "user": map[string]any{"id": "U2", "name": "sam", "profile": map[string]any{"display_name": "Sam", "email": "Sam@Example.com"}}},
		"chat.postMessage": map[string]any{"ok": true, "channel": "C1", "ts": "1762300000.000100"},
	}}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/socket" {
			conn, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer conn.Close()
			f.serveSocket(conn)
			return
		}
		method := strings.TrimPrefix(r.URL.Path, "/api/")
		_ = r.ParseForm()
		f.mu.Lock()
		f.calls[method] = append(f.calls[method], r.Form)
		answer, ok := f.answers[method]
		f.mu.Unlock()
		if method == "apps.connections.open" {
			answer, ok = map[string]any{"ok": true, "url": "ws" + strings.TrimPrefix(f.server.URL, "http") + "/socket"}, true
		}
		if !ok {
			answer = map[string]any{"ok": true}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(answer)
	}))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeSlack) serveSocket(conn *websocket.Conn) {
	_ = conn.WriteJSON(map[string]any{"type": "hello", "num_connections": 1,
		"connection_info": map[string]any{"app_id": "A1"}, "debug_info": map[string]any{"host": "fake"}})
	go func() {
		for {
			_, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			var ack struct {
				EnvelopeID string `json:"envelope_id"`
			}
			if json.Unmarshal(data, &ack) == nil && ack.EnvelopeID != "" {
				f.mu.Lock()
				f.acks = append(f.acks, ack.EnvelopeID)
				f.mu.Unlock()
			}
		}
	}()
	for e := range f.envelopes {
		if conn.WriteJSON(e) != nil {
			return
		}
	}
}

// workspace is a Workspace on the fake.
func (f *fakeSlack) workspace() *Workspace {
	return &Workspace{BotToken: "xoxb-test", AppToken: "xapp-test", APIURL: f.server.URL + "/api/"}
}

func (f *fakeSlack) called(method string) []url.Values {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]url.Values(nil), f.calls[method]...)
}

func (f *fakeSlack) acked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.acks...)
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func mustClient(t *testing.T, w *Workspace) *slack.Client {
	t.Helper()
	api, err := w.client()
	if err != nil {
		t.Fatal(err)
	}
	return api
}
