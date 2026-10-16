package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Daemon is one host: its root, the clients connected to it, and what it serves them.
type Daemon struct {
	ctx      context.Context
	Store    *store.Store
	handlers map[string]Handler

	mu      sync.Mutex
	clients map[int64]*Client
	unknown map[string]int
}

// New opens the root and registers every method this host serves.
func New(ctx context.Context, root string) (*Daemon, error) {
	st, err := store.Open(root)
	if err != nil {
		return nil, err
	}
	d := &Daemon{ctx: ctx, Store: st, handlers: map[string]Handler{}, clients: map[int64]*Client{}, unknown: map[string]int{}}
	d.register()
	return d, nil
}

func (d *Daemon) addClient(c *Client) {
	d.mu.Lock()
	d.clients[c.ID] = c
	d.mu.Unlock()
}

func (d *Daemon) removeClient(c *Client) {
	d.mu.Lock()
	delete(d.clients, c.ID)
	d.mu.Unlock()
}

// Broadcast sends a notification to every client.
func Broadcast[P any](d *Daemon, n wire.Notification[P], params P) {
	p, err := json.Marshal(params)
	if err != nil {
		log.Printf("encode %s: %v", n.Name, err)
		return
	}
	b, _ := json.Marshal(message{JSONRPC: "2.0", Method: n.Name, Params: p})
	d.mu.Lock()
	cs := make([]*Client, 0, len(d.clients))
	for _, c := range d.clients {
		cs = append(cs, c)
	}
	d.mu.Unlock()
	for _, c := range cs {
		_ = c.conn.Write(string(b))
	}
}

// Shutdown ends what the host runs.
func (d *Daemon) Shutdown() {}
