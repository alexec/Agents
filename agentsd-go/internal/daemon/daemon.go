package daemon

import (
	"context"

	"encoding/json"
	"log"
	"os/exec"
	"sync"

	acp "github.com/coder/acp-go-sdk"
)

type Daemon struct {
	ctx      context.Context
	Root     string
	HostID   string
	handlers map[string]Handler

	mu        sync.Mutex
	clients   map[int64]*Client
	unknown   map[string]int
	broadcast func(line string)

	store *Store

	lives    map[string]*live
	relays   map[string]*relay
	sent     map[string]bool
	tunneler Tunneler
	// Sandbox, when set, wraps a runtime's argv (stage 4: Landlock; stage 5: sandbox-exec).
	Sandbox func(runtimeID, dir string, argv []string) []string
	// appTools, when set, is the app's own MCP server for an agent (stage 2).
	appTools   func(agentID string) []acp.McpServer
	toolsPort  int
	hosted     *hostedServers
	shells     map[shellKey]*shell
	wf         *workflows
	turns      int
	caffeinate *exec.Cmd
}

// turnRunning counts the turns that run, and keeps the Mac awake while any does.
func (d *Daemon) turnRunning(started bool) {
	d.mu.Lock()
	if started {
		d.turns++
	} else {
		d.turns--
	}
	n := d.turns
	d.mu.Unlock()
	if started && n == 1 {
		d.awake(true)
	} else if !started && n == 0 {
		d.awake(false)
	}
}

func New(ctx context.Context, root string) (*Daemon, error) {
	d := &Daemon{ctx: ctx, Root: root, handlers: map[string]Handler{}, clients: map[int64]*Client{}, unknown: map[string]int{}}
	st, err := OpenStore(root)
	if err != nil {
		return nil, err
	}
	d.store = st
	d.register()
	d.startWorkflows()
	return d, nil
}

func (d *Daemon) Handle(method string, h Handler) { d.handlers[method] = h }

func (d *Daemon) SetBroadcaster(b func(line string)) {
	d.mu.Lock()
	d.broadcast = b
	d.mu.Unlock()
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
	d.dropSubscriptions(c)
}

// Broadcast sends a notification to every client.
func (d *Daemon) Broadcast(method string, params any) {
	p, err := json.Marshal(params)
	if err != nil {
		log.Printf("broadcast %s: %v", method, err)
		return
	}
	b, _ := json.Marshal(rpcMessage{JSONRPC: "2.0", Method: method, Params: p})
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

func (d *Daemon) dropSubscriptions(c *Client) {}

func (d *Daemon) Shutdown() {
	d.stopAll()
}
