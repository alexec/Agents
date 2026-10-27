package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"sort"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Daemon is one host: its root, the clients connected to it, and what it serves them.
type Daemon struct {
	ctx      context.Context
	Store    *store.Store
	handlers map[string]Handler

	// erasures is the queue of runtime copies of deleted agents to erase (#1001).
	erasures eraser

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
	viewCountBook
	attachmentBook
	settingsState
	userScopeState
	selfUpdateState
	quitState
	leaseState
	eventBook
	actorBook
	appToolsState
	hostUserState
	userSuspendState
	machinePinState
	hostedPool
	eventWaitState
	messageState
	helperQueueState
	costBook
	workflowBook
	allowanceBook
	accountBook
	mcpBook
	viewBook
	mcpHealthBook
	mcpEventsBook
	restartBook
	machineBook
	hostStatusBook
	idleBook
	turnBook
	findBook
	optionBook
	timeBook
	reportBook
	projectBook
	projectToolsBook
	milestoneBook
	afterTurnState
	attentionState
	worktreeState
	recoveryState
	backupState
	folderState
	installBook
	guardedStateHolder
	macState
	folderWatchState
	deviceBook
	localBook
	connectionBook
	setupBook
	orgPolicyState
	orgRouteState
	// lent is a sign-in secret the window lent for a launch (#2524). It stays in memory.
	lent lentBook
	// pageEdits is what the person changed on live pages since each agent's last turn.
	pageEdits  pageEdits
	policyOnce sync.Once
	policy     SocketPolicy
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
	d.setToolsHome()
	d.register()
	d.loadAttention()
	d.loadEvents()
	d.beginMCPApprovals()
	d.recover()
	d.startErasures()
	// How long nothing ran, and the waits open over it (#1219): before anything below can
	// raise an event that wakes one, so its wake says so.
	d.noteRestart()
	d.resumeEventWaits()
	// A lease's line and the waits for it agree again (#2361).
	d.reconcileLineWaits()
	d.resumeBlocks()
	d.resumeContinues()
	d.checkEveryQueue()
	d.restoreRuns()
	safe.Go("workflow clock", d.workflowClock)
	// Each folder's one watch (#173), which the first workflow scan starts too.
	d.kickFolderWatches()
	if done := ctx.Done(); done != nil {
		safe.Go("folder watches end", func() { <-done; d.stopFolderWatches() })
	}
	d.checkMilestonesSoon()
	d.countMergedPRsEveryHour()
	d.watchDisk()
	// The counts on the servers' list view rows (#2033).
	d.startViewCounts()
	d.installDefaultToolsets()
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
	// Those on a control-plane uplink: one frame per uplink, naming who hears it (#167).
	routed := map[*controllink.Uplink][]int{}
	for _, c := range cs {
		if f, ok := c.conn.(controllink.FanOuter); ok {
			if up, n, yes := f.FanOutRoute(); yes {
				routed[up] = append(routed[up], n)
				continue
			}
		}
		_ = c.conn.Write(string(b))
	}
	for up, ns := range routed {
		sort.Ints(ns)
		_ = up.WriteFanOut(ns, string(b))
	}
}

// Shutdown ends what the host runs: every runtime it started.
func (d *Daemon) Shutdown() {
	// First, so a stop that goes wrong below still counts as a stop (#1219).
	stoppedAt := d.noteCleanStop()
	d.machineMu.Lock()
	if d.machineStop != nil {
		d.machineStop()
		d.machineStop = nil
	}
	d.machineMu.Unlock()
	d.stopIdleTimers()
	// Nothing more is routed or written down once the host is going.
	d.attentionMu.Lock()
	d.presences = nil
	for _, t := range d.settling {
		t.Stop()
	}
	d.attentionMu.Unlock()
	// No turn starts, and nothing new follows one; the turns stopped here record their
	// endings and what follows them before the files they write are closed (#1272).
	d.closeAfterTurns()
	d.stopAll()
	d.waitAfterTurns(afterTurnLimit)
	d.noteCutOffAgents(stoppedAt)
	d.closeReport()
	d.clearPickUps()
	d.stopMCPEvents()
	d.stopEvents()
	d.stopAppTools()
	d.allowMu.Lock()
	d.allowStopped = true
	d.allowMu.Unlock()
	d.stopEventWaits()
	d.stopShells()
	d.stopFolderWatches()
	d.stopPins()
	d.stopSignInRelays()
	d.stopModelRelay()
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
