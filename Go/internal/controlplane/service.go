// Package controlplane is the control plane as a service (058), ControlService.swift in
// Go: a store, the router, the methods it answers itself, and a WebSocket server every
// client and host connects to.
//
// It reads and writes today's control/ folder (the store, control-key, tls/), so a
// change from the Swift agents-control to this one keeps every member, host and grant.
package controlplane

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/hosttunnels"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
)

// Config is ControlService.Configuration.
type Config struct {
	Store store.Store
	// The control plane's P-256 private key: raw, 32 bytes. Never in the store.
	PrivateKey []byte
	// The one address clients and hosts are given (R8).
	URL string
	// The pin of this copy's certificate, when it is not publicly trusted.
	Pin string
	// This copy terminates TLS itself with this, or nil behind a load balancer.
	TLS       *tls.Config
	Bind      string
	Port      int
	Name      string
	MachineID string
	Version   string
	// How this Mac's host's join stands (#113): its root's control-join.json.
	HostJoinFile string
	// Where the Linux hosts it hands out are (ServerFiles.folder).
	ServerFolder string
	// The web remote's loopback listener (071): Web/dist and the port, or nil for none,
	// which is a container's default.
	Web *WebConfig
	// Told whenever the web remote's listener starts or fails to (071 R3): serve --home
	// writes it beside the log for Agents Host.
	WebChanged func(web.Status)
	// Where other copies reach this one (several copies over one store, US3). "" for a
	// single copy (Agents Host's), which links with nobody and takes no leases (#206).
	PeerURL string
	// How often a copy beats, looks for the others and renews its leases; shorter in
	// tests. 0 is 10 s.
	CopyBeat time.Duration
	// Where workspace providers keep their secrets (#691, research R3): the control
	// plane's own home, never the store. "" for none, and no providers.
	ProviderHome string
	// The command provider's binary, when not beside agents-control (tests).
	CommandProvider string
	// How long provider calls, starts and lists take; shorter in tests. Zero is standard.
	ProviderTiming providers.Timing
	// Start empty, for a handover to fill (R16): no settings made, every member refused,
	// only the copy handing over answered, until it says take over.
	Receive bool
	// Serve, even if this copy was forwarding when it stopped (--no-forwarding).
	NoForwarding bool
	// Where each log line goes, already marked with this copy. No line may hold a code,
	// a key, a MAC or a message (071 FR-033).
	Log func(string)
}

// WebConfig is ControlService.Configuration.Web.
type WebConfig struct {
	// Folder is Web/dist, with its MANIFEST.
	Folder string
	// Port is 0 to let the system choose (tests); Agents Host's copy uses 8792.
	Port int
}

// Service is ControlService.
type Service struct {
	cfg     Config
	public  []byte
	origin  string
	copyID  string
	records *records.Records
	codes   *Codes
	router  *Router
	methods *Methods
	started time.Time
	// What this copy has told its relay host for each need (T097).
	desk *notices.Desk
	// What each host last listed (#962), for hosts/lastHeard.
	copies *hostCopies
	// The reverse tunnels this copy holds for servers behind a bastion (#435): a single
	// copy's, whose ssh is the person's on this machine.
	tunnels *hosttunnels.Tunnels
	// Workspace providers (#691): only on a single copy with a home for their secrets.
	providers *providers.Providers
	// The other copies over this store, and the leases (US3); nil for a single copy.
	mesh *mesh
	// The origin peers dial, which a copy's key exchange is bound to.
	peerOrigin string
	// Where this copy is in a handover (R16): serving, receiving, frozen or forwarding.
	phase *phaseBox
	// hosts/install, detect and sshHosts (T072, #429, #610): with the person's own ssh.
	installer *hostinstall.Installer

	mu          sync.Mutex
	readAgainAt time.Time
	servers     []*http.Server
	sockets     map[*Conn]bool
	stop        chan struct{}
	ready       bool
	loopback    *web.Listener
}

// New makes a service; Start opens the store and listens.
func New(cfg Config) (*Service, error) {
	public, err := controllink.PublicKey(cfg.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("the control plane's key: %w", err)
	}
	origin, err := controllink.Origin(cfg.URL)
	if err != nil {
		return nil, fmt.Errorf("%s is not an address clients can dial", cfg.URL)
	}
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	if cfg.Version == "" {
		cfg.Version = buildinfo.Version
	}
	if cfg.Bind == "" {
		cfg.Bind = "0.0.0.0"
	}
	s := &Service{cfg: cfg, public: public, origin: origin, copyID: strings.ToLower(records.NewUUID()[:8]),
		records: records.New(cfg.Store), started: time.Now(), desk: notices.NewDesk(), phase: &phaseBox{phase: phaseServing}, sockets: map[*Conn]bool{}, stop: make(chan struct{})}
	s.codes = &Codes{Store: cfg.Store, Private: cfg.PrivateKey, Public: public, URL: cfg.URL, Pin: cfg.Pin, Name: cfg.Name}
	s.router = NewRouter(nil, s.log)
	s.methods = newMethods(s)
	s.router.handler = s.methods
	s.copies = newHostCopies(cfg.Store)
	if cfg.PeerURL != "" {
		if s.peerOrigin, err = controllink.Origin(cfg.PeerURL); err != nil {
			return nil, fmt.Errorf("%s is not an address copies can dial", cfg.PeerURL)
		}
		s.mesh = newMesh(s, cfg.PeerURL, cfg.CopyBeat)
	}
	// Tunnels belong to a single copy: its ssh is the person's on this machine.
	if cfg.PeerURL == "" {
		s.tunnels = hosttunnels.New(hosttunnels.Config{Store: cfg.Store, Port: cfg.Port, Log: s.log,
			Hosts:   func(context.Context) []records.HostRecord { return s.records.Hosts() },
			Changed: func(change hosttunnels.Changed) { s.router.BroadcastControl("control/tunnelChanged", change) }})
	}
	s.router.SetCopier(s.copies.take)
	var tunnels hostinstall.Tunnels
	if s.tunnels != nil {
		tunnels = s.tunnels
	}
	s.installer = &hostinstall.Installer{Codes: s.codes, ServerFolder: cfg.ServerFolder,
		Progress: func(name, step string) {
			s.router.BroadcastControl("control/installProgress", map[string]string{"name": name, "step": step})
		},
		Tunnels: tunnels,
		KnownNames: func(context.Context) []string {
			var names []string
			for _, h := range s.records.Hosts() {
				names = append(names, h.Name)
			}
			return names
		}}
	if cfg.ProviderHome != "" && s.mesh == nil {
		s.providers = s.makeProviders(cfg.ProviderHome)
	}
	return s, nil
}

func (s *Service) log(line string) { s.cfg.Log("agents-control[" + s.copyID + "]: " + line) }

// Router is the service's router, for tests.
func (s *Service) Router() *Router { return s.router }

// Codes is the service's codes.
func (s *Service) Codes() *Codes { return s.codes }

// Records is the service's records, for tests.
func (s *Service) Records() *records.Records { return s.records }

// Start probes the store, refuses one that ignores conditions or belongs to another
// key, takes up its records and listens. It returns the port bound (the one configured,
// or the one the system chose for 0).
func (s *Service) Start(ctx context.Context) (int, error) {
	if err := store.Probe(ctx, s.cfg.Store, s.copyID); err != nil {
		return 0, fmt.Errorf("the store can't be used: %w", err)
	}
	if s.cfg.Receive {
		s.phase.set(phaseReceiving)
		if object, err := s.cfg.Store.Get(ctx, records.SettingsKey); err != nil {
			return 0, err
		} else if object != nil {
			// Started again after it took over: it serves, as any copy would. A store with
			// records that it never took is a handover that didn't finish. Or it took over,
			// then handed over again and forwards.
			var settings records.Settings
			first := ""
			if json.Unmarshal(object.Data, &settings) == nil {
				if list := currentEndpoints(&settings); len(list) > 0 {
					first = list[0].URL
				}
			}
			forwarded, _ := s.cfg.Store.Get(ctx, s.forwardingKey())
			if first != s.cfg.URL && forwarded == nil {
				return 0, errors.New("this store holds records from a handover that didn't finish; empty it and receive again")
			}
			s.phase.set(phaseServing)
		}
	}
	if s.phase.now() != phaseReceiving {
		if err := s.takeUp(ctx); err != nil {
			return 0, err
		}
		if err := s.resumeForwardingIfMarked(ctx); err != nil {
			return 0, err
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.serveHTTP)
	listeners, err := s.listen()
	if err != nil {
		return 0, err
	}
	port := listeners[0].Addr().(*net.TCPAddr).Port
	for _, ln := range listeners {
		srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second, ErrorLog: nil}
		s.servers = append(s.servers, srv)
		if s.cfg.TLS != nil {
			go srv.Serve(tls.NewListener(ln, s.cfg.TLS))
		} else {
			go srv.Serve(ln)
		}
	}
	s.setReady(true)
	if s.cfg.Web != nil {
		s.startWeb()
	}
	go s.refreshEvery(15 * time.Second)
	go s.sweepEveryHour()
	if s.tunnels != nil {
		s.tunnels.Start(0)
	}
	if s.mesh != nil && s.phase.now() != phaseReceiving {
		s.startMesh()
	}
	if s.providers != nil && s.phase.now() != phaseReceiving {
		s.providers.Start()
	}
	go s.watchJoinFile()
	s.log(fmt.Sprintf("listening on %s:%d for %s", s.cfg.Bind, port, s.cfg.URL))
	return port, nil
}

// listen binds the address given, and on 0.0.0.0 the IPv6 any address on the same port
// too, as the Swift service binds "::" beside it.
func (s *Service) listen() ([]net.Listener, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort(s.cfg.Bind, fmt.Sprint(s.cfg.Port)))
	if err != nil {
		return nil, err
	}
	out := []net.Listener{ln}
	if s.cfg.Bind == "0.0.0.0" {
		port := ln.Addr().(*net.TCPAddr).Port
		if six, err := net.Listen("tcp6", net.JoinHostPort("::", fmt.Sprint(port))); err == nil {
			out = append(out, six)
		}
	}
	return out, nil
}

// takeUp reads the store's records and settles the settings: made once, this copy's
// address and pin written, and the key checked against the one every member was paired
// with.
func (s *Service) takeUp(ctx context.Context) error {
	s.records.OnUnreadable(s.log)
	if err := s.records.Load(ctx); err != nil {
		return err
	}
	public := s.public
	made, err := s.records.SettingsOrMake(ctx, func() records.Settings {
		url := s.cfg.URL
		settings := records.Settings{Name: s.cfg.Name, Port: 8790, MachineID: s.cfg.MachineID, URL: &url, ControlKey: public}
		if s.cfg.Pin != "" {
			pin := s.cfg.Pin
			settings.Pin = &pin
		}
		return settings
	})
	if err != nil {
		return err
	}
	if made.ControlKey != nil && !bytes.Equal(made.ControlKey, public) {
		return errors.New("this store belongs to a control plane with another key; give it that key, or another store")
	}
	if _, err := s.records.ChangeSettings(ctx, func(settings *records.Settings) {
		url := s.cfg.URL
		settings.URL = &url
		settings.Pin = nil
		if s.cfg.Pin != "" {
			pin := s.cfg.Pin
			settings.Pin = &pin
		}
		settings.ControlKey = public
	}); err != nil {
		return err
	}
	for _, h := range s.records.Hosts() {
		s.router.Know(h.ID)
	}
	if home := s.records.Settings().HomeHost; home != nil {
		s.router.SetHomeHost(*home)
	}
	s.syncRelays()
	return nil
}

// Stop stops listening and drops every connection, as a copy that stopped would: its
// clients and hosts redial another copy, or this one when it is back.
func (s *Service) Stop() {
	s.mu.Lock()
	select {
	case <-s.stop:
	default:
		close(s.stop)
	}
	servers := s.servers
	s.servers = nil
	tunnels := s.tunnels
	sockets := s.sockets
	s.sockets = map[*Conn]bool{}
	s.mu.Unlock()
	for _, srv := range servers {
		srv.Close()
	}
	s.mu.Lock()
	loopback := s.loopback
	s.loopback = nil
	s.mu.Unlock()
	if loopback != nil {
		loopback.Stop()
	}
	for c := range sockets {
		c.Close()
	}
	if tunnels != nil {
		tunnels.Stop()
	}
	if s.providers != nil {
		s.providers.Stop()
	}
	if s.mesh != nil {
		s.mesh.stop()
	}
}

func (s *Service) setReady(ready bool) {
	s.mu.Lock()
	s.ready = ready
	s.mu.Unlock()
}

// refreshEvery is the backstop for a change made by hand or by another copy (R4): the
// records read again, and every session here held to them.
func (s *Service) refreshEvery(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			s.refresh()
		}
	}
}

func (s *Service) refresh() {
	if s.phase.now() == phaseReceiving {
		return
	}
	if err := s.records.Load(context.Background()); err != nil {
		s.setReady(false)
		s.log("store: " + err.Error())
		return
	}
	s.setReady(true)
	for _, h := range s.records.Hosts() {
		s.router.Know(h.ID)
	}
	s.reconcile()
	s.syncRelays()
}

// reconcile holds every session here to the records as they are now. A client is closed
// only on its tombstone (#171), and a host let go only when its record is gone, not
// when it cannot be read.
func (s *Service) reconcile() {
	for _, client := range s.router.ConnectedClients() {
		if s.records.Client(client) == nil && s.records.WasForgotten(client) {
			s.router.ForgetClient(client)
		}
	}
	known := map[string]bool{}
	for _, h := range s.records.Hosts() {
		known[h.ID] = true
	}
	for _, host := range s.router.KnownHosts() {
		if !known[host] && !s.records.HostUnreadable(host) {
			s.router.ForgetHost(host)
		}
	}
}

// thisMacHost is how this Mac's host's join stands, or nil (#113).
func (s *Service) thisMacHost() *HostJoinStatus {
	if s.cfg.HostJoinFile == "" {
		return nil
	}
	return readJoinFile(s.cfg.HostJoinFile)
}

// watchJoinFile tells every window when this Mac's host's join changes (#113).
func (s *Service) watchJoinFile() {
	if s.cfg.HostJoinFile == "" {
		return
	}
	last, _ := json.Marshal(s.thisMacHost())
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			status := s.thisMacHost()
			now, _ := json.Marshal(status)
			if !bytes.Equal(now, last) {
				s.router.BroadcastControl("control/thisMacHostChanged", status)
			}
			last = now
		}
	}
}

// syncRelays holds the router to the records: which hosts only relay. Then every relay
// host here hears the devices again.
func (s *Service) syncRelays() {
	for _, h := range s.records.Hosts() {
		s.router.SetRelay(h.ID, h.Relay)
	}
	s.tellRelayDevices()
}

// tellRelayDevices tells each relay host whose uplink ends here every device client and
// its key: whom it may carry for (FR-008).
func (s *Service) tellRelayDevices() {
	relays := s.router.RelaysHeldHere()
	if len(relays) == 0 {
		return
	}
	type device struct {
		ID        string `json:"id"`
		PublicKey []byte `json:"publicKey"`
	}
	devices := []device{}
	for _, c := range s.records.Clients() {
		// A browser has no mailbox to carry for (071), and a Mac's window no relay.
		if c.IsDevice() && len(c.PublicKey) > 0 {
			devices = append(devices, device{c.ID, c.PublicKey})
		}
	}
	for _, relay := range relays {
		s.router.Tell(relay, "relay/devices", map[string]any{"devices": devices})
	}
}

// startMesh starts the copies (T063–T066): leases let go when a host's uplink here ends
// or another copy takes it, presence and links told to the others.
func (s *Service) startMesh() {
	m := s.mesh
	s.router.OnLocalEnded(func(host string) {
		s.log("host " + host + " disconnected")
		if epoch := m.leases.release(context.Background(), host); epoch != 0 {
			m.released(host, epoch)
		}
	})
	m.leases.lost = func(host string, epoch int) {
		s.log("another copy took " + host + "; closing its uplink here")
		s.router.CloseLocal(host)
		m.released(host, epoch)
	}
	s.router.OnPresence(func(client string, device bool, report json.RawMessage) {
		grant := records.LegacyGrant
		if device {
			grant = "device"
		}
		m.broadcast(encodePeer("presence", map[string]any{"client": client, "grant": grant, "report": report}))
	})
	s.router.OnLinkChanged(func(client string, relayed *bool) {
		if relayed == nil {
			s.log("client " + client + " disconnected")
		}
		m.broadcast(peerLinkLine(client, relayed))
	})
	m.start()
}

// heard is a host's attention/need (R6): what to post where, told to the relay host held
// here. With no relay host here, a need reaches only the clients connected to its host,
// over their own channels.
func (s *Service) heard(params json.RawMessage) {
	var need notices.AttentionNeed
	if json.Unmarshal(params, &need) != nil {
		return
	}
	s.deliver(need, false)
}

// deliver posts a need through the relay host if it is held here, otherwise tells the
// other copies, one of which may hold it.
func (s *Service) deliver(need notices.AttentionNeed, fromPeer bool) {
	relays := s.router.RelaysHeldHere()
	if len(relays) == 0 {
		if !fromPeer && s.mesh != nil {
			s.mesh.broadcast(encodePeer("need", need))
		}
		return
	}
	sort.Strings(relays)
	relay := relays[0]
	flags := s.router.NotifyFlags()
	var devices []notices.Device
	for _, c := range s.records.Clients() {
		if !c.IsDevice() || len(c.PublicKey) == 0 {
			continue
		}
		kind := notices.Unknown
		if c.Kind == records.KindIPhone || c.Kind == records.KindIPad {
			kind = c.Kind
		}
		d := notices.Device{ID: c.ID, PublicKey: c.PublicKey, Kind: kind, MayNotify: c.MayNotify}
		if c.LastSeen != nil {
			d.LastSeen = c.LastSeen.Time
		}
		if may, ok := flags[c.ID]; ok {
			d.MayNotify = &may
		}
		devices = append(devices, d)
	}
	for _, delivery := range s.desk.Heard(need, s.router.FoldedPresences(), devices, time.Now()) {
		s.router.Tell(relay, "relay/deliver", delivery)
		did := "sent"
		if delivery.Headline == nil {
			did = "withdrew"
		}
		s.log(fmt.Sprintf("notice: %s %s for %s to relay %s", did, delivery.NeedID, delivery.Device, relay))
	}
}

// serveHTTP answers the TLS listener: the WebSocket at /v1/connect, the probes, and what
// a server installs itself from (T070).
func (s *Service) serveHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/healthz":
		plain(w, http.StatusOK, "ok\n")
	case path == "/readyz":
		s.mu.Lock()
		ready := s.ready
		s.mu.Unlock()
		if ready {
			plain(w, http.StatusOK, "ready\n")
		} else {
			plain(w, http.StatusServiceUnavailable, "the store can't be reached\n")
		}
	case path == "/v1/install.sh":
		w.Header().Set("Content-Type", "text/x-shellscript")
		w.Write([]byte(InstallScript))
	case strings.HasPrefix(path, "/v1/servers/"):
		data, ok := serverFile(strings.TrimPrefix(path, "/v1/servers/"), s.cfg.ServerFolder)
		if !ok {
			plain(w, http.StatusNotFound, "this control plane has no such file\n")
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(data)
	case path == "/v1/connect":
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		go s.accept(s.adopt(newConn(ws, r.RemoteAddr)), "")
	default:
		plain(w, http.StatusNotFound, "not here\n")
	}
}

func plain(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	w.Write([]byte(text))
}

// adopt keeps a socket so Stop can close it.
func (s *Service) adopt(c *Conn) *Conn {
	s.mu.Lock()
	s.sockets[c] = true
	s.mu.Unlock()
	go func() {
		<-c.Done()
		s.mu.Lock()
		delete(s.sockets, c)
		s.mu.Unlock()
	}()
	return c
}

// startWeb starts the loopback listener. A build that doesn't match its manifest, or a
// port that's taken, leaves it off and says so (071 R3): in the log, in control/status
// and to WebChanged; the TLS listener and hosts carry on.
func (s *Service) startWeb() {
	listener, err := web.Start(web.Config{Folder: s.cfg.Web.Folder, Port: s.cfg.Web.Port, Log: s.log,
		Accept: func(ws *websocket.Conn, remote, origin string) {
			s.accept(s.adopt(newConn(ws, remote)), origin)
		}})
	status := web.StatusOf(s.cfg.Web.Port, listener, err)
	s.mu.Lock()
	s.loopback = listener
	s.mu.Unlock()
	s.methods.SetWeb(&status)
	if s.cfg.WebChanged != nil {
		s.cfg.WebChanged(status)
	}
	s.router.BroadcastControl("control/webChanged", status)
}

// RetryWeb tries the loopback listener again when it isn't serving (071 R3): Agents
// Host's Try Again, once whatever held the port has let it go.
func (s *Service) RetryWeb() {
	s.mu.Lock()
	serving := s.loopback != nil
	s.mu.Unlock()
	if s.cfg.Web == nil || serving {
		return
	}
	s.startWeb()
}

// WebPort is the loopback listener's port once it is up, or 0.
func (s *Service) WebPort() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loopback == nil {
		return 0
	}
	return s.loopback.Port()
}

// accept is the server's side of the key exchange, then the socket goes where its
// identity says: a client to the router, a host's uplink to the router, a code holder to
// a one-time announce. webOrigin is the loopback listener's own origin for a socket that
// came in there, or "" for the TLS listener: the exchange is bound to the listener's
// origin, never to anything the peer says (071, FR-006).
func (s *Service) accept(conn *Conn, webOrigin string) {
	serverNonce := controllink.Nonce()
	hello := controllink.Hello{V: controllink.Version, Name: s.cfg.Name, Control: controllink.B64URL(s.public),
		Nonce: controllink.B64URL(serverNonce), Copy: s.copyID}
	refuse := func(err error) {
		var r *controllink.Refusal
		if errors.As(err, &r) {
			conn.SendNow(controllink.Message{Refused: r.Reason}.Line())
			s.log(fmt.Sprintf("refused a connection from %s: %s", conn.Remote, r.Reason))
		} else {
			s.log(fmt.Sprintf("a connection from %s ended: %v", conn.Remote, err))
		}
		conn.Close()
	}
	if err := conn.SendNow(controllink.Message{Hello: &hello}.Line()); err != nil {
		conn.Close()
		return
	}
	line, err := conn.ReadWithin(15 * time.Second)
	if err != nil {
		conn.Close()
		return
	}
	m, ok := controllink.ParseMessage(line)
	if !ok || m.Auth == nil {
		refuse(controllink.Refuse(controllink.BadMessage))
		return
	}
	auth := m.Auth
	var client *records.ClientRecord
	var host string
	var admittedAny bool
	bound := s.origins()
	// A peer copy dials the address copies reach each other at, and proves that. Anyone
	// else (a handover's driver too) may have dialled any place the control plane answers.
	if strings.HasPrefix(auth.ID, "x:") && !strings.HasPrefix(auth.ID, "x:"+handoverPrefix) && s.peerOrigin != "" {
		bound = []string{s.peerOrigin}
	}
	if webOrigin != "" {
		// On the loopback listener only a browser or its code may prove anything (071).
		if !strings.HasPrefix(auth.ID, "c:") && !strings.HasPrefix(auth.ID, "p:") {
			refuse(controllink.Refuse(controllink.Unknown))
			return
		}
		bound = []string{webOrigin}
	}
	id, mac, err := controllink.Verify(auth, serverNonce, bound, func(id controllink.Identity) ([]byte, error) {
		key, c, h, err := s.key(id)
		client, host, admittedAny = c, h, err == nil
		return key, err
	})
	if err != nil {
		refuse(err)
		return
	}
	if !admittedAny {
		refuse(controllink.Refuse(controllink.Unknown))
		return
	}
	// In a handover (R16): a receiving copy answers only the copy filling it, and no code
	// is used while records can't be written.
	phase := s.phase.now()
	switch {
	case phase == phaseReceiving && id.Kind != 'x':
		// Being filled, so its records are not whole yet: not a verdict on anyone (#81).
		refuse(controllink.Refuse(controllink.Unavailable))
		return
	case (phase == phaseFrozen || phase == phaseForwarding) && (id.Kind == 'p' || id.Kind == 'e'):
		refuse(controllink.Refuse(controllink.Unknown))
		return
	case phase == phaseForwarding && (id.Kind == 'c' || id.Kind == 'h') && s.phase.forwardingUntil().Before(time.Now()):
		// Forwarding ended (30 days at most): anyone still to hear pairs again.
		refuse(controllink.Refuse(controllink.Unknown))
		return
	}
	// A browser's key works only through the loopback listener, and nothing else's does
	// there (071).
	if client != nil && (client.Kind == records.KindBrowser) != (webOrigin != "") {
		refuse(controllink.Refuse(controllink.Unknown))
		return
	}
	// A device through agents-relay (T096): the exchange is its own, end to end, and it
	// says it came that way, for itself only.
	relayed := auth.Kind == "relay"
	if relayed && (id.Kind != 'c' || auth.For != id.ID || client == nil || !client.IsDevice()) {
		refuse(controllink.Refuse(controllink.BadMessage))
		return
	}
	// Once a list has been announced, every member is given it (R16).
	settings := s.records.Settings()
	ok2 := controllink.OK{MAC: controllink.B64URL(mac), Host: host}
	if client != nil {
		ok2.Grant = records.LegacyGrant
	}
	if relayed {
		ok2.Relayed = &relayed
	}
	if settings != nil && settings.Epoch != nil {
		ok2.Endpoints, _ = json.Marshal(currentEndpoints(settings))
		ok2.Epoch = settings.Epoch
	}
	if err := conn.SendNow(controllink.Message{OK: &ok2}.Line()); err != nil {
		conn.Close()
		return
	}
	// A member that says an epoch keeps a list, and takes the one just given.
	if auth.Epoch != nil {
		epoch := *auth.Epoch
		if settings != nil && settings.Epoch != nil && *settings.Epoch > epoch {
			epoch = *settings.Epoch
		}
		go s.methods.NoteEpoch(context.Background(), id, epoch)
	}
	// A forwarding copy's ok gave the new list; that is all it has to say.
	if phase == phaseForwarding && (id.Kind == 'c' || id.Kind == 'h') {
		conn.Close()
		return
	}
	switch id.Kind {
	case 'c':
		s.router.AttachClient(client, conn, relayed)
		if err := s.methods.Admit(context.Background(), *client); err != nil {
			s.log("store: could not note " + client.Name + " connecting: " + err.Error())
		}
		through := ""
		if relayed {
			through = " through the relay"
		}
		s.log(fmt.Sprintf("client %s (%s) connected%s from %s", client.Name, client.Kind, through, conn.Remote))
	case 'h':
		s.hostArrived(host, conn)
	case 'p', 'e':
		s.spend(conn, id.ID, webOrigin != "")
	case 'x':
		if strings.HasPrefix(id.ID, handoverPrefix) {
			s.handoverSession(conn)
			return
		}
		if s.mesh == nil {
			conn.Close()
			return
		}
		s.mesh.accepted(id.ID, conn)
	}
}

// origins is every origin a member may have dialled: this copy's own, and each endpoint
// announced (R16), in that order and once each. A copy that holds ssh tunnels also
// answers at its loopback: a server through one dials https://127.0.0.1:<port> on its
// own end, which is this listener (#435, #610).
func (s *Service) origins() []string {
	out := []string{s.origin}
	var urls []string
	if settings := s.records.Settings(); settings != nil {
		for _, e := range settings.Endpoints {
			urls = append(urls, e.URL)
		}
	}
	if s.tunnels != nil {
		urls = append(urls, fmt.Sprintf("https://127.0.0.1:%d", s.tunnels.Port()))
	}
	for _, u := range urls {
		if o, err := controllink.Origin(u); err == nil && !contains(out, o) {
			out = append(out, o)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// currentEndpoints is ControlSettings.currentEndpoints: the list announced, or this
// copy's own address.
func currentEndpoints(settings *records.Settings) []records.Endpoint {
	if len(settings.Endpoints) > 0 {
		return settings.Endpoints
	}
	if settings.URL == nil {
		return nil
	}
	return []records.Endpoint{{URL: *settings.URL, Pin: settings.Pin}}
}

// key is the key an identity proves, and what it is admitted as.
func (s *Service) key(id controllink.Identity) ([]byte, *records.ClientRecord, string, error) {
	// Being filled by a handover, its records are not whole yet: try again, which says
	// nothing about the member (#81), where unknown would have a browser forget its key.
	if id.Kind != 'x' && s.phase.now() == phaseReceiving {
		return nil, nil, "", controllink.Refuse(controllink.Unavailable)
	}
	switch id.Kind {
	case 'c':
		// Paired at another copy moments ago: this one reads the store again. A store that
		// cannot be read says so; unknown would have the device forget its pairing (#81).
		if s.records.Client(id.ID) == nil {
			if err := s.readAgain(); err != nil {
				return nil, nil, "", err
			}
		}
		c := s.records.Client(id.ID)
		// A browser hears it was forgotten, and deletes its key (071 FR-014).
		if c == nil && s.records.WasForgotten(id.ID) {
			return nil, nil, "", controllink.Refuse(controllink.Forgotten)
		}
		// Listed and unreadable is not unknown (#171).
		if c == nil && s.records.ClientUnreadable(id.ID) {
			return nil, nil, "", controllink.Refuse(controllink.Unavailable)
		}
		if c == nil || len(c.PublicKey) == 0 {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		key, err := controllink.ClientKey(s.cfg.PrivateKey, c.PublicKey, c.ID)
		if err != nil {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return key, c, "", nil
	case 'h':
		if s.records.Host(id.ID) == nil {
			if err := s.readAgain(); err != nil {
				return nil, nil, "", err
			}
		}
		h := s.records.Host(id.ID)
		if h == nil && s.records.HostUnreadable(id.ID) {
			return nil, nil, "", controllink.Refuse(controllink.Unavailable)
		}
		if h == nil || len(h.PublicKey) == 0 {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		key, err := controllink.HostKey(s.cfg.PrivateKey, h.PublicKey, h.ID)
		if err != nil {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return key, nil, h.ID, nil
	case 'p', 'e':
		// Spent or not: a join replayed by the key that spent it is told apart in announce.
		stored, err := s.codes.Stored(context.Background(), id.ID, true)
		if err != nil {
			return nil, nil, "", err
		}
		wanted := (id.Kind == 'e') == (stored.Purpose == "host")
		secret := controllink.CodeSecret(s.cfg.PrivateKey, id.ID)
		if !wanted || secret == nil {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return controllink.CodeKey(secret), nil, "", nil
	case 'x':
		// Copies link with each other only on a control plane of several copies; a
		// handover's driver proves the copies' key at any.
		if s.mesh == nil && !strings.HasPrefix(id.ID, handoverPrefix) {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return controllink.CopyKey(s.cfg.PrivateKey), nil, "", nil
	}
	return nil, nil, "", controllink.Refuse(controllink.Unknown)
}

// readAgain reads the store again for a member not in the records, or refuses as
// unavailable when it cannot: not known yet is not the same as not a member. Once a
// second at most (#174).
func (s *Service) readAgain() error {
	s.mu.Lock()
	if time.Since(s.readAgainAt) < time.Second {
		s.mu.Unlock()
		return controllink.Refuse(controllink.Unavailable)
	}
	s.readAgainAt = time.Now()
	s.mu.Unlock()
	if err := s.records.Load(context.Background()); err != nil {
		s.log("store: could not read it to admit a member: " + err.Error())
		return controllink.Refuse(controllink.Unavailable)
	}
	return nil
}

// hostArrived takes a host's uplink: its first line is host/hello on channel 0 (kept
// from the first build), then the router reads it.
func (s *Service) hostArrived(host string, conn *Conn) {
	first, err := conn.ReadWithin(15 * time.Second)
	f, ok := readHostFrame(first)
	var m *message
	if err == nil && ok && f.channel == 0 && !f.close && !f.open && f.channels == nil {
		m, ok = decode(f.msg)
	}
	if err != nil || !ok || m == nil || m.Method != "host/hello" || !m.isRequest() {
		s.log("host " + host + " connected without saying hello; closing it")
		conn.Close()
		return
	}
	s.router.AttachHost(host, conn)
	// This copy holds the host now (T063): every peer reaches it through here.
	if s.mesh != nil {
		if epoch, err := s.mesh.leases.take(context.Background(), host); err == nil {
			s.mesh.holding(host, epoch)
		} else {
			s.log("the store would not give " + host + "'s lease to this copy; serving it anyway")
		}
	}
	result, err := s.methods.HostSaid(host, "host/hello", m.Params)
	if err != nil {
		conn.Send(channelFrame(0, replyError(m.ID, err)))
	} else {
		conn.Send(channelFrame(0, reply(m.ID, result)))
	}
	s.log("host " + host + " connected")
}

// spentWords is a code used already, as the page says it (Web/src/session.ts).
const spentWords = "This code has been used. Ask for a new one."

// spend is someone holding a code saying who they are, once, before it hangs up
// (wire.md).
func (s *Service) spend(conn *Conn, id string, loopback bool) {
	defer func() {
		// Give the reply time to leave before the socket closes.
		time.Sleep(200 * time.Millisecond)
		conn.Close()
	}()
	line, err := conn.ReadWithin(15 * time.Second)
	if err != nil {
		return
	}
	m, ok := decode(line)
	if !ok || !m.isRequest() {
		return
	}
	result, err := s.spendCode(id, m.Method, m.Params, loopback)
	if err != nil {
		var r *controllink.Refusal
		if errors.As(err, &r) {
			if r.Reason == controllink.Spent {
				err = fail(notPermitted, spentWords)
			} else {
				err = fail(notPermitted, "That code can't be used: %s.", r.Reason)
			}
		}
		s.log("a " + m.Method + " with a code failed: " + asRPC(err).Message)
		conn.SendNow(replyError(m.ID, err))
		return
	}
	conn.SendNow(reply(m.ID, result))
}

func (s *Service) spendCode(id, method string, params json.RawMessage, loopback bool) (*admitted, error) {
	ctx := context.Background()
	stored, err := s.codes.Stored(ctx, id, true)
	if err != nil {
		return nil, err
	}
	switch {
	case stored.Purpose == "client" && method == "clients/announce":
		var a clientAnnounce
		if json.Unmarshal(params, &a) != nil || len(a.PublicKey) == 0 || !controllink.IsUUID(a.ID) {
			return nil, fail(invalidParams, "Say who you are.")
		}
		a.ID = strings.ToUpper(a.ID)
		switch a.Kind {
		case records.KindMac, records.KindIPhone, records.KindIPad, records.KindUnknown, records.KindBrowser:
		default:
			a.Kind = records.KindUnknown
		}
		// A browser pairs through the loopback listener, and only a browser does (071).
		if (a.Kind == records.KindBrowser) != loopback {
			return nil, fail(invalidParams, "Pair that kind of client elsewhere.")
		}
		// And with a code made for one, which is good nowhere else (R2). Refused before it
		// is spent, so the browser it was made for can still use it.
		browser := stored.Browser != nil && *stored.Browser
		if browser != loopback {
			if browser {
				return nil, fail(invalidParams, "That code is for a browser on this Mac.")
			}
			return nil, fail(invalidParams, "That code is for a window or a phone. Get one from Pair a Browser….")
		}
		name := a.Name
		if a.Kind == records.KindBrowser {
			name = browserName(a.Name)
		}
		spender := a.ID
		sp, err := s.codes.Spend(ctx, id, spent{PublicKey: a.PublicKey, Client: &spender})
		if err != nil {
			return nil, err
		}
		client := a.ID
		if sp.Client != nil {
			client = strings.ToUpper(*sp.Client)
		}
		result := &admitted{Client: client, Grant: records.LegacyGrant}
		// The same join again (#212): it paired, and could not keep it.
		if old := s.records.Client(client); sp.replayed && old != nil && bytes.Equal(old.PublicKey, a.PublicKey) {
			s.log(name + " paired again with the code it spent (" + a.Kind + ")")
			return result, nil
		}
		record := records.ClientRecord{ID: client, Name: name, Kind: a.Kind, PublicKey: a.PublicKey, Paired: records.Now()}
		if err := s.methods.Admit(ctx, record); err != nil {
			return nil, err
		}
		s.log(name + " paired (" + a.Kind + ")")
		// Known at every copy at once: the relay host may be held at another.
		s.announce("clientPaired", client, "code")
		return result, nil
	case stored.Purpose == "host" && method == "hosts/announce":
		var a hostAnnounce
		if json.Unmarshal(params, &a) != nil {
			return nil, fail(invalidParams, "Say which host you are.")
		}
		// The host on the control plane's own machine is its home host, mac, as a moved
		// set-up's is (data-model.md).
		relay := a.Relay != nil && *a.Relay
		home := s.cfg.MachineID != "" && a.MachineID == s.cfg.MachineID && s.records.Host("mac") == nil && !relay
		want := records.NewHostID()
		if home {
			want = "mac"
		}
		sp, err := s.codes.Spend(ctx, id, spent{PublicKey: a.PublicKey, Host: &want})
		if err != nil {
			return nil, err
		}
		if sp.Host == nil {
			return nil, controllink.Refuse(controllink.Spent)
		}
		host := *sp.Host
		result := &admitted{Host: host}
		// The same join again (#212): it enrolled, and could not keep it.
		if old := s.records.Host(host); sp.replayed && old != nil && bytes.Equal(old.PublicKey, a.PublicKey) {
			s.log("host " + a.Name + " enrolled again as " + host + " with the code it spent")
			return result, nil
		}
		mid := a.MachineID
		record := records.HostRecord{ID: host, Name: a.Name, PublicKey: a.PublicKey, Platform: a.Platform,
			Version: a.Version, MachineID: &mid}
		if relay {
			record.Relay = &relay
		}
		if a.Implementation != "" {
			impl, _ := json.Marshal(a.Implementation)
			record.Extra = records.Extra{"implementation": impl}
		}
		if err := s.records.SaveHost(ctx, record); err != nil {
			return nil, err
		}
		if relay {
			s.router.SetRelay(host, &relay)
		}
		// Every other copy knows it at once.
		s.announce("hostEnrolled", host, "code")
		s.router.Know(host)
		s.log("host " + a.Name + " enrolled as " + host)
		return result, nil
	}
	return nil, fail(notPermitted, "That code is not for %s.", method)
}

// browserName is "Safari on Alex's MacBook": the page can't learn the Mac's name, and the
// loopback listener only ever runs on the Mac it names (071, FR-010).
func browserName(said string) string {
	product := strings.TrimSpace(said)
	if r := []rune(product); len(r) > 40 {
		product = strings.TrimSpace(string(r[:40]))
	}
	if product == "" {
		product = "A browser"
	}
	return product + " on " + LocalName()
}
