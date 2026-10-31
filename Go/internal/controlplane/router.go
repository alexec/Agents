package controlplane

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
	"github.com/coder/websocket"
)

// Caller is ControlRouter.Caller: who is calling, as the control plane's own methods
// need to know.
type Caller struct {
	Session string
	Client  string
	Kind    string
	// The device came through agents-relay (T096), not straight here.
	Relayed bool
	// The person the client belongs to (#994): it reaches only that person's machines.
	Person string
}

// Ownership is who owns what (#994, spec 736 FR-018), from the records in memory: the
// person of a client, and the user of a machine.
type Ownership interface {
	PersonOf(client string) string
	OwnerOf(host string) string
}

// botOwners says a machine is a bot's and the person an admin, who is told so (#1761).
type botOwners interface {
	BotMachineFor(person, host string) bool
}

// Handler is ControlHandling: what the control plane answers itself, handed to the
// router so the router stays ignorant of pairing, stores and ssh.
type Handler interface {
	// Handles says whether a method with no host named is the control plane's own. A
	// legacy client's bare line for any other method goes to the home host.
	Handles(method string) bool
	// Handle answers a request from a client for the control plane itself.
	Handle(method string, params json.RawMessage, from Caller) (any, error)
	// HostSaid answers a request on a host's channel 0: host/hello, attention/need.
	HostSaid(host, method string, params json.RawMessage) (any, error)
}

// Uplink is a host's line transport: its own WebSocket here, or (with several copies) a
// stream on the link to the copy that holds it.
type Uplink interface {
	Send(line string) bool
	Read(ctx context.Context) (string, error)
	Close()
}

// Router is ControlRouter.swift (058, R3): client sessions on one side, host uplinks on
// the other, and a channel on a host's uplink for every pair of them.
//
// It routes connections, not calls. A request goes down its channel as the bytes it came
// as (every paired client may ask anything, #111); whatever the host says on that
// channel goes back to that client with the host's id on it.
//
// One mutex, not an actor: every write is a queue on the socket (Conn.Send), so nothing
// waits while it is held.
type Router struct {
	mu       sync.Mutex
	handler  Handler
	homeHost string
	clients  map[string]*clientSession
	hosts    map[string]*hostSession
	known    map[string]bool
	// Hosts that only relay (T096), and whether each is relaying now: they carry devices
	// and are given no client channels, only channel 0.
	relays map[string]bool
	states map[string]hostState
	// How each client reaches this copy, as last said: true when only through the relay.
	toldLinks map[string]bool
	// Requests of a host on its channel 0 (#1122), by their id, until it answers.
	asks map[string]*hostAsk
	// Kept requests on their way to a host, by their delivery, until it answers.
	keptWaits map[string]chan *message
	// Where each session last said the person was, keyed by the session.
	presence map[string]notedPresence
	// Told when a host's real uplink here ends.
	localEnded func(host string)
	// How to reach each peer copy on its link, for streams carried for it (T064).
	peers map[string]func(string)
	// How each client connected at another copy reaches it: relayed or not (T080).
	peerLinks map[string]map[string]bool
	// Told when a client here connects, or its last session ends (nil).
	linkChanged func(client string, relayed *bool)
	// Told each presence report a client here makes.
	presenceHeard func(client string, device bool, report json.RawMessage)
	// A linked host's workspace (#691), laid over its state: a host whose workspace is
	// stopped is shown stopped, not offline.
	workspaces map[string]*providers.MachineWorkspace
	// Keeps a prompt or agent start for a stopped host (#691 US3); nil where nothing is.
	keeper keeper
	// Kept requests asked, in the order they came.
	keeping chan func()
	// Told each host's answer to a whole list (#962), for hosts/lastHeard: host, method,
	// the reply line. Nil where none is kept.
	copier func(host, method, reply string)
	// The organisation's policy's check of a call to a machine (#998): it reads only memory.
	policyGate func(host, method string) error
	// The plan's check of a call that starts another running agent (#2243): it reads only
	// memory and the hosts' own cached lists, never a host.
	agentsRunningGate func(host, method string) error
	// Told of each request a client made, for the metrics and the log (#2176), and of each
	// notification sent to clients.
	requested func(caller Caller, host, method string, id json.RawMessage, result string, took time.Duration)
	sent      func(method string, clients int)
	// Who a client is (#996): written on each channel it opens, and on each entry the
	// audit keeps. Told each call passed on or answered here, for the audit. Nil where
	// there is no audit.
	// Who owns each client and machine (#994); nil lets every client reach every host.
	owners Ownership
	// Whether the control plane has more than one person (#1763, R14), the version a build
	// from before the team tier is told to update to, and the list each host last said:
	// on a team, a client or host without the team capability is refused.
	team             bool
	version          string
	hostCapabilities map[string][]string
	actorOf          func(Caller) *wire.AuditActor
	audited          func(from Caller, host, method string, params json.RawMessage)
	log              func(string)
	generation       int64
	// Each client key's rates (#2150), and their refusals' log lines.
	rates    *clientRates
	refusals *refusalLog
}

type clientSession struct {
	caller   Caller
	conn     *Conn
	channels map[string]int
	// Set by the first wrapped line. Until then the client is today's Remote, which speaks
	// bare JSON-RPC to one daemon: the home host (R7).
	wrapped bool
	// Requests sent to each host and not answered yet, so a host that goes answers them
	// with hostOffline rather than leaving the client to wait for ever (#77).
	inFlight map[string]map[string]bool
	// Of those, the whole lists whose answer is kept for when the host is offline (#962).
	copying map[string]map[string]string
	// The capabilities the client said in its auth line (#1748); nil from one older than
	// that. Each request of a client too old for this control plane is refused.
	capabilities []string
	// The host that answers this page's calls itself (#1970), or "": the session ends when
	// the host is no longer its person's.
	carriedBy string
}

// target is who a channel on a host's uplink is for: a client session here, or the other
// end of a tunnel between two hosts (T091).
type target struct {
	session      string
	tunnelHost   string
	tunnelOthers int
	// A kept request being delivered (#691 US3, channels), waiting on its reply.
	kept string
	// A stream a peer copy carries for one of its own clients (T065), and its channel.
	peer        string
	peerChannel int
}

type hostSession struct {
	conn     Uplink
	next     int
	channels map[int]target
	// Tells this uplink from the one it replaced, so the old one ending does not take the
	// new one down with it.
	gen int64
	// The host's real uplink is here. Otherwise it is a stream to the copy that holds it.
	local bool
	// A peer's stream "peer/channel" to the channel it was given here.
	proxied map[string]int
}

type hostAsk struct {
	host  string
	reply chan *message
}

type notedPresence struct {
	client    string
	device    bool
	watching  *string
	active    bool
	heardAt   time.Time
	mayNotify *bool
}

// hostState is HostState: online, offline since a time, connecting, needsUpdate or
// failed with a reason.
type hostState struct {
	State  string
	Since  time.Time
	From   string
	To     string
	Reason string
}

func (s hostState) online() bool { return s.State == "online" }

func NewRouter(h Handler, log func(string)) *Router {
	if log == nil {
		log = func(string) {}
	}
	return &Router{handler: h, clients: map[string]*clientSession{}, hosts: map[string]*hostSession{},
		known: map[string]bool{}, relays: map[string]bool{}, states: map[string]hostState{},
		toldLinks: map[string]bool{}, asks: map[string]*hostAsk{}, keptWaits: map[string]chan *message{}, presence: map[string]notedPresence{}, log: log,
		peers: map[string]func(string){}, peerLinks: map[string]map[string]bool{},
		workspaces: map[string]*providers.MachineWorkspace{}, rates: newClientRates(), refusals: newRefusalLog(log)}
}

// MARK: What it knows

func (r *Router) SetHomeHost(h string) {
	r.mu.Lock()
	r.homeHost = h
	r.mu.Unlock()
}

// Know says a host is enrolled, online or not. Calls naming one that is not known are
// refused as noSuchHost, not hostOffline.
func (r *Router) Know(host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.known[host] {
		r.known[host] = true
		r.states[host] = hostState{State: "offline", Since: time.Now()}
	}
}

// State is where a host is, as far as the control plane knows; false for none known.
func (r *Router) State(host string) (hostState, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.states[host]
	return s, ok
}

// KnownHosts is every host the router holds a state for.
func (r *Router) KnownHosts() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for h := range r.states {
		out = append(out, h)
	}
	return out
}

// describe is ControlRouter.describe: a host's state as control/hostChanged says it.
func describe(host string, s hostState) map[string]any {
	params := map[string]any{"host": host, "state": s.State}
	switch s.State {
	case "offline":
		params["since"] = s.Since.UTC().Format(time.RFC3339)
	case "needsUpdate":
		params["from"], params["to"] = s.From, s.To
	case "failed":
		params["reason"] = s.Reason
	}
	return params
}

// Described is a host's state as hosts/list and control/hostChanged say it, with its
// workspace laid over it (#691).
func (r *Router) Described(host string) map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.describedLocked(host)
}

func (r *Router) describedLocked(host string) map[string]any {
	s, ok := r.states[host]
	if !ok {
		s = hostState{State: "offline", Since: time.Now()}
	}
	return providers.Overlay(describe(host, s), s.online(), r.workspaces[host])
}

// keeper is KeptHandling: what keeps a request for a stopped host, and is told when a
// host attaches.
type keeper interface {
	Keep(host, method string, params json.RawMessage, caller providers.Caller) *providers.Failure
	Attached(host string)
}

// SetKeeper says what keeps a prompt or a start for a stopped workspace (#691 US3).
func (r *Router) SetKeeper(k keeper) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.keeper = k
	if r.keeping == nil {
		r.keeping = make(chan func(), 256)
		go func() {
			for keep := range r.keeping {
				keep()
			}
		}()
	}
}

// Workspace is a linked host's workspace, or nil.
func (r *Router) Workspace(host string) *providers.MachineWorkspace {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.workspaces[host]
}

// SetWorkspace is ControlRouter.setWorkspace: a linked host's workspace changed (its
// state, a start's phase), or the link went; said to every client when it differs.
func (r *Router) SetWorkspace(host string, ws *providers.MachineWorkspace) {
	r.mu.Lock()
	defer r.mu.Unlock()
	old := r.workspaces[host]
	a, _ := json.Marshal(old)
	b, _ := json.Marshal(ws)
	if string(a) == string(b) {
		return
	}
	if ws == nil {
		delete(r.workspaces, host)
	} else {
		r.workspaces[host] = ws
	}
	if r.known[host] {
		r.broadcastHostLocked(host, "control/hostChanged", r.describedLocked(host))
	}
}

// TellControl tells one client session that speaks the wrapped wire; false when it has
// gone (#858).
func (r *Router) TellControl(session, method string, params any) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.clients[session]
	if s == nil || !s.wrapped {
		return false
	}
	r.writeLocked(session, wrap("", notification(method, params)))
	return r.clients[session] != nil
}

// HasSession says a client session is still here.
func (r *Router) HasSession(session string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.clients[session] != nil
}

func (r *Router) setStateLocked(host string, s hostState) {
	if old, ok := r.states[host]; ok && old.State == s.State && old.Reason == s.Reason && old.From == s.From &&
		old.To == s.To && old.Since.Equal(s.Since) {
		return
	}
	r.states[host] = s
	r.broadcastHostLocked(host, "control/hostChanged", r.describedLocked(host))
}

// Holds says this copy has the host's real uplink.
func (r *Router) Holds(host string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hosts[host] != nil && r.hosts[host].local
}

// Sessions is how many client sessions are here.
func (r *Router) Sessions() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.clients)
}

// Channels is how many channels are open on a host's uplink, for tests.
func (r *Router) Channels(host string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h := r.hosts[host]; h != nil {
		return len(h.channels)
	}
	return 0
}

// ConnectedClients is every client with a session here.
func (r *Router) ConnectedClients() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	seen := map[string]bool{}
	var out []string
	for _, s := range r.clients {
		if !seen[s.caller.Client] {
			seen[s.caller.Client] = true
			out = append(out, s.caller.Client)
		}
	}
	return out
}

// ConnectedMembers is every client and host with a session here (#997: their keys are
// in use).
func (r *Router) ConnectedMembers() []string {
	out := r.ConnectedClients()
	r.mu.Lock()
	defer r.mu.Unlock()
	for id := range r.hosts {
		out = append(out, id)
	}
	return out
}

// CloseMembers closes every client's and host's connection here, so each connects again
// (#997: and takes the control plane's new key).
func (r *Router) CloseMembers() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id := range r.clients {
		r.detachLocked(id, 0)
	}
	for _, h := range r.hosts {
		h.conn.Close()
	}
}

// SetRelay says whether a host only relays (MachineRecord.relay): nil for a host that runs
// agents, false for a relay switched off, true for one relaying. A host found to be a
// relay has its client channels closed.
func (r *Router) SetRelay(host string, relay *bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if relay == nil {
		if _, was := r.relays[host]; was {
			delete(r.relays, host)
			for id := range r.clients {
				r.openChannelLocked(id, host)
			}
		}
		return
	}
	_, was := r.relays[host]
	r.relays[host] = *relay
	if was {
		return
	}
	for _, s := range r.clients {
		if c, ok := s.channels[host]; ok {
			delete(s.channels, host)
			if h := r.hosts[host]; h != nil {
				delete(h.channels, c)
				h.conn.Send(closeFrame(c))
			}
		}
	}
}

// HostsHeldHere is every host that runs agents whose uplink ends here.
func (r *Router) HostsHeldHere() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for host, h := range r.hosts {
		if h != nil && h.local && !r.relays[host] {
			out = append(out, host)
		}
	}
	return out
}

// RelaysHeldHere is every relaying host whose uplink ends here.
func (r *Router) RelaysHeldHere() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for host, on := range r.relays {
		if on && r.hosts[host] != nil && r.hosts[host].local {
			out = append(out, host)
		}
	}
	return out
}

// RelayOnline says whether a relaying host is online anywhere: held here, or at another
// copy that this one reaches it through (#1460).
func (r *Router) RelayOnline() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for host, on := range r.relays {
		if on && r.hosts[host] != nil {
			return true
		}
	}
	return false
}

// MARK: Hosts

// AttachHost takes a host's uplink: a channel opens to it for every client session, then
// it is read until it ends.
func (r *Router) AttachHost(host string, conn Uplink) { r.attachHost(host, conn, true) }

// AttachProxy takes a stream to the copy that holds a host, as the host's uplink (058,
// US3). Its channel numbers are this copy's own. A stream that ends leaves the state
// alone: the host has usually moved, and is shown offline only if nobody holds it again
// within 5 s.
func (r *Router) AttachProxy(host string, conn Uplink) { r.attachHost(host, conn, false) }

func (r *Router) attachHost(host string, conn Uplink, local bool) {
	r.mu.Lock()
	if r.hosts[host] != nil {
		r.dropHostLocked(host, 0, nil)
	}
	r.known[host] = true
	r.generation++
	gen := r.generation
	r.hosts[host] = &hostSession{conn: conn, next: 1, channels: map[int]target{}, gen: gen, local: local,
		proxied: map[string]int{}}
	r.setStateLocked(host, hostState{State: "online"})
	for id := range r.clients {
		r.openChannelLocked(id, host)
	}
	if local && r.keeper != nil {
		k := r.keeper
		go k.Attached(host)
	}
	r.mu.Unlock()
	go func() {
		for {
			line, err := conn.Read(context.Background())
			if err != nil {
				break
			}
			r.hostLine(line, host)
		}
		r.mu.Lock()
		current := r.hosts[host] != nil && r.hosts[host].gen == gen
		if !local {
			r.dropHostLocked(host, gen, nil)
			r.mu.Unlock()
			r.offlineUnlessBack(host, 5*time.Second)
			return
		}
		r.dropHostLocked(host, gen, &hostState{State: "offline", Since: time.Now()})
		ended := r.localEnded
		r.mu.Unlock()
		if current && ended != nil {
			ended(host)
		}
	}()
}

// offlineUnlessBack shows a host offline if nobody holds it again within grace.
func (r *Router) offlineUnlessBack(host string, grace time.Duration) {
	time.Sleep(grace)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.hosts[host] == nil && r.known[host] && r.states[host].online() {
		r.setStateLocked(host, hostState{State: "offline", Since: time.Now()})
	}
}

// Reaches says the host is reachable from here at all, directly or through a peer.
func (r *Router) Reaches(host string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hosts[host] != nil
}

// CloseLocal closes a host's real uplink here: its lease went to another copy. The host
// redials.
func (r *Router) CloseLocal(host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h := r.hosts[host]; h != nil && h.local {
		r.dropHostLocked(host, 0, nil)
	}
}

// CloseStopped closes a host's real uplink here when its workspace was stopped (#1701), and
// shows it offline. A tunnel through a provider's own (gcloud's start-tcp-tunnel) can hold a
// stopped host's connection open for a minute, and a Start then took it for the new one.
func (r *Router) CloseStopped(host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h := r.hosts[host]; h != nil && h.local {
		r.dropHostLocked(host, 0, &hostState{State: "offline", Since: time.Now()})
	}
}

// MARK: Streams carried for peer copies (T065)

// SetPeer says a peer copy's link is up: streams it asks for are answered through send.
func (r *Router) SetPeer(id string, send func(string)) {
	r.mu.Lock()
	r.peers[id] = send
	r.mu.Unlock()
}

// DropPeer says a peer's link went: every stream it had open on a host here closes.
func (r *Router) DropPeer(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.peers, id)
	if gone := r.peerLinks[id]; len(gone) > 0 {
		r.broadcastControlLocked("control/clientChanged", map[string]any{})
	}
	delete(r.peerLinks, id)
	for _, h := range r.hosts {
		if !h.local {
			continue
		}
		for key, mine := range h.proxied {
			if strings.HasPrefix(key, id+"/") {
				delete(h.proxied, key)
				delete(h.channels, mine)
				h.conn.Send(closeFrame(mine))
			}
		}
	}
}

func peerKey(peer string, c int) string { return peer + "/" + strconv.Itoa(c) }

// peerFrame is PeerWire.frame: a host line with "p":"<host>" in front.
func peerFrame(host, hostLine string) string { return `{"p":"` + host + `",` + hostLine[1:] }

func (r *Router) tellPeerLocked(peer, line string) {
	if send := r.peers[peer]; send != nil {
		send(line)
	}
}

// OpenFromPeer is a peer opening a stream to a host held here: a fresh channel on the
// real uplink. This copy reads fan-out frames and hands each peer its part channel by
// channel, so the host may fan out whatever the peer is.
func (r *Router) OpenFromPeer(peer, host string, c int, open wire.ChannelOpen) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	// The peer checks its client's person too; a stream for another's machine opens nothing.
	mine := r.owners == nil || r.owners.OwnerOf(host) == r.owners.PersonOf(open.Client)
	if _, relay := r.relays[host]; relay || h == nil || !h.local || !mine {
		r.tellPeerLocked(peer, peerFrame(host, closeFrame(c)))
		return
	}
	key := peerKey(peer, c)
	if old, ok := h.proxied[key]; ok {
		delete(h.channels, old)
		h.conn.Send(closeFrame(old))
	}
	channel := h.next
	h.next++
	h.channels[channel] = target{peer: peer, peerChannel: c}
	h.proxied[key] = channel
	yes := true
	open.FanOut = &yes
	h.conn.Send(openFrame(channel, open))
}

// FromPeer is a message on a peer's stream, for the host.
func (r *Router) FromPeer(peer, host string, c int, msg string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	mine, ok := 0, false
	if h != nil && h.local {
		mine, ok = h.proxied[peerKey(peer, c)]
	}
	if !ok {
		r.tellPeerLocked(peer, peerFrame(host, closeFrame(c)))
		return
	}
	h.conn.Send(channelFrame(mine, msg))
}

// CloseFromPeer is the peer closing its stream.
func (r *Router) CloseFromPeer(peer, host string, c int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	if h == nil {
		return
	}
	if mine, ok := h.proxied[peerKey(peer, c)]; ok {
		delete(h.proxied, peerKey(peer, c))
		delete(h.channels, mine)
		h.conn.Send(closeFrame(mine))
	}
}

// HeldHere is every host whose real uplink ends here.
func (r *Router) HeldHere() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for host, h := range r.hosts {
		if h.local {
			out = append(out, host)
		}
	}
	return out
}

// NotePeerLink is a peer copy saying how one of its clients reaches it; nil: it doesn't.
func (r *Router) NotePeerLink(peer, client string, relayed *bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.peerLinks[peer] == nil {
		r.peerLinks[peer] = map[string]bool{}
	}
	if relayed == nil {
		delete(r.peerLinks[peer], client)
	} else {
		r.peerLinks[peer][client] = *relayed
	}
	r.broadcastControlLocked("control/clientChanged", map[string]any{"client": client})
}

// LinksHere is every client connected here, as it was said: for a peer that just linked.
func (r *Router) LinksHere() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	for k, v := range r.toldLinks {
		out[k] = v
	}
	return out
}

// OnLinkChanged is told when a client here connects (its relayed), or its last session
// ends (nil), so other copies know.
func (r *Router) OnLinkChanged(f func(client string, relayed *bool)) {
	r.mu.Lock()
	r.linkChanged = f
	r.mu.Unlock()
}

// OnPresence is told each presence report a client here makes, so other copies fold it.
func (r *Router) OnPresence(f func(client string, device bool, report json.RawMessage)) {
	r.mu.Lock()
	r.presenceHeard = f
	r.mu.Unlock()
}

// NotePeerPresence is a presence report made at another copy, folded here as the
// client's own.
func (r *Router) NotePeerPresence(client string, device bool, report json.RawMessage) {
	var p wire.PresenceReport
	if json.Unmarshal(report, &p) != nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	previous := r.presence[client]
	may := p.MayNotify
	if may == nil {
		may = previous.mayNotify
	}
	r.presence[client] = notedPresence{client: client, device: device, watching: (*string)(p.Watching), active: p.Active,
		heardAt: time.Now(), mayNotify: may}
}

// OnLocalEnded is told when a host's real uplink here ends.
func (r *Router) OnLocalEnded(f func(string)) {
	r.mu.Lock()
	r.localEnded = f
	r.mu.Unlock()
}

// ForgetHost is hosts/remove (FR-014): its uplink closes and it is forgotten. Its agents
// are left as they are.
func (r *Router) ForgetHost(host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dropHostLocked(host, 0, nil)
	r.broadcastHostLocked(host, "control/hostChanged", map[string]any{"host": host, "state": "removed"})
	delete(r.known, host)
	delete(r.states, host)
}

func (r *Router) dropHostLocked(host string, gen int64, newState *hostState) {
	h := r.hosts[host]
	if h == nil || (gen != 0 && h.gen != gen) {
		return
	}
	delete(r.hosts, host)
	h.conn.Close()
	var bareGone []string
	for _, t := range h.channels {
		switch {
		case t.session != "":
			s := r.clients[t.session]
			if s == nil {
				continue
			}
			delete(s.channels, host)
			waiting := s.inFlight[host]
			delete(s.inFlight, host)
			delete(s.copying, host)
			// What was asked of it is answered, not lost (#77).
			for id := range waiting {
				r.writeLocked(t.session, s.wrap(host, replyError(json.RawMessage(id), fail(hostOffline, "That machine went offline before it answered."))))
			}
			// A bare-wire client (the Remote) talks to the home host's daemon and hears
			// nothing else. Its connection ends, so it reconnects and reads everything
			// afresh.
			if !s.wrapped && host == r.homeHost {
				bareGone = append(bareGone, t.session)
			}
		case t.kept != "":
			// Not answered: it stays kept for the next time the host is up.
			r.endKeptLocked(t.kept, nil)
		case t.peer != "":
			// The peer hears the host is gone once, from the lease's release, as "gone":
			// its clients keep their sockets, and what they asked is answered hostOffline
			// there. (Swift also closes each channel, which ends those clients' sockets.)
		case t.tunnelHost != "":
			// A tunnel ends at both hosts with either.
			if other := r.hosts[t.tunnelHost]; other != nil {
				delete(other.channels, t.tunnelOthers)
				other.conn.Send(closeFrame(t.tunnelOthers))
			}
		}
	}
	if newState != nil {
		r.setStateLocked(host, *newState)
	}
	for _, id := range bareGone {
		r.detachLocked(id, 0)
	}
	for id, ask := range r.asks {
		if ask.host == host {
			delete(r.asks, id)
			close(ask.reply)
		}
	}
}

func (s *clientSession) wrap(host, msg string) string {
	if !s.wrapped {
		return msg
	}
	return wrap(host, msg)
}

// wrap is ControlWire.wrap: {"h":<host>,"m":<message>}, or {"m":…} for the control plane.
func wrap(host, msg string) string {
	if host == "" {
		return `{"m":` + msg + `}`
	}
	return `{"h":"` + host + `","m":` + msg + `}`
}

func channelFrame(c int, msg string) string { return `{"c":` + strconv.Itoa(c) + `,"m":` + msg + `}` }
func closeFrame(c int) string               { return `{"c":` + strconv.Itoa(c) + `,"close":true}` }

// openFrame opens a channel as ControlWire.ChannelOpen says.
func openFrame(c int, open wire.ChannelOpen) string {
	b, _ := json.Marshal(open)
	return `{"c":` + strconv.Itoa(c) + `,"open":` + string(b) + `}`
}

// hostFrame is ControlWire.HostFrame: a line on a host's uplink, taken apart.
type hostFrame struct {
	channel  int
	channels []int
	msg      string
	close    bool
	open     bool
}

// readHostFrame is ControlWire.readHost. Lines this side writes put m last, so the fast
// path finds where it starts; anything else is parsed whole.
func readHostFrame(line string) (hostFrame, bool) {
	if strings.HasPrefix(line, `{"f":[`) && strings.HasSuffix(line, "}") {
		if end := strings.IndexByte(line, ']'); end > 0 && strings.HasPrefix(line[end+1:], `,"m":`) {
			var chans []int
			ok := true
			for _, p := range strings.Split(line[6:end], ",") {
				n, err := strconv.Atoi(p)
				if err != nil || n <= 0 {
					ok = false
					break
				}
				chans = append(chans, n)
			}
			if ok {
				return hostFrame{channels: chans, msg: line[end+6 : len(line)-1]}, true
			}
		}
	}
	if strings.HasPrefix(line, `{"c":`) && strings.HasSuffix(line, "}") {
		rest := line[5:]
		i := 0
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			i++
		}
		if i > 0 && strings.HasPrefix(rest[i:], `,"m":`) {
			n, _ := strconv.Atoi(rest[:i])
			return hostFrame{channel: n, msg: rest[i+5 : len(rest)-1]}, true
		}
	}
	var o map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &o) != nil {
		return hostFrame{}, false
	}
	if f, ok := o["f"]; ok {
		var chans []int
		if json.Unmarshal(f, &chans) != nil || o["m"] == nil {
			return hostFrame{}, false
		}
		for _, c := range chans {
			if c <= 0 {
				return hostFrame{}, false
			}
		}
		return hostFrame{channels: chans, msg: string(o["m"])}, true
	}
	var c int
	if json.Unmarshal(o["c"], &c) != nil || c < 0 {
		return hostFrame{}, false
	}
	if m, ok := o["m"]; ok {
		return hostFrame{channel: c, msg: string(m)}, true
	}
	if _, ok := o["open"]; ok {
		return hostFrame{channel: c, open: true}, true
	}
	if string(o["close"]) == "true" {
		return hostFrame{channel: c, close: true}, true
	}
	return hostFrame{}, false
}

func (r *Router) hostLine(line, host string) {
	f, ok := readHostFrame(line)
	// Only the control plane opens channels. A host that tries is ignored.
	if !ok || f.open {
		return
	}
	if f.channels != nil {
		r.fanOut(f.msg, f.channels, host)
		return
	}
	if f.channel == 0 && !f.close {
		// A git command waits on a person's answer (#1122): the host's other lines go on.
		if strings.Contains(f.msg, `"git/credential"`) {
			go r.channelZero(f.msg, host)
		} else {
			r.channelZero(f.msg, host)
		}
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	if h == nil {
		return
	}
	t, ok := h.channels[f.channel]
	if !ok {
		return
	}
	if f.close {
		// The host hung up on a client (a device it was told to forget, say): the
		// client's whole connection goes, as it would have today.
		delete(h.channels, f.channel)
		if t.kept != "" {
			r.endKeptLocked(t.kept, nil)
		} else if t.peer != "" {
			delete(h.proxied, peerKey(t.peer, t.peerChannel))
			r.tellPeerLocked(t.peer, peerFrame(host, closeFrame(t.peerChannel)))
		} else if t.session != "" {
			r.detachLocked(t.session, 0)
		} else if other := r.hosts[t.tunnelHost]; other != nil {
			delete(other.channels, t.tunnelOthers)
			other.conn.Send(closeFrame(t.tunnelOthers))
		}
		return
	}
	if t.peer != "" {
		r.tellPeerLocked(t.peer, peerFrame(host, channelFrame(t.peerChannel, f.msg)))
		return
	}
	if t.kept != "" {
		// A kept request's reply ends its channel; anything else said there is for nobody.
		if m, ok := decode(f.msg); ok && m.Method == "" && (m.Result != nil || m.Error != nil) {
			delete(h.channels, f.channel)
			h.conn.Send(closeFrame(f.channel))
			r.endKeptLocked(t.kept, m)
		}
		return
	}
	if t.tunnelHost != "" {
		// A tunnel's bytes go to the other host as they came, never read.
		if other := r.hosts[t.tunnelHost]; other != nil {
			other.conn.Send(channelFrame(t.tunnelOthers, f.msg))
		}
		return
	}
	s := r.clients[t.session]
	if s == nil {
		return
	}
	// Read only while something waits on this host, and only for its id: the line goes on
	// as it came.
	if len(s.inFlight[host]) > 0 {
		if id := answeredID(f.msg); id != "" {
			delete(s.inFlight[host], id)
			if method, ok := s.copying[host][id]; ok {
				delete(s.copying[host], id)
				if r.copier != nil {
					go r.copier(host, method, f.msg)
				}
			}
		}
	}
	if s.wrapped {
		r.writeLocked(t.session, wrap(host, f.msg))
	} else if host == r.homeHost {
		r.writeLocked(t.session, f.msg)
	}
}

// fanOut is a host's broadcast said once for every channel named (#167), copied here to
// each one's client, wrapped once for them all.
func (r *Router) fanOut(msg string, channels []int, host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	if h == nil {
		return
	}
	wrapped := ""
	for _, c := range channels {
		t, ok := h.channels[c]
		if ok && t.peer != "" {
			// Channel by channel, which a copy of any age reads.
			r.tellPeerLocked(t.peer, peerFrame(host, channelFrame(t.peerChannel, msg)))
			continue
		}
		if !ok || t.session == "" {
			continue
		}
		s := r.clients[t.session]
		if s == nil {
			continue
		}
		if s.wrapped {
			if wrapped == "" {
				wrapped = wrap(host, msg)
			}
			r.writeLocked(t.session, wrapped)
		} else if host == r.homeHost {
			r.writeLocked(t.session, msg)
		}
	}
}

func (r *Router) channelZero(msg, host string) {
	m, ok := decode(msg)
	if !ok {
		return
	}
	if !m.isRequest() && m.Method == "" {
		// A reply to something the control plane asked of the host (#1122).
		var id string
		if json.Unmarshal(m.ID, &id) == nil {
			r.mu.Lock()
			ask := r.asks[id]
			if ask != nil && ask.host == host {
				delete(r.asks, id)
				ask.reply <- m
			}
			r.mu.Unlock()
		}
		return
	}
	if !m.isRequest() {
		return
	}
	result, err := r.handler.HostSaid(host, m.Method, m.Params)
	line := ""
	if err != nil {
		line = replyError(m.ID, err)
	} else {
		line = reply(m.ID, result)
	}
	r.mu.Lock()
	if h := r.hosts[host]; h != nil {
		h.conn.Send(channelFrame(0, line))
	}
	r.mu.Unlock()
}

// Tell sends a notification on a host's channel 0, when its uplink ends here.
func (r *Router) Tell(host, method string, params any) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	return h != nil && h.local && h.conn.Send(channelFrame(0, notification(method, params)))
}

// Ask is a request of a host on its channel 0, which only the control plane writes, and
// its reply. Nil when the host is not here, goes before it answers, or takes longer than
// patience (#1122).
func (r *Router) Ask(host, method string, params any, patience time.Duration) *message {
	r.mu.Lock()
	h := r.hosts[host]
	if h == nil || !h.local {
		r.mu.Unlock()
		return nil
	}
	id := "ask-" + records.NewUUID()
	ask := &hostAsk{host: host, reply: make(chan *message, 1)}
	r.asks[id] = ask
	if !h.conn.Send(channelFrame(0, request(id, method, params))) {
		delete(r.asks, id)
		r.mu.Unlock()
		return nil
	}
	r.mu.Unlock()
	select {
	case m, ok := <-ask.reply:
		if !ok {
			return nil
		}
		return m
	case <-time.After(patience):
		r.mu.Lock()
		delete(r.asks, id)
		r.mu.Unlock()
		return nil
	}
}

// DeliverKept is ControlRouter.deliverKept: a request to a host on a channel of its own,
// bound to the client that asked, and its reply. Nil when the host is not here, goes
// before it answers, or takes longer than patience: the request stays kept.
func (r *Router) DeliverKept(method string, params any, client, kind, host string, patience time.Duration) *message {
	r.mu.Lock()
	h := r.hosts[host]
	if _, relay := r.relays[host]; relay || h == nil {
		r.mu.Unlock()
		return nil
	}
	delivery := records.NewUUID()
	c := h.next
	h.next++
	h.channels[c] = target{kept: delivery}
	open := wire.ChannelOpen{Client: client}
	if kind != records.KindMac {
		open.Device = new(wire.UUID(client))
	}
	wait := make(chan *message, 1)
	r.keptWaits[delivery] = wait
	if !h.conn.Send(openFrame(c, open)) || !h.conn.Send(channelFrame(c, request("kept-"+delivery, method, params))) {
		delete(h.channels, c)
		delete(r.keptWaits, delivery)
		r.mu.Unlock()
		return nil
	}
	r.mu.Unlock()
	select {
	case m := <-wait:
		return m
	case <-time.After(patience):
		r.mu.Lock()
		if h := r.hosts[host]; h != nil {
			if _, open := h.channels[c]; open {
				delete(h.channels, c)
				h.conn.Send(closeFrame(c))
			}
		}
		delete(r.keptWaits, delivery)
		r.mu.Unlock()
		return nil
	}
}

func (r *Router) endKeptLocked(delivery string, m *message) {
	if wait, ok := r.keptWaits[delivery]; ok {
		delete(r.keptWaits, delivery)
		wait <- m
	}
}

// MARK: Clients

// AttachClient takes a paired client's socket, and returns its session, which ends when
// the socket does.
func (r *Router) AttachClient(client *records.ClientRecord, conn *Conn, relayed bool, capabilities []string) string {
	id := records.NewUUID()
	r.mu.Lock()
	person := ""
	if r.owners != nil {
		person = r.owners.PersonOf(client.ID)
	}
	r.clients[id] = &clientSession{caller: Caller{Session: id, Client: client.ID, Kind: client.Kind, Relayed: relayed, Person: person},
		conn: conn, channels: map[string]int{}, inFlight: map[string]map[string]bool{},
		copying: map[string]map[string]string{}, capabilities: capabilities}
	for host := range r.hosts {
		r.openChannelLocked(id, host)
	}
	r.noteLinkLocked(client.ID)
	r.mu.Unlock()
	go func() {
		for {
			line, err := conn.Read(context.Background())
			if err != nil {
				break
			}
			r.clientLine(line, id)
		}
		r.mu.Lock()
		r.detachLocked(id, 0)
		r.mu.Unlock()
	}()
	return id
}

// ForgottenCloseCode is what a forgotten client's sockets end with (071 browser-auth.md).
const ForgottenCloseCode = 4403

// detachLocked ends a session: its channels are closed on every host, then its socket.
func (r *Router) detachLocked(id string, code websocket.StatusCode) {
	r.detachReasonLocked(id, code, "forgotten")
}

func (r *Router) detachReasonLocked(id string, code websocket.StatusCode, reason string) {
	s := r.clients[id]
	if s == nil {
		return
	}
	delete(r.clients, id)
	delete(r.presence, id)
	for host, c := range s.channels {
		if h := r.hosts[host]; h != nil {
			delete(h.channels, c)
			h.conn.Send(closeFrame(c))
		}
	}
	if code != 0 {
		s.conn.CloseWith(code, reason)
	} else {
		s.conn.Close()
	}
	r.noteLinkLocked(s.caller.Client)
}

// CutOffPerson ends every session of a suspended person here, each told why with 4403
// suspended (#1002, D13). Their clients keep their records and keys.
func (r *Router) CutOffPerson(person string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, s := range r.clients {
		if s.caller.Person == person {
			r.detachReasonLocked(id, ForgottenCloseCode, "suspended")
		}
	}
}

// ForgetClient ends every session of a forgotten client, each told why with 4403.
func (r *Router) ForgetClient(client string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, s := range r.clients {
		if strings.EqualFold(s.caller.Client, client) {
			r.detachLocked(id, ForgottenCloseCode)
		}
	}
}

// noteLinkLocked says a client's link changed here: true when it reaches this copy only
// through the relay, gone when its last session ended.
func (r *Router) noteLinkLocked(client string) {
	present, allRelayed := false, true
	for _, s := range r.clients {
		if s.caller.Client == client {
			present = true
			allRelayed = allRelayed && s.caller.Relayed
		}
	}
	was, had := r.toldLinks[client]
	if present == had && (!present || was == allRelayed) {
		return
	}
	if present {
		r.toldLinks[client] = allRelayed
	} else {
		delete(r.toldLinks, client)
	}
	if r.linkChanged != nil {
		var relayed *bool
		if present {
			relayed = &allRelayed
		}
		go r.linkChanged(client, relayed)
	}
	r.broadcastControlLocked("control/clientChanged", map[string]any{"client": client})
}

// Connections is how every connected client reaches the control plane: true when only
// through the relay.
func (r *Router) Connections() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	note := func(client string, relayed bool) {
		was, ok := out[client]
		out[client] = (!ok || was) && relayed
	}
	for _, links := range r.peerLinks {
		for client, relayed := range links {
			note(client, relayed)
		}
	}
	for k, v := range r.toldLinks {
		note(k, v)
	}
	return out
}

func (r *Router) openChannelLocked(sessionID, host string) {
	s := r.clients[sessionID]
	h := r.hosts[host]
	if s == nil || h == nil {
		return
	}
	if _, relay := r.relays[host]; relay {
		return
	}
	if !r.mayReachLocked(s.caller, host) {
		return
	}
	r.openReachedLocked(sessionID, host)
}

func (r *Router) relayLocked(host string) bool {
	_, relay := r.relays[host]
	return relay
}

// openReachedLocked is openChannelLocked for a session already known to reach the host.
func (r *Router) openReachedLocked(sessionID, host string) {
	s, h := r.clients[sessionID], r.hosts[host]
	c := h.next
	h.next++
	h.channels[c] = target{session: sessionID}
	s.channels[host] = c
	// Bound to the client unless it is a Mac's window, which is the Mac, as a window on
	// the socket is: presence is reported as it, and it names no other device.
	yes := true
	open := wire.ChannelOpen{Client: s.caller.Client, FanOut: &yes}
	if s.caller.Kind != records.KindMac {
		open.Device = new(wire.UUID(s.caller.Client))
	}
	if s.caller.Relayed {
		open.Relayed = &yes
	}
	if r.actorOf != nil {
		open.Actor = r.actorOf(s.caller)
	}
	h.conn.Send(openFrame(c, open))
}

const (
	frameBad = iota
	frameControl
	frameHost
)

// readClientFrame is ControlWire.readClient.
func readClientFrame(line string) (host, msg string, kind int) {
	if strings.HasPrefix(line, `{"m":`) && strings.HasSuffix(line, "}") {
		return "", line[5 : len(line)-1], frameControl
	}
	if strings.HasPrefix(line, `{"h":"`) {
		rest := line[6:]
		if q := strings.IndexByte(rest, '"'); q > 0 && strings.HasPrefix(rest[q+1:], `,"m":`) && strings.HasSuffix(line, "}") && controllink.IsHostID(rest[:q]) {
			return rest[:q], rest[q+6 : len(rest)-1], frameHost
		}
	}
	var o map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &o) != nil {
		return "", "", frameBad
	}
	m, ok := o["m"]
	if !ok {
		return "", "", frameBad
	}
	h, ok := o["h"]
	if !ok || string(h) == "null" {
		return "", string(m), frameControl
	}
	if json.Unmarshal(h, &host) != nil || !controllink.IsHostID(host) {
		return "", "", frameBad
	}
	return host, string(m), frameHost
}

func (r *Router) clientLine(line, sessionID string) {
	host, msg, kind := readClientFrame(line)
	if r.refusedRate(sessionID, host, line, msg, kind) || kind != frameBad && r.refusedOld(sessionID, host, msg) {
		return
	}
	switch kind {
	case frameBad:
		// JSON-RPC's answer to a request it cannot read is a parse error with no id, so
		// the client fails what it has in flight (#93). It goes back on the route the line
		// named, when it named one.
		r.mu.Lock()
		if s := r.clients[sessionID]; s != nil {
			r.log("control: unreadable line from client " + sessionID)
			var o map[string]json.RawMessage
			json.Unmarshal([]byte(line), &o)
			named := ""
			if raw, ok := o["h"]; ok {
				if json.Unmarshal(raw, &named) != nil || !controllink.IsHostID(named) {
					named = ""
				}
			}
			_, hasM := o["m"]
			_, hasH := o["h"]
			e := replyError(nil, fail(parseError, "The control plane could not read that message."))
			if s.wrapped || hasM || hasH {
				e = wrap(named, e)
			}
			r.writeLocked(sessionID, e)
		}
		r.mu.Unlock()
	case frameControl:
		r.mu.Lock()
		if s := r.clients[sessionID]; s != nil {
			s.wrapped = true
		}
		r.mu.Unlock()
		r.toControl(msg, sessionID, true)
	case frameHost:
		r.mu.Lock()
		if s := r.clients[sessionID]; s != nil {
			s.wrapped = true
		}
		r.toHostLocked(host, msg, sessionID)
		r.mu.Unlock()
	}
}

func (r *Router) toHostLocked(host, msg, sessionID string) {
	s := r.clients[sessionID]
	if s == nil {
		return
	}
	m, ok := decode(msg)
	if !ok {
		// Unreadable, so nobody can say what it asks: it goes nowhere.
		return
	}
	if !m.isRequest() {
		// A notification, or an answer to something the host asked this client.
		if c, ok := s.channels[host]; ok {
			if h := r.hosts[host]; h != nil {
				h.conn.Send(channelFrame(c, msg))
			}
		}
		return
	}
	if m.Method == "presence/report" {
		var p wire.PresenceReport
		if json.Unmarshal(m.Params, &p) == nil {
			previous := r.presence[sessionID]
			may := p.MayNotify
			if may == nil {
				may = previous.mayNotify
			}
			device := s.caller.Kind != records.KindMac && s.caller.Kind != records.KindBrowser
			r.presence[sessionID] = notedPresence{client: s.caller.Client, device: device, watching: (*string)(p.Watching),
				active: p.Active, heardAt: time.Now(), mayNotify: may}
			if r.presenceHeard != nil {
				go r.presenceHeard(s.caller.Client, device, m.Params)
			}
		}
	}
	// A bot's machine is the bot's alone: an admin, who may know it is there, is told so
	// (#1761, FR-031); bots/stopRun is the one way to act on it.
	if bots, ok := r.owners.(botOwners); ok && r.known[host] && bots.BotMachineFor(s.caller.Person, host) {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(botMachine, "That machine is a bot's: only its workflows start work there. An admin can stop a run."))))
		r.noteLocked(s.caller, host, m, "refused")
		return
	}
	// Another user's machine is not found, as one that is not there (FR-018).
	if !r.known[host] || !r.mayReachLocked(s.caller, host) {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(noSuchHost, "No machine is called %s.", host))))
		r.noteLocked(s.caller, host, m, "refused")
		return
	}
	// A host from before the team tier, on a team, would act for every person (R14).
	if list, known := r.hostCapabilities[host]; known {
		if refusal := hostRefusal(list, r.version, r.team); refusal != nil {
			r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, refusal)))
			return
		}
	}
	// A machine that does not follow the policy starts no work when it says so (#998).
	if r.policyGate != nil {
		if refusal := r.policyGate(host, m.Method); refusal != nil {
			r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, refusal)))
			r.noteLocked(s.caller, host, m, "refused")
			return
		}
	}
	// At the plan's limit on agents running at once, starting one more is refused;
	// nothing running is stopped (#2243).
	if r.agentsRunningGate != nil {
		if refusal := r.agentsRunningGate(host, m.Method); refusal != nil {
			r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, refusal)))
			r.noteLocked(s.caller, host, m, "refused")
			return
		}
	}
	c, ok := s.channels[host]
	h := r.hosts[host]
	if !ok || h == nil {
		refusal := providers.OfflineRefusal(r.workspaces[host])
		// A prompt or a start for a stopped workspace may be kept, and start it (#691 US3).
		if r.keeper != nil && providers.KeptMethods[m.Method] {
			if r.audited != nil {
				r.audited(s.caller, host, m.Method, m.Params)
			}
			k, caller, id, wrapped, method, params := r.keeper, s.caller, m.ID, s.wrapped, m.Method, m.Params
			r.keeping <- func() {
				answer := k.Keep(host, method, params, providersCaller(caller))
				var err error = refusal
				if answer != nil {
					err = answer
				}
				line := replyError(id, err)
				if wrapped {
					line = wrap(host, line)
				}
				r.mu.Lock()
				r.writeLocked(sessionID, line)
				r.mu.Unlock()
			}
			return
		}
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, refusal)))
		return
	}
	if !h.conn.Send(channelFrame(c, msg)) {
		// An uplink that has ended but is not yet dropped takes nothing: said, not lost (#62).
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(hostOffline, "That machine is offline."))))
		r.noteLocked(s.caller, host, m, "offline")
		return
	}
	r.noteLocked(s.caller, host, m, "routed")
	if s.inFlight[host] == nil {
		s.inFlight[host] = map[string]bool{}
	}
	s.inFlight[host][idKey(m.ID)] = true
	if r.audited != nil {
		r.audited(s.caller, host, m.Method, m.Params)
	}
	if r.copier != nil && keepsList(m.Method, m.Params) {
		if s.copying[host] == nil {
			s.copying[host] = map[string]string{}
		}
		s.copying[host][idKey(m.ID)] = m.Method
	}
}

// SetOwnership says who owns each client and machine (#994). Sessions already here are
// held to it at once.
func (r *Router) SetOwnership(o Ownership) {
	r.mu.Lock()
	r.owners = o
	r.mu.Unlock()
	r.HoldToOwners()
}

// MayReach says a caller may reach a machine: it is their person's (FR-018).
func (r *Router) MayReach(from Caller, host string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.mayReachLocked(from, host)
}

func (r *Router) mayReachLocked(from Caller, host string) bool {
	return r.owners == nil || r.owners.OwnerOf(host) == from.Person
}

// ServesItself says whether a host may answer a person's page itself (#1970): one this
// router knows, and the person's own (FR-018).
func (r *Router) ServesItself(person, host string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.known[host] && r.mayReachLocked(Caller{Person: person}, host)
}

// NoteCarried says a host answers a session's calls itself (#1970), so the session ends
// once the host is not its person's: at once, if it changed hands meanwhile.
func (r *Router) NoteCarried(session, host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.clients[session]
	if s == nil {
		return
	}
	if !r.mayReachLocked(s.caller, host) {
		r.detachLocked(session, 0)
		return
	}
	s.carriedBy = host
}

// HoldToOwners opens a channel to each machine a session's person owns now, and closes
// the one to each it no longer owns: after a join is approved, or a machine changes hands.
// Each machine's owner is read once, outside the lock, as each read takes the records'
// lock; under it, each session looks only at its own channels and its person's machines,
// not every machine (#2059).
func (r *Router) HoldToOwners() {
	r.mu.Lock()
	owners := r.owners
	hosts := make([]string, 0, len(r.hosts))
	for host := range r.hosts {
		if _, relay := r.relays[host]; !relay {
			hosts = append(hosts, host)
		}
	}
	r.mu.Unlock()
	ownerOf := make(map[string]string, len(hosts))
	byOwner := map[string][]string{}
	for _, host := range hosts {
		owner := ""
		if owners != nil {
			owner = owners.OwnerOf(host)
		}
		ownerOf[host] = owner
		byOwner[owner] = append(byOwner[owner], host)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.owners != owners {
		// SetOwnership ran meanwhile, and holds every session to its own.
		return
	}
	for id, s := range r.clients {
		person := s.caller.Person
		if owners == nil {
			person = ""
		}
		// A page its host answers itself is that host's person's alone (#1970).
		if owner, read := ownerOf[s.carriedBy]; s.carriedBy != "" && read && owner != person {
			r.detachLocked(id, 0)
			continue
		}
		for host, c := range s.channels {
			owner, read := ownerOf[host]
			if !read {
				// A machine that came after the read: its channels were opened as it came.
				continue
			}
			if owner != person {
				if h := r.hosts[host]; h != nil {
					delete(h.channels, c)
					h.conn.Send(closeFrame(c))
				}
				delete(s.channels, host)
			}
		}
		for _, host := range byOwner[person] {
			if _, has := s.channels[host]; !has && r.hosts[host] != nil && !r.relayLocked(host) {
				r.openReachedLocked(id, host)
			}
		}
	}
}

// TellPerson tells every session of a person here what only they are told.
func (r *Router) TellPerson(person, method string, params any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	line := wrap("", notification(method, params))
	sent := 0
	for id, s := range r.clients {
		if s.wrapped && s.caller.Person == person {
			r.writeLocked(id, line)
			sent++
		}
	}
	if r.sent != nil {
		r.sent(method, sent)
	}
}

// broadcastHostLocked tells a machine's change only to the sessions that reach it.
func (r *Router) broadcastHostLocked(host, method string, params any) {
	line := wrap("", notification(method, params))
	sent := 0
	for id, s := range r.clients {
		if s.wrapped && r.mayReachLocked(s.caller, host) {
			r.writeLocked(id, line)
			sent++
		}
	}
	if r.sent != nil {
		r.sent(method, sent)
	}
}

// BroadcastHost is broadcastHostLocked.
func (r *Router) BroadcastHost(host, method string, params any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.broadcastHostLocked(host, method, params)
}

// SetAudit says who each client is, and where each call goes for the audit (#996).
// audited must not wait: the router holds its lock while it is told.
func (r *Router) SetAudit(actorOf func(Caller) *wire.AuditActor, audited func(from Caller, host, method string, params json.RawMessage)) {
	r.mu.Lock()
	r.actorOf, r.audited = actorOf, audited
	r.mu.Unlock()
}

// SetRequested says what is told of each request a client made, and how it ended (#2176).
func (r *Router) SetRequested(f func(caller Caller, host, method string, id json.RawMessage, result string, took time.Duration)) {
	r.mu.Lock()
	r.requested = f
	r.mu.Unlock()
}

// SetSent says what is told of each notification sent to clients (#2176).
func (r *Router) SetSent(f func(method string, clients int)) {
	r.mu.Lock()
	r.sent = f
	r.mu.Unlock()
}

// noteLocked tells requested of a request to a machine, if it is one.
func (r *Router) noteLocked(caller Caller, host string, m *message, result string) {
	if r.requested != nil && m.isRequest() {
		r.requested(caller, host, m.Method, m.ID, result, 0)
	}
}

// SetPolicyGate says what checks each call to a machine against the policy (#998).
func (r *Router) SetPolicyGate(gate func(host, method string) error) {
	r.mu.Lock()
	r.policyGate = gate
	r.mu.Unlock()
}

// SetAgentsRunningGate says what checks each call that starts another running agent
// against the plan's limit (#2243).
func (r *Router) SetAgentsRunningGate(gate func(host, method string) error) {
	r.mu.Lock()
	r.agentsRunningGate = gate
	r.mu.Unlock()
}

// SetCopier says where each host's answer to a whole list goes (#962).
func (r *Router) SetCopier(f func(host, method, reply string)) {
	r.mu.Lock()
	r.copier = f
	r.mu.Unlock()
}

// toControl answers on its own goroutine: hosts/install takes minutes, and nothing else
// this client says may wait behind it.
func (r *Router) toControl(msg, sessionID string, wrapped bool) {
	m, ok := decode(msg)
	if !ok || !m.isRequest() {
		return
	}
	r.mu.Lock()
	s := r.clients[sessionID]
	audited := r.audited
	r.mu.Unlock()
	if s == nil {
		return
	}
	caller := s.caller
	requested := r.requested
	go func() {
		start := time.Now()
		result, err := r.handler.Handle(m.Method, m.Params, caller)
		if requested != nil {
			outcome := "ok"
			if err != nil {
				outcome = "error"
			}
			requested(caller, "", m.Method, m.ID, outcome, max(time.Since(start), time.Nanosecond))
		}
		line := ""
		if err != nil {
			line = replyError(m.ID, err)
		} else {
			line = reply(m.ID, result)
			if audited != nil {
				audited(caller, "", m.Method, m.Params)
			}
		}
		if wrapped {
			line = wrap("", line)
		}
		r.mu.Lock()
		r.writeLocked(sessionID, line)
		r.mu.Unlock()
	}()
}

func (r *Router) writeLocked(sessionID, line string) {
	s := r.clients[sessionID]
	if s == nil {
		return
	}
	if !s.conn.Send(line) {
		r.detachLocked(sessionID, 0)
	}
}

// BroadcastControl tells every client that speaks the wrapped wire.
func (r *Router) BroadcastControl(method string, params any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.broadcastControlLocked(method, params)
}

// BroadcastControlEach tells every client session a control notification of its person's
// own (#1761): params is asked once per person.
func (r *Router) BroadcastControlEach(method string, params func(person string) any) {
	r.mu.Lock()
	persons := map[string]bool{}
	for _, s := range r.clients {
		if s.wrapped {
			persons[s.caller.Person] = true
		}
	}
	r.mu.Unlock()
	// Asked outside the lock: it reads records and the providers.
	lines := map[string]string{}
	for person := range persons {
		lines[person] = wrap("", notification(method, params(person)))
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	sent := 0
	for id, s := range r.clients {
		if line, ok := lines[s.caller.Person]; ok && s.wrapped {
			r.writeLocked(id, line)
			sent++
		}
	}
	if r.sent != nil {
		r.sent(method, sent)
	}
}

func (r *Router) broadcastControlLocked(method string, params any) {
	line := wrap("", notification(method, params))
	sent := 0
	for id, s := range r.clients {
		if s.wrapped {
			r.writeLocked(id, line)
			sent++
		}
	}
	if r.sent != nil {
		r.sent(method, sent)
	}
}

// FoldedPresences is every client's presence, folded as a daemon folds its own: one per
// surface, an active one beating a later quiet one (058, R6). A Mac's window is the Mac.
func (r *Router) FoldedPresences() map[notices.Surface]notices.Presence {
	r.mu.Lock()
	defer r.mu.Unlock()
	folded := map[notices.Surface]notices.Presence{}
	for _, note := range r.presence {
		surface := notices.Mac
		if note.device {
			surface = notices.Surface{Device: note.client}
		}
		p := notices.Presence{Surface: surface, Active: note.active, HeardAt: note.heardAt}
		if note.watching != nil {
			p.Watching = strings.ToUpper(*note.watching)
		}
		if held, ok := folded[surface]; ok {
			better := p.HeardAt.After(held.HeardAt)
			if p.Active != held.Active {
				better = p.Active
			}
			if !better {
				continue
			}
		}
		folded[surface] = p
	}
	return folded
}

// NotifyFlags is what each device last said about showing a notification, where it said.
func (r *Router) NotifyFlags() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	flags := map[string]bool{}
	at := map[string]time.Time{}
	for _, note := range r.presence {
		if note.mayNotify == nil {
			continue
		}
		if held, ok := at[note.client]; ok && held.After(note.heardAt) {
			continue
		}
		flags[note.client], at[note.client] = *note.mayNotify, note.heardAt
	}
	return flags
}

// MARK: Tunnels between hosts (T091)

// OpenTunnel joins a channel on each of two hosts, for a sign-in lender relays to
// borrower, which asked with ref: what one sends on its end reaches the other untouched.
// Either end closing, or either host going, closes both. False when either host is not
// here.
func (r *Router) OpenTunnel(borrower, lender, runtime, ref string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	near, far := r.hosts[borrower], r.hosts[lender]
	if borrower == lender || near == nil || far == nil {
		return false
	}
	nc, fc := near.next, far.next
	near.next++
	far.next++
	near.channels[nc] = target{tunnelHost: lender, tunnelOthers: fc}
	far.channels[fc] = target{tunnelHost: borrower, tunnelOthers: nc}
	far.conn.Send(openFrame(fc, wire.ChannelOpen{Client: "tunnel:" + borrower, Tunnel: &runtime}))
	near.conn.Send(openFrame(nc, wire.ChannelOpen{Client: "tunnel:" + lender, Tunnel: &runtime, TunnelRef: &ref}))
	return true
}
