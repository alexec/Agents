package service

import (
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
)

// Caller is who is calling, as the control plane's own methods need to know.
type Caller struct {
	Session string
	Client  string
	Kind    string
	Relayed bool
}

// Handler answers what the control plane answers itself (ControlHandling).
type Handler interface {
	Handles(method string) bool
	Handle(method string, params json.RawMessage, from Caller) (any, error)
	HostSaid(host, method string, params json.RawMessage) (any, error)
}

// Router is ControlRouter.swift: client sessions on one side, host uplinks on the other,
// and a channel on a host's uplink for every pair of them. It routes connections, not
// calls: a request goes down its channel as the bytes it came as, and whatever the host
// says on that channel goes back to that client with the host's id on it.
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
	relays   map[string]bool
	states   map[string]hostState
	links    map[string]bool // what clients were last said to be connected, and how
	log      func(string)
}

type clientSession struct {
	caller   Caller
	conn     *Conn
	channels map[string]int
	// Set by the first wrapped line. Until then the client is today's Remote, speaking
	// bare JSON-RPC to one daemon: the home host (R7).
	wrapped  bool
	inFlight map[string]map[string]bool
}

type target struct {
	session      string // a client session, or
	tunnelHost   string // the other end of a tunnel between two hosts (T091)
	tunnelOthers int
}

type hostSession struct {
	conn     *Conn
	next     int
	channels map[int]target
	gen      int64
}

type hostState struct {
	State  string
	Since  time.Time
	Reason string
}

func NewRouter(h Handler, log func(string)) *Router {
	return &Router{handler: h, clients: map[string]*clientSession{}, hosts: map[string]*hostSession{},
		known: map[string]bool{}, relays: map[string]bool{}, states: map[string]hostState{}, links: map[string]bool{}, log: log}
}

var generation int64

// MARK: What it knows

func (r *Router) SetHomeHost(h string) { r.mu.Lock(); r.homeHost = h; r.mu.Unlock() }

func (r *Router) Know(host string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.known[host] {
		r.known[host] = true
		r.states[host] = hostState{State: "offline", Since: time.Now()}
	}
}

func (r *Router) State(host string) hostState {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.states[host]
	if !ok {
		return hostState{State: "offline", Since: time.Now()}
	}
	return s
}

func (r *Router) Online(host string) bool { return r.State(host).State == "online" }

func describe(host string, s hostState) map[string]any {
	m := map[string]any{"host": host, "state": s.State}
	switch s.State {
	case "offline":
		m["since"] = s.Since.UTC().Format("2006-01-02T15:04:05Z")
	case "failed":
		m["reason"] = s.Reason
	}
	return m
}

func (r *Router) Described(host string) map[string]any { return describe(host, r.State(host)) }

func (r *Router) setState(host string, s hostState) {
	if old, ok := r.states[host]; ok && old.State == s.State && old.Reason == s.Reason {
		return
	}
	r.states[host] = s
	r.broadcastControlLocked("control/hostChanged", describe(host, s))
}

// SetRelay: a host that only relays is given no client channels, only channel 0.
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

// MARK: Hosts

// AttachHost: a host's uplink is up. A channel opens to it for every client session, then
// it is read until it ends.
func (r *Router) AttachHost(host string, conn *Conn) {
	r.mu.Lock()
	if old := r.hosts[host]; old != nil {
		r.dropHostLocked(host, 0, nil)
	}
	r.known[host] = true
	generation++
	gen := generation
	r.hosts[host] = &hostSession{conn: conn, next: 1, channels: map[int]target{}, gen: gen}
	r.setState(host, hostState{State: "online"})
	for id := range r.clients {
		r.openChannelLocked(id, host)
	}
	r.mu.Unlock()
	go func() {
		for {
			line, err := conn.Read(contextBackground())
			if err != nil {
				break
			}
			r.hostLine(line, host)
		}
		r.mu.Lock()
		r.dropHostLocked(host, gen, &hostState{State: "offline", Since: time.Now()})
		r.mu.Unlock()
	}()
}

// ForgetHost: hosts/remove. Its uplink closes and it is forgotten.
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
		if t.session != "" {
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
			// A bare-wire client (the Remote) hears nothing else: its connection ends, so it
			// reconnects and reads everything afresh.
			if !s.wrapped && host == r.homeHost {
				bareGone = append(bareGone, t.session)
			}
		} else if t.tunnelHost != "" {
			if other := r.hosts[t.tunnelHost]; other != nil {
				delete(other.channels, t.tunnelOthers)
				other.conn.Send(closeFrame(t.tunnelOthers))
			}
		}
	}
	if newState != nil {
		r.setState(host, *newState)
	}
	for _, id := range bareGone {
		r.detachLocked(id, 0)
	}
}

func (s *clientSession) wrap(host, msg string) string {
	if !s.wrapped {
		return msg
	}
	return wrap(host, msg)
}

func wrap(host, msg string) string {
	if host == "" {
		return `{"m":` + msg + `}`
	}
	return `{"h":"` + host + `","m":` + msg + `}`
}

func channelFrame(c int, msg string) string { return `{"c":` + strconv.Itoa(c) + `,"m":` + msg + `}` }
func closeFrame(c int) string               { return `{"c":` + strconv.Itoa(c) + `,"close":true}` }

func openFrame(c int, open map[string]any) string {
	b, _ := json.Marshal(open)
	return `{"c":` + strconv.Itoa(c) + `,"open":` + string(b) + `}`
}

// hostFrame is a line on a host's uplink, taken apart: a message, a close, a fan-out.
type hostFrame struct {
	channel  int
	channels []int
	msg      string
	close    bool
	open     bool
}

func readHostFrame(line string) (hostFrame, bool) {
	// Lines this side writes put m last, so the fast path finds where it starts.
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
	if !ok || f.open {
		return
	}
	if f.channels != nil {
		r.fanOut(f.msg, f.channels, host)
		return
	}
	if f.channel == 0 && !f.close {
		go r.channelZero(f.msg, host)
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
		// The host hung up on a client: its whole connection goes, as it would have today.
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
	// Read only while something waits on this host, and only for its id.
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

// fanOut: a host's broadcast said once for every channel named (#167), wrapped once.
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
	if !ok || !m.isRequest() {
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

// Tell sends a notification on a host's channel 0.
func (r *Router) Tell(host, method string, params any) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hosts[host]
	return h != nil && h.conn.Send(channelFrame(0, notification(method, params)))
}

// MARK: Clients

// AttachClient: a paired client has connected. Returns its session, which ends when the
// socket does.
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
			line, err := conn.Read(contextBackground())
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

// The close code a forgotten client's sockets end with (071 browser-auth.md).
const forgottenCloseCode = 4403

func (r *Router) detachLocked(id string, code websocket.StatusCode) {
	s := r.clients[id]
	if s == nil {
		return
	}
	delete(r.clients, id)
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
		if s.caller.Client == client {
			r.detachLocked(id, forgottenCloseCode)
		}
	}
}

func (r *Router) noteLinkLocked(client string) {
	present, allRelayed := false, true
	for _, s := range r.clients {
		if s.caller.Client == client {
			present = true
			allRelayed = allRelayed && s.caller.Relayed
		}
	}
	was, had := r.links[client]
	if present == had && (!present || was == allRelayed) {
		return
	}
	if present {
		r.links[client] = allRelayed
	} else {
		delete(r.links, client)
	}
	r.broadcastControlLocked("control/clientChanged", map[string]any{"client": client})
}

// Connections: every connected client, and whether only through the relay.
func (r *Router) Connections() map[string]bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]bool{}
	for k, v := range r.links {
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
	// the socket is.
	open := map[string]any{"grant": "operator", "client": s.caller.Client, "fanOut": true}
	if s.caller.Kind != "mac" {
		open["device"] = s.caller.Client
	}
	if s.caller.Relayed {
		open["relayed"] = true
	}
	h.conn.Send(openFrame(c, open))
}

func (r *Router) clientLine(line, sessionID string) {
	host, msg, kind := readClientFrame(line)
	switch kind {
	case frameBad:
		r.mu.Lock()
		if s := r.clients[sessionID]; s != nil {
			r.log("unreadable line from a client")
			wrapped := s.wrapped || strings.Contains(line, `"m"`)
			e := replyError(nil, fail(parseError, "The control plane could not read that message."))
			if wrapped {
				e = wrap(host, e)
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

const (
	frameBad = iota
	frameControl
	frameHost
	frameLegacy
)

func readClientFrame(line string) (host, msg string, kind int) {
	if strings.HasPrefix(line, `{"m":`) && strings.HasSuffix(line, "}") {
		return "", line[5 : len(line)-1], frameControl
	}
	if strings.HasPrefix(line, `{"h":"`) {
		rest := line[6:]
		if q := strings.IndexByte(rest, '"'); q > 0 && strings.HasPrefix(rest[q+1:], `,"m":`) && strings.HasSuffix(line, "}") && auth.IsHostID(rest[:q]) {
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
	if json.Unmarshal(h, &host) != nil || !auth.IsHostID(host) {
		return "", "", frameBad
	}
	return host, string(m), frameHost
}

func (r *Router) toHostLocked(host, msg, sessionID string) {
	s := r.clients[sessionID]
	if s == nil {
		return
	}
	m, ok := decode(msg)
	if !ok {
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
	if !r.known[host] {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(noSuchHost, "No host is called %s.", host))))
		return
	}
	c, ok := s.channels[host]
	h := r.hosts[host]
	if !ok || h == nil {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(hostOffline, "That host is offline."))))
		return
	}
	if !h.conn.Send(channelFrame(c, msg)) {
		r.writeLocked(sessionID, s.wrap(host, replyError(m.ID, fail(hostOffline, "That host is offline."))))
		return
	}
	if s.inFlight[host] == nil {
		s.inFlight[host] = map[string]bool{}
	}
	s.inFlight[host][idKey(m.ID)] = true
}

// toControl: its own goroutine, as hosts/install takes minutes and nothing else this
// client says may wait behind it.
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

// MARK: Tunnels between hosts (T091)

// OpenTunnel joins a channel on each of two hosts: what one sends on its end reaches the
// other untouched.
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
	far.conn.Send(openFrame(fc, map[string]any{"grant": "operator", "client": "tunnel:" + borrower, "tunnel": runtime}))
	near.conn.Send(openFrame(nc, map[string]any{"grant": "operator", "client": "tunnel:" + lender, "tunnel": runtime, "tunnelRef": ref}))
	return true
}

// Sessions is how many client sessions are here, for the log and tests.
func (r *Router) Sessions() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.clients)
}

// Channels lists the channels open on a host's uplink, for tests.
func (r *Router) Channels(host string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h := r.hosts[host]; h != nil {
		return len(h.channels)
	}
	return 0
}
