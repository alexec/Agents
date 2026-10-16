package service

import (
	"context"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Conn is a WebSocket carrying one line per text frame (WebSocketLineTransport). Writes
// queue and never block the router: a peer that falls this far behind is closed, and
// reconnects to read everything afresh, as the Swift transport's bound does.
type Conn struct {
	ws     *websocket.Conn
	out    chan string
	done   chan struct{}
	once   sync.Once
	Remote string
	mu     sync.Mutex
	closed []func()
}

const queued = 8192

func newConn(ws *websocket.Conn, remote string) *Conn {
	ws.SetReadLimit(64 << 20)
	c := &Conn{ws: ws, out: make(chan string, queued), done: make(chan struct{}), Remote: remote}
	go c.write()
	go c.ping()
	return c
}

func (c *Conn) write() {
	for {
		select {
		case line := <-c.out:
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			err := c.ws.Write(ctx, websocket.MessageText, []byte(line))
			cancel()
			if err != nil {
				c.Close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// A ping every 20 s; no pong within 20 s more and the socket goes.
func (c *Conn) ping() {
	t := time.NewTicker(20 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			err := c.ws.Ping(ctx)
			cancel()
			if err != nil {
				c.Close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// Send queues a line; false when the socket is closed or too far behind (and so closed).
func (c *Conn) Send(line string) bool {
	select {
	case <-c.done:
		return false
	default:
	}
	select {
	case c.out <- line:
		return true
	default:
		c.Close()
		return false
	}
}

// SendNow writes a line and waits for it to go: the exchange, and a last reply.
func (c *Conn) SendNow(line string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, []byte(line))
}

func (c *Conn) Read(ctx context.Context) (string, error) {
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		c.Close()
	}
	return string(b), err
}

func (c *Conn) ReadWithin(d time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	return c.Read(ctx)
}

func (c *Conn) Close() { c.CloseWith(websocket.StatusNormalClosure, "") }

func (c *Conn) CloseWith(code websocket.StatusCode, reason string) {
	c.once.Do(func() {
		close(c.done)
		go c.ws.Close(code, reason)
		c.mu.Lock()
		fs := c.closed
		c.mu.Unlock()
		for _, f := range fs {
			f()
		}
	})
}

func (c *Conn) Done() <-chan struct{} { return c.done }
