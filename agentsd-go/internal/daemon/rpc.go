// Package daemon is the daemon's core: the JSON-RPC methods a window calls on a host
// (DaemonAPI.swift), agents, their transcripts, and the notifications clients hear.
package daemon

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

	"github.com/alexec/agents/agentsd-go/internal/control"

	"github.com/alexec/agents/agentsd-go/internal/safe"
)

type rpcMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *RPCError) Error() string { return fmt.Sprintf("%d %s", e.Code, e.Message) }

func notFound(method string) *RPCError {
	return &RPCError{Code: -32601, Message: "Method not found: " + method}
}

func invalid(err error) *RPCError { return &RPCError{Code: -32602, Message: err.Error()} }

// Client is one connection: a channel from the control plane, or daemon.sock.
type Client struct {
	ID     int64
	conn   control.Conn
	d      *Daemon
	mu     sync.Mutex
	closed atomic.Bool
}

func (c *Client) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("encode: %v", err)
		return
	}
	if err := c.conn.Write(string(b)); err != nil {
		c.closed.Store(true)
	}
}

// Notify sends a notification to this client.
func (c *Client) Notify(method string, params any) {
	p, _ := json.Marshal(params)
	c.send(rpcMessage{JSONRPC: "2.0", Method: method, Params: p})
}

type Handler func(ctx context.Context, c *Client, params json.RawMessage) (any, error)

var nextClient atomic.Int64

// Accept serves one connection until it closes.
func (d *Daemon) Accept(conn control.Conn) {
	c := &Client{ID: nextClient.Add(1), conn: conn, d: d}
	d.addClient(c)
	defer d.removeClient(c)
	for line := range conn.In() {
		var m rpcMessage
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			c.send(rpcMessage{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &RPCError{Code: -32700, Message: "parse error"}})
			continue
		}
		if m.Method == "" {
			continue // a reply; nothing here asks clients anything
		}
		safe.Go("rpc "+m.Method, func() { d.dispatch(c, m) })
	}
}

func (d *Daemon) dispatch(c *Client, m rpcMessage) {
	h := d.handlers[m.Method]
	var result any
	var err error
	if h == nil {
		d.logUnknown(m.Method, m.Params)
		err = notFound(m.Method)
	} else if v := safe.Catch("rpc "+m.Method, func() { result, err = h(d.ctx, c, m.Params) }); v != nil {
		err = &RPCError{Code: -32603, Message: fmt.Sprintf("the host hit a bug in %s: %v", m.Method, v)}
	}
	if m.ID == nil {
		return // a notification
	}
	if err != nil {
		var re *RPCError
		if !errors.As(err, &re) {
			re = &RPCError{Code: -32000, Message: err.Error()}
		}
		c.send(rpcMessage{JSONRPC: "2.0", ID: m.ID, Error: re})
		return
	}
	b, merr := json.Marshal(result)
	if merr != nil {
		c.send(rpcMessage{JSONRPC: "2.0", ID: m.ID, Error: &RPCError{Code: -32603, Message: merr.Error()}})
		return
	}
	c.send(rpcMessage{JSONRPC: "2.0", ID: m.ID, Result: b})
}

func (d *Daemon) logUnknown(method string, params json.RawMessage) {
	d.mu.Lock()
	seen := d.unknown[method]
	d.unknown[method] = seen + 1
	d.mu.Unlock()
	if seen == 0 {
		p := string(params)
		if len(p) > 300 {
			p = p[:300] + "…"
		}
		log.Printf("rpc: not served: %s %s", method, p)
	}
}

// MARK: daemon.sock, for driving the host by hand (server-rpc.sh, rpc.py)

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
