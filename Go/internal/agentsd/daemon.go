package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Daemon is one host: its root, the clients connected to it, and what it serves them.
type Daemon struct {
	ctx      context.Context
	Store    *store.Store
	handlers map[string]Handler

	// Tunneler opens tunnels through the control plane, to a host that lends a sign-in;
	// nil when this host has no control plane.
	Tunneler Tunneler

	mu      sync.Mutex
	clients map[int64]*Client
	unknown map[string]int
	lives   map[wire.UUID]*live
	relays  map[string]*relay
	sent    map[wire.UUID]bool
	// watches is each watched agent folder's inotify, and interests who watches it.
	watches   map[string]*folderWatch
	interests map[string][]interest
	shells    map[shellKey]*shell
	// agentMu orders every read-change-save of an agent record.
	agentMu sync.Mutex
	pinState
	settingsState
	quitState
	leaseState
	eventBook
	appToolsState
	eventWaitState
	messageState
	helperQueueState
	costBook
	workflowBook
	allowanceBook
	mcpBook
	optionBook
	attentionState
	worktreeState
	recoveryState
	projectState
	guardedStateHolder
	// SettingsDir is the person's settings on this host (StoreLocations.personalSettings):
	// <root>/settings, or $HOME/.agents/settings for a server, as the Swift host's --serve.
	SettingsDir string
	// RaiseByHand lets events/raise make an event: an unreleased build on a scratch root.
	RaiseByHand bool
}

// New opens the root and registers every method this host serves.
func New(ctx context.Context, root string) (*Daemon, error) {
	st, err := store.Open(root)
	if err != nil {
		return nil, err
	}
	d := &Daemon{ctx: ctx, Store: st, handlers: map[string]Handler{}, clients: map[int64]*Client{}, unknown: map[string]int{},
		lives: map[wire.UUID]*live{}, relays: map[string]*relay{}, sent: map[wire.UUID]bool{},
		watches: map[string]*folderWatch{}, interests: map[string][]interest{}, shells: map[shellKey]*shell{},
		SettingsDir: filepath.Join(st.Loc.Root, "settings")}
	d.register()
	d.loadAttention()
	d.loadEvents()
	d.beginMCPApprovals()
	d.recover()
	d.resumeEventWaits()
	d.resumeBlocks()
	d.checkEveryQueue()
	d.restoreRuns()
	safe.Go("workflow clock", d.workflowClock)
	d.watchDisk()
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
	d.forgetWatches(c)
	d.forgetPresence(c)
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

// Shutdown ends what the host runs: every runtime it started.
func (d *Daemon) Shutdown() {
	// Nothing more is routed or written down once the host is going.
	d.attentionMu.Lock()
	d.presences = nil
	for _, t := range d.settling {
		t.Stop()
	}
	d.attentionMu.Unlock()
	d.stopAll()
	d.clearPickUps()
	d.stopEvents()
	d.stopAppTools()
	d.allowMu.Lock()
	d.allowStopped = true
	d.allowMu.Unlock()
	d.stopEventWaits()
	d.stopShells()
}

// once is true the first time a sendID is seen: a window sends a prompt again for 30 s
// until it hears it was taken, and it must run once.
func (d *Daemon) once(sendID *wire.UUID) bool {
	if sendID == nil {
		return true
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.sent[*sendID] {
		return false
	}
	if len(d.sent) > 4096 {
		d.sent = map[wire.UUID]bool{}
	}
	d.sent[*sendID] = true
	return true
}
