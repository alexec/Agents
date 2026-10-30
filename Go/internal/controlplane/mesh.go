package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Several copies over one store (058, US3), as Leases.swift and PeerLinks.swift keep
// them. A host is held by one copy, its lease in v1/leases/<host>.json, taken with a
// conditional write and renewed every 10 s. Every pair of live copies (v1/copies/<id>.json,
// a heartbeat every 10 s) has one WebSocket, dialled by the smaller id and proved as
// x:<copy>. A copy reaches a host another holds through a stream on that link, which its
// router takes for the host's uplink. Changes people make go out on every link, and into
// v1/events/ for a copy that missed them.

// The lease's and the copy record's times (HostLease, CopyRecord).
const (
	leaseLife  = 30 * time.Second
	leaseRenew = 10 * time.Second
	copyBeat   = 10 * time.Second
	copyGone   = 30 * time.Second
)

// hostLease is HostLease: which copy holds a host's uplink (R5).
type hostLease struct {
	Host    string        `json:"host"`
	Copy    string        `json:"copy"`
	Epoch   int           `json:"epoch"`
	Expires records.Stamp `json:"expires"`
}

const leasesPrefix = "v1/leases/"

func leaseKey(host string) string      { return leasesPrefix + host + ".json" }
func copyRecordKey(copy string) string { return "v1/copies/" + copy + ".json" }

type heldLease struct {
	etag  string
	lease hostLease
}

// leases is Leases: the hosts this copy holds, renewed against the version written.
type leases struct {
	store store.Store
	copy  string
	mu    sync.Mutex
	held  map[string]heldLease
	// Told when a renewal finds another copy took the host.
	lost func(host string, epoch int)
}

// take takes the host's lease for this copy, over whatever was there, and says its epoch.
func (l *leases) take(ctx context.Context, host string) (int, error) {
	for range 3 {
		existing, err := l.store.Get(ctx, leaseKey(host))
		if err != nil {
			return 0, err
		}
		var previous hostLease
		when := store.Absent
		if existing != nil {
			json.Unmarshal(existing.Data, &previous)
			when = store.Matching(existing.ETag)
		}
		next := hostLease{Host: host, Copy: l.copy, Epoch: previous.Epoch + 1, Expires: records.At(time.Now().Add(leaseLife))}
		data, _ := records.Encode(next)
		etag, err := l.store.Put(ctx, leaseKey(host), data, when)
		if store.IsConflict(err) {
			continue
		}
		if err != nil {
			return 0, err
		}
		l.mu.Lock()
		l.held[host] = heldLease{etag, next}
		l.mu.Unlock()
		return next.Epoch, nil
	}
	return 0, &store.ConflictError{Key: leaseKey(host)}
}

// release marks the lease over, if it is still this copy's, and says its epoch, or 0.
func (l *leases) release(ctx context.Context, host string) int {
	l.mu.Lock()
	mine, ok := l.held[host]
	delete(l.held, host)
	l.mu.Unlock()
	if !ok {
		return 0
	}
	over := mine.lease
	over.Expires = records.Now()
	data, _ := records.Encode(over)
	l.store.Put(ctx, leaseKey(host), data, store.Matching(mine.etag))
	return over.Epoch
}

func (l *leases) epoch(host string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.held[host].lease.Epoch
}

// holder is who holds a host now, unless its lease has run out.
func (l *leases) holder(ctx context.Context, host string) *hostLease {
	object, err := l.store.Get(ctx, leaseKey(host))
	if err != nil || object == nil {
		return nil
	}
	var lease hostLease
	if json.Unmarshal(object.Data, &lease) != nil || !lease.Expires.After(time.Now()) {
		return nil
	}
	return &lease
}

// renewAll renews each lease held. A renewal refused means another copy took the host;
// a store that is away keeps the uplink, and live work carries on (US3-6).
func (l *leases) renewAll(ctx context.Context) {
	l.mu.Lock()
	held := make(map[string]heldLease, len(l.held))
	for k, v := range l.held {
		held[k] = v
	}
	l.mu.Unlock()
	for host, mine := range held {
		renewed := mine.lease
		renewed.Expires = records.At(time.Now().Add(leaseLife))
		data, _ := records.Encode(renewed)
		etag, err := l.store.Put(ctx, leaseKey(host), data, store.Matching(mine.etag))
		l.mu.Lock()
		now, still := l.held[host]
		switch {
		case err == nil && still && now.etag == mine.etag:
			l.held[host] = heldLease{etag, renewed}
			l.mu.Unlock()
		case err == nil && !still:
			// Released while out, and its mark lost to this write: marked again.
			l.mu.Unlock()
			over := renewed
			over.Expires = records.Now()
			data, _ := records.Encode(over)
			l.store.Put(ctx, leaseKey(host), data, store.Matching(etag))
		case store.IsConflict(err) && still && now.etag == mine.etag:
			delete(l.held, host)
			lost := l.lost
			l.mu.Unlock()
			if lost != nil {
				lost(host, mine.lease.Epoch)
			}
		default:
			l.mu.Unlock()
		}
	}
}

// copyRecord is CopyRecord: a live copy, and where the others reach it.
type copyRecord struct {
	ID        string        `json:"id"`
	PeerURL   string        `json:"peerURL"`
	Started   records.Stamp `json:"started"`
	Heartbeat records.Stamp `json:"heartbeat"`
}

// controlEvent is ControlEvent: a change, for every copy to apply.
type controlEvent struct {
	Kind    string `json:"kind"`
	Subject string `json:"subject"`
	At      string `json:"at"`
	By      string `json:"by"`
}

type peerLink struct {
	peer string
	conn *Conn
}

// mesh is CopyMesh.
type mesh struct {
	s        *Service
	peerURL  string
	leases   *leases
	beat     time.Duration
	started  time.Time
	mu       sync.Mutex
	links    map[string]*peerLink
	dialling map[string]bool
	proxies  map[string]*proxyUplink
}

func newMesh(s *Service, peerURL string, beat time.Duration) *mesh {
	if beat <= 0 {
		beat = copyBeat
	}
	m := &mesh{s: s, peerURL: peerURL, beat: beat, started: time.Now(), links: map[string]*peerLink{},
		dialling: map[string]bool{}, proxies: map[string]*proxyUplink{}}
	m.leases = &leases{store: s.cfg.Store, copy: s.copyID, held: map[string]heldLease{}}
	return m
}

func (m *mesh) start() {
	m.tick()
	renew := leaseRenew
	if m.beat < renew {
		renew = m.beat
	}
	go m.every(m.beat, m.tick)
	go m.every(renew, func() { m.leases.renewAll(context.Background()) })
}

func (m *mesh) every(d time.Duration, f func()) {
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-m.s.stop:
			return
		case <-t.C:
			f()
		}
	}
}

func (m *mesh) stop() {
	m.s.cfg.Store.Delete(context.Background(), copyRecordKey(m.s.copyID))
	m.mu.Lock()
	links, proxies := m.links, m.proxies
	m.links, m.proxies = map[string]*peerLink{}, map[string]*proxyUplink{}
	m.mu.Unlock()
	for _, l := range links {
		l.conn.Close()
	}
	for _, p := range proxies {
		p.finish()
	}
}

// tick is the heartbeat, a look at who else is there, and a look for hosts nobody here
// reaches.
func (m *mesh) tick() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st := m.s.cfg.Store
	me := m.s.copyID
	record := copyRecord{ID: me, PeerURL: m.peerURL, Started: records.At(m.started), Heartbeat: records.Now()}
	data, _ := records.Encode(record)
	st.Put(ctx, copyRecordKey(me), data, store.Always)
	listed, err := st.List(ctx, "v1/copies/")
	if err != nil {
		return
	}
	for _, e := range listed {
		object, err := st.Get(ctx, e.Key)
		if err != nil || object == nil {
			continue
		}
		// HostCopies keep their lists in the same folder: those are no copy.
		var c copyRecord
		if json.Unmarshal(object.Data, &c) != nil || c.ID == "" || c.PeerURL == "" {
			continue
		}
		if time.Since(c.Heartbeat.Time) > copyGone {
			// Gone: any copy tidies its record away.
			st.Delete(ctx, e.Key)
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

func (m *mesh) dial(id, peerURL string) {
	defer func() {
		m.mu.Lock()
		delete(m.dialling, id)
		m.mu.Unlock()
	}()
	pin := ""
	if strings.HasPrefix(peerURL, "https") {
		pin = m.s.cfg.Pin
	}
	lines, _, err := controllink.Join(context.Background(), peerURL, pin, controllink.Credentials{
		Identity: "x:" + m.s.copyID, Key: controllink.CopyKey(m.s.privateKey()), Kind: "copy", ControlKey: m.s.publicKey()})
	if err != nil {
		m.s.log(fmt.Sprintf("could not reach copy %s at %s: %v", id, peerURL, err))
		return
	}
	m.linkUp(id, newConn(lines.Socket(), peerURL))
}

// accepted is a peer that dialled this copy and proved it is one of ours.
func (m *mesh) accepted(id string, conn *Conn) { m.linkUp(id, conn) }

func (m *mesh) linkUp(id string, conn *Conn) {
	m.mu.Lock()
	if old := m.links[id]; old != nil {
		old.conn.Close()
	}
	link := &peerLink{peer: id, conn: conn}
	m.links[id] = link
	m.mu.Unlock()
	m.s.router.SetPeer(id, func(line string) { conn.Send(line) })
	m.s.log("linked with copy " + id)
	// Say which hosts are held here, so the peer reaches them through this link.
	for _, host := range m.s.router.HeldHere() {
		conn.Send(hostOnline(host, true, m.leases.epoch(host)))
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
	go m.s.linked()
}

func (m *mesh) linkDown(link *peerLink) {
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

// MARK: PeerWire

func hostOnline(host string, online bool, epoch int) string {
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

func encodePeer(tag string, body any) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.Encode(map[string]any{tag: body})
	return strings.TrimSuffix(b.String(), "\n")
}

// encodeNeed is a need for the other copies, with whose devices it goes to (#994).
func encodeNeed(need notices.AttentionNeed, owner string) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.Encode(map[string]any{"need": need, "owner": owner})
	return strings.TrimSuffix(b.String(), "\n")
}

// received is what a peer says (PeerWire.read).
func (m *mesh) received(line string, link *peerLink) {
	if strings.HasPrefix(line, `{"p":"`) {
		rest := line[6:]
		q := strings.IndexByte(rest, '"')
		if q < 0 || !strings.HasPrefix(rest[q+1:], ",") {
			return
		}
		host, hostLine := rest[:q], "{"+rest[q+2:]
		if strings.HasPrefix(hostLine, `{"gone":`) {
			m.dropProxy(host, link.peer)
			// Whoever holds it now says so; until then, look.
			go func() {
				time.Sleep(time.Second)
				m.find(context.Background(), host)
			}()
			return
		}
		m.stream(host, hostLine, link)
		return
	}
	var o map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &o) != nil {
		return
	}
	switch {
	case o["host"] != nil:
		var h struct {
			ID    string `json:"id"`
			State string `json:"state"`
		}
		json.Unmarshal(o["host"], &h)
		if h.State == "online" {
			m.reach(h.ID, link)
		} else {
			m.dropProxy(h.ID, link.peer)
		}
	case o["event"] != nil:
		var e controlEvent
		if json.Unmarshal(o["event"], &e) == nil {
			m.s.apply(e)
		}
	case o["presence"] != nil:
		var p struct {
			Client string          `json:"client"`
			Grant  string          `json:"grant"`
			Report json.RawMessage `json:"report"`
		}
		if json.Unmarshal(o["presence"], &p) == nil && controllink.IsUUID(p.Client) {
			m.s.router.NotePeerPresence(strings.ToUpper(p.Client), p.Grant == "device", p.Report)
		}
	case o["link"] != nil:
		var l struct {
			Client  string          `json:"client"`
			Relayed *bool           `json:"relayed"`
			Gone    json.RawMessage `json:"gone"`
		}
		if json.Unmarshal(o["link"], &l) == nil && controllink.IsUUID(l.Client) {
			relayed := l.Relayed
			if l.Gone != nil {
				relayed = nil
			} else if relayed == nil {
				no := false
				relayed = &no
			}
			m.s.router.NotePeerLink(link.peer, strings.ToUpper(l.Client), relayed)
		}
	case o["need"] != nil:
		var need notices.AttentionNeed
		var owner string
		json.Unmarshal(o["owner"], &owner)
		if json.Unmarshal(o["need"], &need) == nil {
			m.s.deliver(need, true, owner, "")
		}
	}
}

// stream is a host frame on the link: for a host held here (the peer carries a client
// of its own to it), or for this copy's stream to a host the peer holds.
func (m *mesh) stream(host, hostLine string, link *peerLink) {
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
			var open wire.ChannelOpen
			json.Unmarshal(o["open"], &open)
			r.OpenFromPeer(link.peer, host, c, open)
		case o["m"] != nil:
			r.FromPeer(link.peer, host, c, string(o["m"]))
		case string(o["close"]) == "true":
			r.CloseFromPeer(link.peer, host, c)
		}
		// Only a host fans out, and only to the control plane: a peer's is ignored.
		return
	}
	m.mu.Lock()
	p := m.proxies[host]
	m.mu.Unlock()
	if p != nil && p.peer == link.peer {
		p.deliver(hostLine)
	}
}

func (m *mesh) dropProxy(host, peer string) {
	m.mu.Lock()
	p := m.proxies[host]
	if p != nil && p.peer == peer {
		delete(m.proxies, host)
	} else {
		p = nil
	}
	m.mu.Unlock()
	if p != nil {
		p.finish()
	}
}

// reach makes a stream the router takes for the host's uplink.
func (m *mesh) reach(host string, link *peerLink) {
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
	m.s.router.AttachProxy(host, p)
}

func (m *mesh) findHosts(ctx context.Context) {
	for _, host := range m.s.router.KnownHosts() {
		if !m.s.router.Reaches(host) {
			m.find(ctx, host)
		}
	}
}

func (m *mesh) find(ctx context.Context, host string) {
	if m.s.router.Reaches(host) {
		return
	}
	lease := m.leases.holder(ctx, host)
	if lease == nil || lease.Copy == m.s.copyID {
		return
	}
	m.mu.Lock()
	link := m.links[lease.Copy]
	m.mu.Unlock()
	if link != nil {
		m.reach(host, link)
	}
}

func (m *mesh) broadcast(line string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, l := range m.links {
		l.conn.Send(line)
	}
}

// holding says this copy took a host: every peer reaches it through here now.
func (m *mesh) holding(host string, epoch int) {
	m.mu.Lock()
	p := m.proxies[host]
	delete(m.proxies, host)
	m.mu.Unlock()
	if p != nil {
		p.finish()
	}
	m.broadcast(hostOnline(host, true, epoch))
}

func (m *mesh) released(host string, epoch int) { m.broadcast(goneLine(host, epoch)) }

// counts is how many leases this copy holds, and how many copies it knows, itself too:
// for the metrics (#2176).
func (m *mesh) counts() (leases, copies int) {
	m.leases.mu.Lock()
	leases = len(m.leases.held)
	m.leases.mu.Unlock()
	return leases, len(m.peers()) + 1
}

func (m *mesh) peers() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []string
	for id := range m.links {
		out = append(out, id)
	}
	return out
}

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
	return &proxyUplink{host: host, peer: peer, send: send, in: make(chan string, queued), done: make(chan struct{}),
		channels: map[int]bool{}}
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
	if f, ok := readHostFrame(line); ok && f.msg == "" && f.channels == nil {
		p.mu.Lock()
		if f.close {
			delete(p.channels, f.channel)
		} else if f.open {
			p.channels[f.channel] = true
		}
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
		// Too far behind: the router finds the host again.
		p.finish()
	}
}

// Close is the router dropping this stream: the holder closes this copy's channels.
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

// announce is a change made here: on every peer link first, then into v1/events/ for a
// copy that missed it.
func (s *Service) announce(kind, subject, by string) {
	if s.mesh == nil {
		return
	}
	at := time.Now().UTC()
	event := controlEvent{Kind: kind, Subject: subject, At: at.Format("2006-01-02T15:04:05Z"), By: by}
	s.mesh.broadcast(encodePeer("event", event))
	key := fmt.Sprintf("v1/events/%s/%013d-%s.json", at.Format("2006-01-02"), at.UnixMilli(), strings.ToLower(records.NewUUID()[:8]))
	if data, err := records.Encode(map[string]any{"kind": kind, "subject": subject, "at": records.At(at), "by": by}); err == nil {
		s.cfg.Store.Put(context.Background(), key, data, store.Absent)
	}
}

// apply is a change another copy made: the records again, then its effect on sessions
// here.
func (s *Service) apply(e controlEvent) {
	s.records.Load(context.Background())
	switch e.Kind {
	case "clientForgotten":
		s.router.ForgetClient(strings.ToUpper(e.Subject))
	case "hostRemoved":
		s.router.ForgetHost(e.Subject)
		s.copies.forget(e.Subject)
	case "userSettingsChanged":
		// A person's settings or secrets changed at another copy (#1760).
		s.userChangedHere(e.Subject, nil, true)
	case "orgRoutesChanged":
		// An org route changed at another copy (#999): its machines and clients here.
		s.orgRoutesChangedHere()
	case "policyChanged", "policyStopAll":
		// The policy changed at another copy (#998): its machines and clients here.
		s.policyChangedHere(e.Kind == "policyStopAll")
	case "linkRequested", "linkDecided":
		// A channel link asked for, sent on or decided at another copy (#1762).
		s.links.heardFromCopy(e.Kind, e.Subject)
	case "linksChanged":
		s.links.tellChanged(e.Subject)
	case "groupsChanged":
		// A group made, changed or removed at another copy (#1761).
		s.tellGroupsChanged(e.Subject, s.records.Group(e.Subject) == nil)
	case "projectsChanged":
		// A project made, renamed, adopted or removed at another copy (#2317).
		s.tellProjectsChanged(e.Subject, e.Subject != "" && s.records.Project(e.Subject) == nil)
	case "personSuspended":
		// A person suspended, or no longer, at another copy (#1002, D13): within 5 seconds here.
		s.suspendedHere(e.Subject)
	case "scimTokenRevoked":
		s.scimTokens.forget()
	case "notice":
		var n wire.ControlNotice
		if json.Unmarshal([]byte(e.Subject), &n) == nil {
			s.noticeAdminsHere(n)
		}
	case "peopleChanged":
		// Another copy's invite or removal makes this one a team, or not (#1763).
		s.noteTeam()
		s.tellPeoplesMachines()
		// Who may use which org route (#999).
		s.resendOrgRoutes()
	case "clientPaired", "hostEnrolled", "hostMoved":
		for _, h := range s.records.Hosts() {
			s.router.Know(h.ID)
		}
	case "endpointsChanged":
		// Members here reconnect, and their ok gives them the list.
		s.mu.Lock()
		sockets := s.sockets
		s.mu.Unlock()
		for c := range sockets {
			c.Close()
		}
	}
	s.syncRelays()
	s.log("applied " + e.Kind + " " + e.Subject + " from another copy")
}

// linked is a copy that just linked: every session here held to the records, and the
// peer told how each client here reaches this copy (T080).
func (s *Service) linked() {
	s.reconcile()
	for client, relayed := range s.router.LinksHere() {
		r := relayed
		s.mesh.broadcast(peerLinkLine(client, &r))
	}
}

func peerLinkLine(client string, relayed *bool) string {
	body := map[string]any{"client": client}
	if relayed == nil {
		body["gone"] = true
	} else {
		body["relayed"] = *relayed
	}
	return encodePeer("link", body)
}
