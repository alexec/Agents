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
	"time"

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
	CodeRuntimeNotFound     = -32001
	CodeRuntimeWillNotStart = -32002
	CodeFolderGone          = -32004
	CodeNoSuchAgent         = -32005
	CodeNotSupported        = -32009
	CodeNoSuchFolder       = -32012
	CodeCredentialWanted    = -32036
)

// Invalid is a -32602 for params that do not say what the method needs.
func Invalid(format string, args ...any) *Error {
	return &Error{Code: CodeInvalidParams, Message: fmt.Sprintf(format, args...)}
}

// Client is one connection: a channel from the control plane, or daemon.sock.
type Client struct {
	ID   int64
	Role Role
	conn controllink.Conn
	d    *Daemon
	// actor is who the control plane says this connection's calls are from (#1751).
	actor *wire.AuditActor
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
	c := &Client{ID: nextClient.Add(1), Role: roleOf(conn), conn: conn, d: d, actor: actorOf(conn)}
	// Only a person's connection is one the host speaks to unasked (roles.go).
	if c.Role.HearsNotifications() {
		d.addClient(c)
		defer d.removeClient(c)
	}
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
	if !c.Role.Allows(m.Method) {
		err = &Error{Code: CodeNotPermitted, Message: fmt.Sprintf("%s is not open to this connection (%s).", m.Method, c.Role)}
	} else if h == nil {
		d.logUnknown(m.Method)
		err = &Error{Code: CodeMethodNotFound, Message: "Method not found: " + m.Method}
	} else if v := safe.Catch("rpc "+m.Method, func() { result, err = h(d.ctx, c, m.Params) }); v != nil {
		err = &Error{Code: CodeInternal, Message: fmt.Sprintf("the machine hit a bug in %s: %v", m.Method, v)}
	}
	if err == nil && h != nil {
		d.noteMilestones(c, m.Method)
		d.countCall(c, m.Method)
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

// A daemon.sock client is written by a goroutine of its own, through a bounded queue, so a
// client that stops reading (a window hung or stopped in a debugger) never holds Broadcast,
// its caller or any lock the caller has (#1399): its queue stays full for sockQueueWait, or
// a write to it takes longer than sockWriteDeadline, and it is let go. It connects again and catches up.
const (
	sockQueue         = 1024
	sockQueueWait     = 2 * time.Second
	sockWriteDeadline = 10 * time.Second
)

var errSocketGone = errors.New("the socket's client was let go")

type sockConn struct {
	c    net.Conn
	out  chan string
	done chan struct{}
	once sync.Once
	in   chan string
	role Role
}

func newSockConn(c net.Conn, role Role) *sockConn {
	s := &sockConn{c: c, out: make(chan string, sockQueue), done: make(chan struct{}), in: make(chan string, 256), role: role}
	safe.Go("socket write", s.writeAll)
	return s
}

// Write queues a line; it never waits for the client.
func (s *sockConn) Write(line string) error {
	select {
	case <-s.done:
		return errSocketGone
	default:
	}
	select {
	case s.out <- line:
		return nil
	case <-s.done:
		return errSocketGone
	default:
	}
	// Full: a client behind in a burst gets a moment; one that reads nothing is let go.
	wait := time.NewTimer(sockQueueWait)
	defer wait.Stop()
	select {
	case s.out <- line:
		return nil
	case <-s.done:
		return errSocketGone
	case <-wait.C:
		log.Printf("socket: a client read none of the last %d lines in %s; let go", sockQueue, sockQueueWait)
		s.Close()
		return errSocketGone
	}
}

// writeAll writes what is queued, as much as is there at once, until the client goes.
func (s *sockConn) writeAll() {
	w := bufio.NewWriter(s.c)
	for {
		select {
		case <-s.done:
			return
		case line := <-s.out:
			s.c.SetWriteDeadline(time.Now().Add(sockWriteDeadline))
			_, err := w.WriteString(line + "\n")
			for more := true; more && err == nil; {
				select {
				case next := <-s.out:
					_, err = w.WriteString(next + "\n")
				default:
					more = false
				}
			}
			if err == nil {
				err = w.Flush()
			}
			if err != nil {
				if errors.Is(err, os.ErrDeadlineExceeded) {
					log.Printf("socket: a client took over %s to take a write; let go", sockWriteDeadline)
				}
				s.Close()
				return
			}
		}
	}
}

func (s *sockConn) In() <-chan string { return s.in }
func (s *sockConn) Close()            { s.once.Do(func() { close(s.done); s.c.Close() }) }
func (s *sockConn) Device() string    { return "" }
func (s *sockConn) Role() Role        { return s.role }

// ServeSocket answers on daemon.sock, mode 0600 in the root, until ctx ends.
func (d *Daemon) ServeSocket(ctx context.Context, path string) error {
	os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	os.Chmod(path, 0o600)
	policy := d.socketPolicy()
	log.Printf("socket: %s", policy.Summary())
	safe.Go("socket close", func() { <-ctx.Done(); l.Close() })
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		safe.Go("socket accept", func() { d.acceptSocket(c, policy) })
	}
}

func (d *Daemon) acceptSocket(c net.Conn, policy SocketPolicy) {
	role, ok := policy.Role(c)
	if !ok {
		c.Close() // another account, or one the kernel would not name
		return
	}
	d.serveSockConn(newSockConn(c, role), bufio.NewReaderSize(c, 1<<20))
}

// serveSockConn reads sc's lines from r, which may hold some already, and serves it until
// it goes.
func (d *Daemon) serveSockConn(sc *sockConn, r *bufio.Reader) {
	safe.Go("socket read", func() {
		// A client gone takes its writer with it.
		defer sc.Close()
		defer close(sc.in)
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
	d.Accept(sc)
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
