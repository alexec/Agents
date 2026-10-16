package channels

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)

// fakeSlack is FakeSlack: the Web API methods the channel calls, and a Socket Mode socket
// a test pushes envelopes into and reads acknowledgements from. No network.
type fakeSlack struct {
	mu        sync.Mutex
	calls     []fakeCall
	sockets   []*fakeSocket
	nextTS    int
	questions []string
	// refuse is Slack's error for a method, to refuse it.
	refuse map[string]string
}

type fakeCall struct {
	method, token string
	body          map[string]any
}

func newFakeSlack() *fakeSlack { return &fakeSlack{nextTS: 1, refuse: map[string]string{}} }

func (f *fakeSlack) made(method string) []fakeCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fakeCall
	for _, c := range f.calls {
		if c.method == method {
			out = append(out, c)
		}
	}
	return out
}

func (f *fakeSlack) socket() *fakeSocket {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.sockets) == 0 {
		return nil
	}
	return f.sockets[len(f.sockets)-1]
}

func (f *fakeSlack) connections() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sockets)
}

func (f *fakeSlack) lastTS() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.questions) == 0 {
		return ""
	}
	return f.questions[len(f.questions)-1]
}

func (f *fakeSlack) Call(_ context.Context, method, token string, body map[string]any) (map[string]any, error) {
	f.mu.Lock()
	f.calls = append(f.calls, fakeCall{method, token, body})
	refused, ok := f.refuse[method]
	f.mu.Unlock()
	if ok {
		return nil, SlackSaid(refused, method)
	}
	switch method {
	case "apps.connections.open":
		return map[string]any{"ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=t"}, nil
	case "conversations.open":
		return map[string]any{"ok": true, "channel": map[string]any{"id": "D1"}}, nil
	case "chat.postMessage":
		f.mu.Lock()
		ts := fmt.Sprintf("1700000000.%d", 100000+f.nextTS)
		f.nextTS++
		if _, threaded := body["thread_ts"]; !threaded {
			f.questions = append(f.questions, ts)
		}
		f.mu.Unlock()
		return map[string]any{"ok": true, "ts": ts, "channel": body["channel"]}, nil
	}
	return map[string]any{"ok": true}, nil
}

func (f *fakeSlack) Connect(_ context.Context, _ string) (LineConn, error) {
	s := &fakeSocket{lines: make(chan string, 64), closed: make(chan struct{})}
	f.mu.Lock()
	f.sockets = append(f.sockets, s)
	f.mu.Unlock()
	s.push(map[string]any{"type": "hello", "num_connections": 1})
	return s, nil
}

// press is a button pressed in Slack.
func (f *fakeSlack) press(value, key, user string) {
	f.socket().push(map[string]any{"envelope_id": NewUUID(), "type": "interactive", "payload": map[string]any{
		"type": "block_actions", "user": map[string]any{"id": user},
		"actions": []any{map[string]any{"block_id": key, "action_id": "option-0", "value": value}},
	}})
}

// reply is a message in Slack, in a thread when ts is given.
func (f *fakeSlack) reply(text, ts, user string, bot bool) {
	event := map[string]any{"type": "message", "channel": "D1", "user": user, "text": text, "ts": "1700000099.000001"}
	if ts != "" {
		event["thread_ts"] = ts
	}
	if bot {
		event["bot_id"] = "B1"
	}
	f.socket().push(map[string]any{"envelope_id": NewUUID(), "type": "events_api", "payload": map[string]any{"event": event}})
}

// fakeSocket is FakeSlackSocket.
type fakeSocket struct {
	mu      sync.Mutex
	written []string
	lines   chan string
	closed  chan struct{}
	once    sync.Once
}

func (s *fakeSocket) push(envelope any) {
	data, _ := json.Marshal(envelope)
	s.lines <- string(data)
}

func (s *fakeSocket) acks() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, line := range s.written {
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) == nil {
			if id, ok := m["envelope_id"].(string); ok {
				out = append(out, id)
			}
		}
	}
	return out
}

func (s *fakeSocket) ReadLine(ctx context.Context) (string, error) {
	select {
	case line := <-s.lines:
		return line, nil
	case <-s.closed:
		return "", io.EOF
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (s *fakeSocket) WriteLine(line string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.written = append(s.written, line)
	return nil
}

func (s *fakeSocket) Close() error {
	s.once.Do(func() { close(s.closed) })
	return nil
}

// eventually waits up to five seconds for ok.
func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("never: %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
