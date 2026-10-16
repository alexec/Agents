package daemon

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

type lines struct{ out []string }

func (l *lines) Write(s string) error { l.out = append(l.out, s); return nil }
func (l *lines) In() <-chan string    { return nil }
func (l *lines) Close()               {}
func (l *lines) Device() string       { return "" }

// A handler that panics answers -32603, and the host goes on serving (#1125, the morning walk).
func TestPanickingHandlerAnswersAnError(t *testing.T) {
	d := &Daemon{ctx: context.Background(), handlers: map[string]Handler{}, unknown: map[string]int{}}
	d.Handle("boom", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		var m map[string]int
		m["x"] = 1
		return nil, nil
	})
	d.Handle("ok", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return "fine", nil })
	conn := &lines{}
	c := &Client{conn: conn, d: d}
	d.dispatch(c, rpcMessage{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "boom"})
	d.dispatch(c, rpcMessage{JSONRPC: "2.0", ID: json.RawMessage("2"), Method: "ok"})
	if len(conn.out) != 2 || !strings.Contains(conn.out[0], "-32603") || !strings.Contains(conn.out[1], `"fine"`) {
		t.Fatalf("replies: %v", conn.out)
	}
}
