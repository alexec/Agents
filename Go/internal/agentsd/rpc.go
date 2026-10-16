// Package agentsd is the Go host daemon (#1136): the JSON-RPC methods a window calls on a
// server host (DaemonAPI), over each channel the control plane opens and over daemon.sock,
// on a root laid out as the Swift daemon lays it out.
package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Error is a JSON-RPC error, with DaemonAPI's codes.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s", e.Code, e.Message) }

// The codes a window acts on (DaemonAPI.ErrorCode).
const (
	CodeParse          = -32700
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternal       = -32603
	CodeServer         = -32000
	// DaemonAPI.Failure.
	CodeRuntimeNotFound  = -32001
	CodeFolderGone       = -32004
	CodeNoSuchAgent      = -32005
	CodeNotSupported     = -32009
	CodeNoSuchProject    = -32012
	CodeCredentialWanted = -32036
)

// Invalid is a -32602 for params that do not say what the method needs.
func Invalid(format string, args ...any) *Error {
	return &Error{Code: CodeInvalidParams, Message: fmt.Sprintf(format, args...)}
}

// Client is one connection: a channel from the control plane, or daemon.sock.
type Client struct {
	ID   int64
	conn controllink.Conn
	d    *Daemon
}

func (c *Client) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("encode: %v", err)
		return
	}
	_ = c.conn.Write(string(b))
}

// Notify sends a notification to this client.
func Notify[P any](c *Client, n wire.Notification[P], params P) {
	p, err := json.Marshal(params)
	if err != nil {
		log.Printf("encode %s: %v", n.Name, err)
		return
	}
	c.send(message{JSONRPC: "2.0", Method: n.Name, Params: p})
}

// Handler answers one method's params.
type Handler func(ctx context.Context, c *Client, params json.RawMessage) (any, error)

// On serves a method with its generated types: the params are decoded into P, and the
// result is R, so a handler cannot answer in another shape than the schema's.
func On[P, R any](d *Daemon, m wire.Method[P, R], h func(ctx context.Context, c *Client, p P) (R, error)) {
	d.handlers[m.Name] = func(ctx context.Context, c *Client, raw json.RawMessage) (any, error) {
		var p P
		if len(raw) > 0 && string(raw) != "null" {
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, Invalid("%s: %v", m.Name, err)
			}
		}
		return h(ctx, c, p)
	}
}

// Quiet serves a method that this host accepts and has nothing to do for: a setting the
// window pushes, a report it sends. It answers {}.
func Quiet(d *Daemon, names ...string) {
	for _, n := range names {
		d.handlers[n] = func(context.Context, *Client, json.RawMessage) (any, error) { return wire.Empty{}, nil }
	}
}

var nextClient atomic.Int64

// Accept serves one connection until it closes.
func (d *Daemon) Accept(conn controllink.Conn) {
	c := &Client{ID: nextClient.Add(1), conn: conn, d: d}
	d.addClient(c)
	defer d.removeClient(c)
	for line := range conn.In() {
		var m message
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			c.send(message{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &Error{Code: CodeParse, Message: "parse error"}})
			continue
		}
		if m.Method == "" {
			continue // a reply: nothing here asks a client anything yet
		}
		safe.Go("rpc "+m.Method, func() { d.dispatch(c, m) })
	}
}

func (d *Daemon) dispatch(c *Client, m message) {
	h := d.handlers[m.Method]
	var result any
	var err error
	if h == nil {
		d.logUnknown(m.Method)
		err = &Error{Code: CodeMethodNotFound, Message: "Method not found: " + m.Method}
	} else if v := safe.Catch("rpc "+m.Method, func() { result, err = h(d.ctx, c, m.Params) }); v != nil {
		err = &Error{Code: CodeInternal, Message: fmt.Sprintf("the host hit a bug in %s: %v", m.Method, v)}
	}
	if m.ID == nil {
		return // a notification
	}
	if err != nil {
		var re *Error
		if !errors.As(err, &re) {
			re = &Error{Code: CodeServer, Message: err.Error()}
		}
		c.send(message{JSONRPC: "2.0", ID: m.ID, Error: re})
		return
	}
	b, merr := json.Marshal(result)
	if merr != nil {
		c.send(message{JSONRPC: "2.0", ID: m.ID, Error: &Error{Code: CodeInternal, Message: merr.Error()}})
		return
	}
	c.send(message{JSONRPC: "2.0", ID: m.ID, Result: b})
}

func (d *Daemon) logUnknown(method string) {
	d.mu.Lock()
	seen := d.unknown[method]
	d.unknown[method] = seen + 1
	d.mu.Unlock()
	if seen == 0 {
		log.Printf("rpc: not served here yet: %s", method)
	}
}

// MARK: daemon.sock, for driving the host by hand (server-rpc.sh)

type sockConn struct {
	c  net.Conn
	w  *bufio.Writer
	mu sync.Mutex
	in chan string
}

func (s *sockConn) Write(line string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.w.WriteString(line + "\n"); err != nil {
		return err
	}
	return s.w.Flush()
}
func (s *sockConn) In() <-chan string { return s.in }
func (s *sockConn) Close()            { s.c.Close() }
func (s *sockConn) Device() string    { return "" }

// ServeSocket answers on daemon.sock, mode 0600 in the root, until ctx ends.
func (d *Daemon) ServeSocket(ctx context.Context, path string) error {
	os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	os.Chmod(path, 0o600)
	safe.Go("socket close", func() { <-ctx.Done(); l.Close() })
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		sc := &sockConn{c: c, w: bufio.NewWriter(c), in: make(chan string, 256)}
		safe.Go("socket read", func() {
			defer close(sc.in)
			r := bufio.NewReaderSize(c, 1<<20)
			for {
				line, err := r.ReadString('\n')
				if len(line) > 1 {
					sc.in <- line[:len(line)-1]
				}
				if err != nil {
					return
				}
			}
		})
		safe.Go("socket client", func() { d.Accept(sc) })
	}
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
