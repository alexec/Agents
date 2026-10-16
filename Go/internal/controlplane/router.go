package controlplane

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Caller is ControlRouter.Caller: who is calling, as the control plane's own methods
// need to know.
type Caller struct {
	Session string
	Client  string
	Kind    string
	// The device came through agents-relay (T096), not straight here.
	Relayed bool
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
	// Where each session last said the person was, keyed by the session.
	presence map[string]notedPresence
	// Told when a host's real uplink here ends.
	localEnded func(host string)
	log        func(string)
	generation int64
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
}

// target is who a channel on a host's uplink is for: a client session here, or the other
// end of a tunnel between two hosts (T091).
type target struct {
	session      string
	tunnelHost   string
	tunnelOthers int
}

type hostSession struct {
	conn     Uplink
	next     int
	channels map[int]target
	// Tells this uplink from the one it replaced, so the old one ending does not take the
	// new one down with it.
	gen int64
	// The host's real uplink is here.
	local bool
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
		toldLinks: map[string]bool{}, asks: map[string]*hostAsk{}, presence: map[string]notedPresence{}, log: log}
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

// Described is a host's state as hosts/list and control/hostChanged say it.
func (r *Router) Described(host string) map[string]any {
	s, ok := r.State(host)
	if !ok {
		s = hostState{State: "offline", Since: time.Now()}
	}
	return describe(host, s)
}

func (r *Router) setStateLocked(host string, s hostState) {
	if old, ok := r.states[host]; ok && old.State == s.State && old.Reason == s.Reason && old.From == s.From &&
		old.To == s.To && old.Since.Equal(s.Since) {
		return
	}
	r.states[host] = s
	r.broadcastControlLocked("control/hostChanged", describe(host, s))
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

// SetRelay says whether a host only relays (HostRecord.relay): nil for a host that runs
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

// MARK: Hosts

// AttachHost takes a host's uplink: a channel opens to it for every client session, then
// it is read until it ends.
func (r *Router) AttachHost(host string, conn Uplink) {
	r.mu.Lock()
	if r.hosts[host] != nil {
		r.dropHostLocked(host, 0, nil)
	}
	r.known[host] = true
	r.generation++
	gen := r.generation
	r.hosts[host] = &hostSession{conn: conn, next: 1, channels: map[int]target{}, gen: gen, local: true}
	r.setStateLocked(host, hostState{State: "online"})
	for id := range r.clients {
		r.openChannelLocked(id, host)
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
		r.dropHostLocked(host, gen, &hostState{State: "offline", Since: time.Now()})
		ended := r.localEnded
		r.mu.Unlock()
		if current && ended != nil {
			ended(host)
		}
	}()
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
	delete(r.known, host)
	delete(r.states, host)
	r.broadcastControlLocked("control/hostChanged", map[string]any{"host": host, "state": "removed"})
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
			// What was asked of it is answered, not lost (#77).
			for id := range waiting {
				r.writeLocked(t.session, s.wrap(host, replyError(json.RawMessage(id), fail(hostOffline, "That host went offline before it answered."))))
			}
			// A bare-wire client (the Remote) talks to the home host's daemon and hears
			// nothing else. Its connection ends, so it reconnects and reads everything
			// afresh.
			if !s.wrapped && host == r.homeHost {
				bareGone = append(bareGone, t.session)
			}
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

// channelOpen is ControlWire.ChannelOpen: what a channel is opened as.
type channelOpen struct {
	// Always operator, which an older host needs to open the channel at all (#111).
	Grant     string  `json:"grant"`
	Client    string  `json:"client"`
	Device    *string `json:"device,omitempty"`
	Relayed   *bool   `json:"relayed,omitempty"`
	Tunnel    *string `json:"tunnel,omitempty"`
	TunnelRef *string `json:"tunnelRef,omitempty"`
	FanOut    *bool   `json:"fanOut,omitempty"`
}

func openFrame(c int, open channelOpen) string {
	open.Grant = records.LegacyGrant
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
		if t.session != "" {
			r.detachLocked(t.session, 0)
		} else if other := r.hosts[t.tunnelHost]; other != nil {
			delete(other.channels, t.tunnelOthers)
			other.conn.Send(closeFrame(t.tunnelOthers))
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

// MARK: Clients

// AttachClient takes a paired client's socket, and returns its session, which ends when
// the socket does.
func (r *Router) AttachClient(client *records.ClientRecord, conn *Conn, relayed bool) string {
	id := records.NewUUID()
	r.mu.Lock()
	r.clients[id] = &clientSession{caller: Caller{Session: id, Client: client.ID, Kind: client.Kind, Relayed: relayed},
		conn: conn, channels: map[string]int{}, inFlight: map[string]map[string]bool{}}
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
		s.conn.CloseWith(code, "forgotten")
	} else {
		s.conn.Close()
	}
	r.noteLinkLocked(s.caller.Client)
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
	r.broadcastControlLocked("control/clientChanged", map[string]any{"client": client})
}

// Connections is how every connected client reaches the control plane: true when only
// through the relay.
func (r *Router) Connections() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	for k, v := range r.toldLinks {
		out[k] = v
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
	c := h.next
	h.next++
	h.channels[c] = target{session: sessionID}
	s.channels[host] = c
	// Bound to the client unless it is a Mac's window, which is the Mac, as a window on
	// the socket is: presence is reported as it, and it names no other device.
	yes := true
	open := channelOpen{Client: s.caller.Client, FanOut: &yes}
	if s.caller.Kind != records.KindMac {
		device := s.caller.Client
		open.Device = &device
	}
	if s.caller.Relayed {
		open.Relayed = &yes
	}
	h.conn.Send(openFrame(c, open))
}

const (
	frameBad = iota
	frameControl
	frameHost
	frameLegacy
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
	if _, ok := o["jsonrpc"]; ok {
		return "", line, frameLegacy
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
	case frameLegacy:
		m, ok := decode(msg)
		if ok && m.isRequest() && r.handler.Handles(m.Method) {
			r.toControl(msg, sessionID, false)
			return
		}
		r.mu.Lock()
		if r.homeHost != "" {
			r.toHostLocked(r.homeHost, msg, sessionID)
		} else if ok && m.isRequest() {
			r.writeLocked(sessionID, replyError(m.ID, fail(noSuchHost, "This control plane has no home host.")))
		}
		r.mu.Unlock()
	}
}

// presenceReport is DaemonAPI.PresenceReport, read as it passes to a host.
type presenceReport struct {
	Watching  *string `json:"watching"`
	Active    bool    `json:"active"`
	MayNotify *bool   `json:"mayNotify"`
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
		var p presenceReport
		if json.Unmarshal(m.Params, &p) == nil {
			previous := r.presence[sessionID]
			may := p.MayNotify
			if may == nil {
				may = previous.mayNotify
			}
			device := s.caller.Kind != records.KindMac && s.caller.Kind != records.KindBrowser
			r.presence[sessionID] = notedPresence{client: s.caller.Client, device: device, watching: p.Watching,
				active: p.Active, heardAt: time.Now(), mayNotify: may}
		}
	}
	if !r.known[host] {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(noSuchHost, "No host is called %s.", host))))
		return
	}
	c, ok := s.channels[host]
	h := r.hosts[host]
	if !ok || h == nil || !h.conn.Send(channelFrame(c, msg)) {
		// An uplink that has ended but is not yet dropped takes nothing: said, not lost (#62).
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(hostOffline, "That host is offline."))))
		return
	}
	if s.inFlight[host] == nil {
		s.inFlight[host] = map[string]bool{}
	}
	s.inFlight[host][idKey(m.ID)] = true
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
	r.mu.Unlock()
	if s == nil {
		return
	}
	caller := s.caller
	go func() {
		result, err := r.handler.Handle(m.Method, m.Params, caller)
		line := ""
		if err != nil {
			line = replyError(m.ID, err)
		} else {
			line = reply(m.ID, result)
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

func (r *Router) broadcastControlLocked(method string, params any) {
	line := wrap("", notification(method, params))
	for id, s := range r.clients {
		if s.wrapped {
			r.writeLocked(id, line)
		}
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
	far.conn.Send(openFrame(fc, channelOpen{Client: "tunnel:" + borrower, Tunnel: &runtime}))
	near.conn.Send(openFrame(nc, channelOpen{Client: "tunnel:" + lender, Tunnel: &runtime, TunnelRef: &ref}))
	return true
}
