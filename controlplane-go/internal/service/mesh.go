package service

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

// Stage 7: several copies over one store (058, US3), as Leases.swift and PeerLinks.swift
// keep them. A host is held by one copy, its lease in v1/leases/<host>.json, taken with a
// conditional write and renewed every 10 s. Every pair of live copies (v1/copies/<id>.json,
// a heartbeat every 10 s) has one WebSocket, dialled by the smaller id and proved as
// x:<copy>. A copy reaches a host another holds through a stream on that link, which its
// router takes for the host's uplink. Changes people make go out on every link.

// MARK: Leases

type lease struct {
	Host    string        `json:"host"`
	Copy    string        `json:"copy"`
	Epoch   int           `json:"epoch"`
	Expires records.Stamp `json:"expires"`
}

const (
	leaseLife  = 30 * time.Second
	leaseRenew = 10 * time.Second
	copyBeat   = 10 * time.Second
	copyGone   = 30 * time.Second
)

func leaseKey(host string) string { return "v1/leases/" + host + ".json" }
func copyKey(copy string) string  { return "v1/copies/" + copy + ".json" }

type Leases struct {
	store store.Store
	copy  string
	mu    sync.Mutex
	held  map[string]heldLease
	lost  func(host string)
}

type heldLease struct {
	etag  string
	lease lease
}

func encodeJSON(v any) []byte { b, _ := json.MarshalIndent(v, "", "  "); return b }

// Take takes the host's lease for this copy, over whatever was there. Returns its epoch.
func (l *Leases) Take(ctx context.Context, host string) (int, error) {
	for range 3 {
		o, err := l.store.Get(ctx, leaseKey(host))
		if err != nil {
			return 0, err
		}
		var prev lease
		cond := store.Absent
		if o != nil {
			json.Unmarshal(o.Data, &prev)
			cond = store.Matching(o.ETag)
		}
		next := lease{Host: host, Copy: l.copy, Epoch: prev.Epoch + 1, Expires: records.Stamp{Time: time.Now().Add(leaseLife).UTC()}}
		tag, err := l.store.Put(ctx, leaseKey(host), encodeJSON(next), cond)
		if store.IsConflict(err) {
			continue
		}
		if err != nil {
			return 0, err
		}
		l.mu.Lock()
		l.held[host] = heldLease{tag, next}
		l.mu.Unlock()
		return next.Epoch, nil
	}
	return 0, &store.ConflictError{Key: leaseKey(host)}
}

// Release marks the lease over, if it is still this copy's. Returns its epoch, or 0.
func (l *Leases) Release(ctx context.Context, host string) int {
	l.mu.Lock()
	mine, ok := l.held[host]
	delete(l.held, host)
	l.mu.Unlock()
	if !ok {
		return 0
	}
	over := mine.lease
	over.Expires = records.Now()
	l.store.Put(ctx, leaseKey(host), encodeJSON(over), store.Matching(mine.etag))
	return over.Epoch
}

func (l *Leases) Epoch(host string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.held[host].lease.Epoch
}

// Holder is who holds a host now, unless its lease has run out.
func (l *Leases) Holder(ctx context.Context, host string) *lease {
	o, err := l.store.Get(ctx, leaseKey(host))
	if err != nil || o == nil {
		return nil
	}
	var le lease
	if json.Unmarshal(o.Data, &le) != nil || !le.Expires.After(time.Now()) {
		return nil
	}
	return &le
}

// renewAll renews each lease held. A renewal refused means another copy took the host.
// A store that is away keeps the uplink: live work carries on (US3-6).
func (l *Leases) renewAll(ctx context.Context) {
	l.mu.Lock()
	held := make(map[string]heldLease, len(l.held))
	for k, v := range l.held {
		held[k] = v
	}
	l.mu.Unlock()
	for host, mine := range held {
		renewed := mine.lease
		renewed.Expires = records.Stamp{Time: time.Now().Add(leaseLife).UTC()}
		tag, err := l.store.Put(ctx, leaseKey(host), encodeJSON(renewed), store.Matching(mine.etag))
		l.mu.Lock()
		now, still := l.held[host]
		switch {
		case err == nil && still && now.etag == mine.etag:
			l.held[host] = heldLease{tag, renewed}
			l.mu.Unlock()
		case store.IsConflict(err) && still && now.etag == mine.etag:
			delete(l.held, host)
			lost := l.lost
			l.mu.Unlock()
			if lost != nil {
				lost(host)
			}
		default:
			// Taken afresh or released while the write was out: that answer is stale.
			l.mu.Unlock()
		}
	}
}

// MARK: The mesh

type peerLink struct {
	peer string
	conn *Conn
	gen  int64
}

type Mesh struct {
	s        *Service
	peerURL  string
	leases   *Leases
	mu       sync.Mutex
	links    map[string]*peerLink
	dialling map[string]bool
	proxies  map[string]*proxyUplink
	started  time.Time
	gen      int64
}

type copyRecord struct {
	ID        string        `json:"id"`
	PeerURL   string        `json:"peerURL"`
	Started   records.Stamp `json:"started"`
	Heartbeat records.Stamp `json:"heartbeat"`
}

func newMesh(s *Service, peerURL string) *Mesh {
	m := &Mesh{s: s, peerURL: peerURL, links: map[string]*peerLink{}, dialling: map[string]bool{},
		proxies: map[string]*proxyUplink{}, started: time.Now()}
	m.leases = &Leases{store: s.cfg.Store, copy: s.copyID, held: map[string]heldLease{}}
	m.leases.lost = func(host string) {
		s.log("another copy took " + host + "; closing its uplink here")
		s.router.CloseLocal(host)
	}
	return m
}

func (m *Mesh) start() {
	beat, renew := copyBeat, leaseRenew
	if b := m.s.cfg.CopyBeat; b > 0 {
		beat, renew = b, b
	}
	m.tick()
	go func() {
		for range time.Tick(beat) {
			m.tick()
		}
	}()
	go func() {
		for range time.Tick(renew) {
			m.leases.renewAll(context.Background())
		}
	}()
}

func (m *Mesh) Peers() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []string
	for id := range m.links {
		out = append(out, id)
	}
	return out
}

// tick is the heartbeat, a look at who else is there, and a look for hosts nobody here reaches.
func (m *Mesh) tick() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st := m.s.cfg.Store
	me := m.s.copyID
	rec := copyRecord{ID: me, PeerURL: m.peerURL, Started: records.Stamp{Time: m.started.UTC()}, Heartbeat: records.Now()}
	st.Put(ctx, copyKey(me), encodeJSON(rec), store.Always)
	listed, err := st.List(ctx, "v1/copies/")
	if err != nil {
		return
	}
	for _, e := range listed {
		o, err := st.Get(ctx, e.Key)
		if err != nil || o == nil {
			continue
		}
		var c copyRecord
		if json.Unmarshal(o.Data, &c) != nil {
			continue
		}
		if time.Since(c.Heartbeat.Time) > copyGone {
			st.Delete(ctx, e.Key) // gone: any copy tidies its record away
			continue
		}
		m.mu.Lock()
		dial := c.ID != me && m.links[c.ID] == nil && !m.dialling[c.ID] && me < c.ID
		if dial {
			m.dialling[c.ID] = true
		}
		m.mu.Unlock()
		if dial {
			go m.dial(c.ID, c.PeerURL)
		}
	}
	m.findHosts(ctx)
}

func (m *Mesh) dial(id, peerURL string) {
	defer func() { m.mu.Lock(); delete(m.dialling, id); m.mu.Unlock() }()
	conn, err := m.join(peerURL)
	if err != nil {
		m.s.log(fmt.Sprintf("could not reach copy %s at %s: %v", id, peerURL, err))
		return
	}
	m.linkUp(id, conn)
}

// join dials a peer and proves x:<copy> with the key only copies hold.
func (m *Mesh) join(peerURL string) (*Conn, error) {
	u, err := url.Parse(peerURL)
	if err != nil {
		return nil, err
	}
	origin, _ := auth.Origin(peerURL)
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if pin := m.s.cfg.Pin; pin != "" {
		tlsConfig.InsecureSkipVerify = true
		tlsConfig.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
			leaf, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
			if auth.ToB64URL(sum[:]) != pin {
				return errors.New("not the copies' certificate")
			}
			return nil
		}
	}
	u.Scheme = map[string]string{"https": "wss", "http": "ws"}[u.Scheme]
	u.Path = "/v1/connect"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, u.String(), &websocket.DialOptions{HTTPClient: &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}}})
	if err != nil {
		return nil, err
	}
	c := newConn(ws, peerURL)
	line, err := c.ReadWithin(10 * time.Second)
	if err != nil {
		return nil, err
	}
	var hello struct{ Hello auth.Hello }
	json.Unmarshal([]byte(line), &hello)
	if k, _ := auth.B64URL(hello.Hello.Control); string(k) != string(m.s.public) {
		c.Close()
		return nil, errors.New("that is not this control plane")
	}
	sn, _ := auth.B64URL(hello.Hello.Nonce)
	pn := auth.Nonce()
	key := auth.CopyKey(m.s.cfg.PrivateKey)
	id := "x:" + m.s.copyID
	c.SendNow(auth.Line("auth", auth.Auth{ID: id, Nonce: auth.ToB64URL(pn), MAC: auth.ToB64URL(auth.PeerMAC(key, sn, pn, id, origin)), Kind: "copy"}))
	line, err = c.ReadWithin(10 * time.Second)
	if err != nil {
		return nil, err
	}
	var ok struct {
		OK *auth.OK `json:"ok"`
	}
	json.Unmarshal([]byte(line), &ok)
	if ok.OK == nil {
		c.Close()
		return nil, fmt.Errorf("refused: %s", line)
	}
	if mac, _ := auth.B64URL(ok.OK.MAC); string(mac) != string(auth.ServerMAC(key, sn, pn, id, origin)) {
		c.Close()
		return nil, errors.New("the ok's MAC does not match")
	}
	return c, nil
}

// Accepted: a peer that dialled this copy and proved it is one of ours.
func (m *Mesh) Accepted(id string, conn *Conn) { m.linkUp(id, conn) }

func (m *Mesh) linkUp(id string, conn *Conn) {
	m.mu.Lock()
	if old := m.links[id]; old != nil {
		old.conn.Close()
	}
	m.gen++
	link := &peerLink{peer: id, conn: conn, gen: m.gen}
	m.links[id] = link
	m.mu.Unlock()
	m.s.router.SetPeer(id, func(line string) { conn.Send(line) })
	m.s.log("linked with copy " + id)
	// Say which hosts are held here, so the peer reaches them through this link.
	for _, host := range m.s.router.Known() {
		if m.s.router.Holds(host) {
			conn.Send(hostFrameLine(host, true, m.leases.Epoch(host)))
		}
	}
	go func() {
		for {
			line, err := conn.Read(context.Background())
			if err != nil {
				break
			}
			m.received(line, link)
		}
		m.linkDown(link)
	}()
}

func (m *Mesh) linkDown(link *peerLink) {
	m.mu.Lock()
	if m.links[link.peer] != link {
		m.mu.Unlock()
		return
	}
	delete(m.links, link.peer)
	var gone []*proxyUplink
	for host, p := range m.proxies {
		if p.peer == link.peer {
			delete(m.proxies, host)
			gone = append(gone, p)
		}
	}
	m.mu.Unlock()
	m.s.router.DropPeer(link.peer)
	for _, p := range gone {
		p.finish()
	}
	m.s.log("lost the link with copy " + link.peer)
}

func hostFrameLine(host string, online bool, epoch int) string {
	state := "offline"
	if online {
		state = "online"
	}
	b, _ := json.Marshal(map[string]any{"host": map[string]any{"id": host, "state": state, "epoch": epoch}})
	return string(b)
}

func goneLine(host string, epoch int) string {
	return `{"p":"` + host + `","gone":{"epoch":` + strconv.Itoa(epoch) + `}}`
}

// received is what a peer says (PeerWire.read).
func (m *Mesh) received(line string, link *peerLink) {
	if strings.HasPrefix(line, `{"p":"`) {
		rest := line[6:]
		q := strings.IndexByte(rest, '"')
		if q < 0 || !strings.HasPrefix(rest[q+1:], ",") {
			return
		}
		host, hostLine := rest[:q], "{"+rest[q+2:]
		if strings.HasPrefix(hostLine, `{"gone":`) {
			m.mu.Lock()
			p := m.proxies[host]
			if p != nil && p.peer == link.peer {
				delete(m.proxies, host)
			}
			m.mu.Unlock()
			if p != nil && p.peer == link.peer {
				p.finish()
			}
			// Whoever holds it now says so; until then, look.
			go func() { time.Sleep(time.Second); m.find(context.Background(), host) }()
			return
		}
		m.stream(host, hostLine, link)
		return
	}
	var o map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &o) != nil {
		return
	}
	if raw, ok := o["host"]; ok {
		var h struct {
			ID    string `json:"id"`
			State string `json:"state"`
		}
		json.Unmarshal(raw, &h)
		if h.State == "online" {
			m.reach(h.ID, link)
		} else {
			m.mu.Lock()
			p := m.proxies[h.ID]
			if p != nil && p.peer == link.peer {
				delete(m.proxies, h.ID)
			}
			m.mu.Unlock()
			if p != nil && p.peer == link.peer {
				p.finish()
			}
		}
		return
	}
	if raw, ok := o["event"]; ok {
		var e event
		if json.Unmarshal(raw, &e) == nil {
			m.s.apply(e)
		}
	}
	// presence, need and link frames: notices and Settings' "connected at" are not ported.
}

// stream: a host frame on the link, for a host held here (the peer carries a client of its
// own to it) or for the stream this copy has to a host the peer holds.
func (m *Mesh) stream(host, hostLine string, link *peerLink) {
	r := m.s.router
	if r.Holds(host) {
		var o map[string]json.RawMessage
		if json.Unmarshal([]byte(hostLine), &o) != nil {
			return
		}
		var c int
		json.Unmarshal(o["c"], &c)
		switch {
		case o["open"] != nil:
			var open map[string]any
			json.Unmarshal(o["open"], &open)
			r.OpenFromPeer(link.peer, host, c, open)
		case o["m"] != nil:
			r.FromPeer(link.peer, host, c, string(o["m"]))
		case string(o["close"]) == "true":
			r.CloseFromPeer(link.peer, host, c)
		}
		return
	}
	m.mu.Lock()
	p := m.proxies[host]
	m.mu.Unlock()
	if p != nil && p.peer == link.peer {
		p.deliver(hostLine)
	}
}

// reach makes a stream the router takes for the host's uplink.
func (m *Mesh) reach(host string, link *peerLink) {
	if m.s.router.Holds(host) {
		return
	}
	m.mu.Lock()
	if p := m.proxies[host]; p != nil {
		if p.peer == link.peer && p.isOpen() {
			m.mu.Unlock()
			return
		}
		p.finish()
	}
	p := newProxyUplink(host, link.peer, func(line string) { link.conn.Send(line) })
	m.proxies[host] = p
	m.mu.Unlock()
	m.s.router.AttachHost(host, p, false)
}

func (m *Mesh) findHosts(ctx context.Context) {
	for _, host := range m.s.router.Known() {
		if !m.s.router.Reaches(host) {
			m.find(ctx, host)
		}
	}
}

func (m *Mesh) find(ctx context.Context, host string) {
	if m.s.router.Reaches(host) {
		return
	}
	le := m.leases.Holder(ctx, host)
	if le == nil || le.Copy == m.s.copyID {
		return
	}
	m.mu.Lock()
	link := m.links[le.Copy]
	m.mu.Unlock()
	if link != nil {
		m.reach(host, link)
	}
}

func (m *Mesh) broadcast(line string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, l := range m.links {
		l.conn.Send(line)
	}
}

// holding: this copy took a host; every peer reaches it through here now.
func (m *Mesh) holding(host string, epoch int) {
	m.mu.Lock()
	p := m.proxies[host]
	delete(m.proxies, host)
	m.mu.Unlock()
	if p != nil {
		p.finish()
	}
	m.broadcast(hostFrameLine(host, true, epoch))
}

func (m *Mesh) released(host string, epoch int) { m.broadcast(goneLine(host, epoch)) }

// MARK: A host held by another copy

// proxyUplink is ProxyUplink: what the router writes goes to the holder with the host in
// front; what the holder sends back comes out as if from the host's own uplink.
type proxyUplink struct {
	host, peer string
	send       func(string)
	in         chan string
	done       chan struct{}
	once       sync.Once
	mu         sync.Mutex
	channels   map[int]bool
}

func newProxyUplink(host, peer string, send func(string)) *proxyUplink {
	return &proxyUplink{host: host, peer: peer, send: send, in: make(chan string, queued), done: make(chan struct{}), channels: map[int]bool{}}
}

func (p *proxyUplink) isOpen() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

func (p *proxyUplink) Send(line string) bool {
	if !p.isOpen() {
		return false
	}
	if f, ok := readHostFrame(line); ok && f.msg == "" {
		p.mu.Lock()
		if f.close {
			delete(p.channels, f.channel)
		} else if strings.Contains(line, `"open":`) {
			p.channels[f.channel] = true
		}
		p.mu.Unlock()
	} else if strings.Contains(line, `,"open":`) {
		var o struct{ C int }
		json.Unmarshal([]byte(line), &o)
		p.mu.Lock()
		p.channels[o.C] = true
		p.mu.Unlock()
	}
	p.send(peerFrame(p.host, line))
	return true
}

func (p *proxyUplink) Read(ctx context.Context) (string, error) {
	select {
	case l := <-p.in:
		return l, nil
	case <-p.done:
		return "", errors.New("the stream closed")
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (p *proxyUplink) deliver(line string) {
	select {
	case p.in <- line:
	case <-p.done:
	default:
		p.finish() // too far behind: the router redials through find
	}
}

// Close: the router dropped this stream; the holder closes this copy's channels on the host.
func (p *proxyUplink) Close() {
	if p.isOpen() {
		p.mu.Lock()
		var open []int
		for c := range p.channels {
			open = append(open, c)
		}
		p.mu.Unlock()
		for _, c := range open {
			p.send(peerFrame(p.host, closeFrame(c)))
		}
	}
	p.finish()
}

func (p *proxyUplink) finish() { p.once.Do(func() { close(p.done) }) }

// MARK: Changes made here, applied at every copy

type event struct {
	Kind    string        `json:"kind"`
	Subject string        `json:"subject"`
	At      records.Stamp `json:"at"`
	By      string        `json:"by"`
}

// tellCopies says a change on every peer link (the store's events/ for a copy that missed
// it is not kept: the 15 s re-list is the backstop).
func (s *Service) tellCopies(kind, subject, by string) {
	if s.mesh == nil {
		return
	}
	b, _ := json.Marshal(map[string]any{"event": event{Kind: kind, Subject: subject, At: records.Now(), By: by}})
	s.mesh.broadcast(string(b))
}

// apply is a change another copy made: the records again, then its effect on sessions here.
func (s *Service) apply(e event) {
	s.records.Load(context.Background())
	switch e.Kind {
	case "clientForgotten":
		s.router.ForgetClient(strings.ToUpper(e.Subject))
	case "hostRemoved":
		s.router.ForgetHost(e.Subject)
	default:
		for _, h := range s.records.Hosts() {
			s.router.Know(h.ID)
			s.router.SetRelay(h.ID, h.Relay)
		}
	}
	s.log("applied " + e.Kind + " " + e.Subject + " from another copy")
}
