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
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/hosttunnels"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/scim"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/wire"
	"github.com/coder/websocket"
)

// Config is ControlService.Configuration.
type Config struct {
	Store store.Store
	// The control plane's P-256 private key: raw, 32 bytes. Never in the store.
	PrivateKey []byte
	// Where the key is kept, so control/rotate can keep a new one (#997); nil for a key
	// handed in, which is not rotated.
	KeyKeeper KeyKeeper
	// How long a client's or machine's key lives unused (#997); 0 is DefaultKeyLifetime.
	KeyLifetime time.Duration
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
	// Where the runtimes' toolsets machines/install puts on a server are (#1136): "" puts none.
	ToolsetFolder string
	// The web remote's loopback listener (071): Web/dist and the port, or nil for none,
	// which is a container's default.
	Web *WebConfig
	// The built web app (Web/dist) to serve on this listener too, at URL's own origin, for a
	// browser anywhere (#1459): a control plane behind a proxy with a public certificate
	// (compose.public.yaml). "" serves none, as Agents Host's copy, whose page is the
	// loopback listener's.
	PublicWeb string
	// The second name in front of this listener for the page's MCP Apps views (#1484): the
	// sandbox proxy's https address (views.<domain>). "" draws no views on the page.
	PublicViews string
	// Told whenever the web remote's listener starts or fails to (071 R3): serve --home
	// writes it beside the log for Agents Host.
	WebChanged func(web.Status)
	// Hosted is a copy we run for an account on our servers (#1807): it has no ssh, so no
	// tunnels, and it installs, finds and updates no machine over ssh. Machines join by a
	// code, their join command, or a provider.
	Hosted bool
	// Where other copies reach this one (several copies over one store, US3). "" for a
	// single copy (Agents Host's), which links with nobody and takes no leases (#206).
	PeerURL string
	// How often a copy beats, looks for the others and renews its leases; shorter in
	// tests. 0 is 10 s.
	CopyBeat time.Duration
	// The machine providers' home (#691): their connections' files, and their secrets
	// when there is no SecretKeeper; with one, the secrets are sealed in the store (#2138).
	// "" for none, and no providers.
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
	// The proxies whose X-Forwarded-For names a socket's source (Caddy on a public
	// machine): the per-source budget counts by it (public-security.md P3). Empty trusts
	// none, and counts by the peer's own address.
	TrustedProxies []netip.Prefix
	// The keeper that seals each person's secrets (#1760, FR-025): gcpkms://… on a cloud
	// machine, or base64key://… from a 0600 file outside the store on a Mac. "" keeps no
	// secrets: user/setSecret is refused, and settings still follow the person.
	SecretKeeper string
	// Where each log line goes, already marked with this copy. No line may hold a code,
	// a key, a MAC or a message (071 FR-033).
	Log func(string)
	// Logger takes a line for each request, at debug, with its fields (#2176): method,
	// client, person, host and request id. Nil drops them.
	Logger *slog.Logger
	// Posts this copy's own pushes through APNs (#1460) when no Mac host relays a notice.
	// Nil, with no key on the machine, sends none.
	Push Pusher
	// The sign-in providers this copy can check, and where it asks them (#995); nil is the
	// app's own client ids, or AGENTS_SIGNIN_* over them.
	SignIn *signin.Config
	// Where the org routes' token and check calls go (#999); nil is the providers' own.
	// Tests point them at fakes.
	orgEndpoints *orgEndpoints
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
	cfg Config
	// The control key, and the one before a rotation (#997): read with currentKeys.
	keyBook
	origin  string
	copyID  string
	records *records.Records
	codes   *Codes
	router  *Router
	// auditChain links the audit entries this copy writes, and auditSinks sends them (#1001).
	auditChain *audit.Chain
	// auditWriter keeps the entries, one goroutine for all (#2433).
	auditWriter *audit.Writer
	auditSinks  *auditSinkState
	// Servers' backups (#1815).
	backups *backupStore
	methods *Methods
	started time.Time
	// What this copy has told its relay host for each need (T097).
	desk *notices.Desk
	// This copy's own pushes, when no relay host is online (#1460); nil with no key.
	pushes *pushes
	// What each host last listed (#962), for machines/lastHeard.
	copies *hostCopies
	// The reverse tunnels this copy holds for servers behind a bastion (#435): a single
	// copy's, whose ssh is the person's on this machine.
	tunnels *hosttunnels.Tunnels
	// Machine providers (#691): only on a single copy with a home for their secrets.
	providers *providers.Providers
	// The other copies over this store, and the leases (US3); nil for a single copy.
	mesh *mesh
	// The origin peers dial, which a copy's key exchange is bound to.
	peerOrigin string
	// Where this copy is in a handover (R16): serving, receiving, frozen or forwarding.
	phase *phaseBox
	// machines/install, detect and sshHosts (T072, #429, #610): with the person's own ssh.
	installer *hostinstall.Installer

	// One read of the store's records at a time, at most one every readAgainEvery
	// (public-security.md P1).
	reads readGate
	// What each source address may still try before it proves a key (P3).
	sources *sources
	// The downloads' rate for each address, the most sockets open at once, and the log of
	// what was refused for either (#2150).
	downloads   *addressRates
	socketsMost int
	refusals    *refusalLog
	// The machine/clients each host here was told last (#1528).
	told toldClients
	// Machines asking to join with no code (#994).
	joins *joins
	links *links
	// Sign-in with Google, Apple and GitHub (#995), and the GitHub sign-ins waiting.
	signIns *signIns
	// SCIM at /scim/v2/ (#1002, slice 2a).
	scimTokens *scimTokens
	scimServer *scim.Server
	// The read API's tokens, and the OTLP exporter when one is set (#2019).
	readAPI         *readTokens
	otlp            *otlpExporter
	signInApprovals *signInApprovals
	// Each person's settings and secrets (#1760), and what each machine here was sent.
	users     *usersettings.Book
	toldUsers toldUsers
	// Which bots are at a spend cap today (#1761).
	caps botCaps
	// The organisation's policy as this copy knows it, and what each machine was sent (#998).
	policies policyBook
	// The organisation's routes to the model (#999): opened secrets, tokens, and what each
	// machine here was sent.
	orgRoutes orgRouteBook
	// A bot's machine started for its triggers (#2011, FR-034).
	starts botStarts
	// What Reports and the Console read from the store, by entity tag (#2054, #2056).
	storeReads readCache

	mu       sync.Mutex
	servers  []*http.Server
	sockets  map[*Conn]bool
	stop     chan struct{}
	ready    bool
	loopback *web.Listener
	// The page at this copy's own origin (#1459), or nil.
	page *web.Public
	// What an operations team scrapes (#2176): always counted, served only by ServeMetrics.
	metrics *Metrics
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
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.DiscardHandler)
	}
	metrics := newMetrics()
	cfg.Store = countedStore{Store: cfg.Store, m: metrics}
	s := &Service{cfg: cfg, keyBook: keyBook{keys: controlKeys{private: cfg.PrivateKey, public: public}}, origin: origin, copyID: strings.ToLower(records.NewUUID()[:8]),
		records: records.New(cfg.Store), started: time.Now(), desk: notices.NewDesk(), phase: &phaseBox{phase: phaseServing}, sockets: map[*Conn]bool{}, stop: make(chan struct{}),
		reads: readGate{every: readAgainEvery}, metrics: metrics}
	s.sources = newSources(cfg.TrustedProxies, s.log)
	s.auditChain, s.auditSinks = audit.NewChain(s.copyID), newAuditSinkState(cfg.Name, s.copyID)
	s.auditWriter = audit.NewWriter(s.auditLog(), s.log)
	s.downloads, s.socketsMost, s.refusals = newAddressRates(), socketsMost, newRefusalLog(s.log)
	if cfg.Push != nil {
		s.pushes = newPushes(s, cfg.Push)
	}
	s.codes = &Codes{Store: cfg.Store, Private: cfg.PrivateKey, Public: public, URL: cfg.URL, Pin: cfg.Pin, Name: cfg.Name,
		Keys: func() ([]byte, []byte) { k := s.currentKeys(); return k.private, k.public }}
	s.router = NewRouter(nil, s.log)
	s.router.SetRequested(s.requested)
	s.router.SetSent(metrics.Event)
	s.router.OnPresence(s.presenceHeard)
	s.methods = newMethods(s)
	s.router.handler = s.methods
	s.router.SetOwnership(s)
	s.router.SetPolicyGate(s.policyGate)
	s.router.SetTeam(false, cfg.Version)
	s.joins = newJoins(s)
	s.links = newLinks(s)
	s.signIns = newSignIns(s, cfg.SignIn)
	s.scimTokens = &scimTokens{s: s}
	s.readAPI = &readTokens{s: s}
	s.scimServer = &scim.Server{Directory: scimDirectory{s}, Tokens: s.scimTokens, Log: s.log, URL: func() string {
		base, _ := s.signIns.httpsBase()
		return base + scim.Base
	}}
	s.signInApprovals = newSignInApprovals(s)
	s.copies = newHostCopies(cfg.Store)
	if s.users, err = openUserBook(cfg); err != nil {
		return nil, err
	}
	if s.backups, err = newBackupStore(cfg.Store, s.records, cfg.PrivateKey); err != nil {
		return nil, err
	}
	if cfg.PeerURL != "" {
		if s.peerOrigin, err = controllink.Origin(cfg.PeerURL); err != nil {
			return nil, fmt.Errorf("%s is not an address copies can dial", cfg.PeerURL)
		}
		s.mesh = newMesh(s, cfg.PeerURL, cfg.CopyBeat)
	}
	// Tunnels belong to a single copy: its ssh is the person's on this machine.
	if cfg.PeerURL == "" && !cfg.Hosted {
		s.tunnels = hosttunnels.New(hosttunnels.Config{Store: cfg.Store, Port: cfg.Port, Log: s.log,
			Hosts:   func(context.Context) []records.MachineRecord { return s.records.Hosts() },
			Changed: func(change hosttunnels.Changed) { s.router.BroadcastControl("control/tunnelChanged", change) },
			// Made after the tunnels: read when a tunnel asks.
			Asleep: func(host string) bool { return s.providers != nil && s.providers.Asleep(host) },
			Listed: func(host string) string {
				if s.providers == nil {
					return ""
				}
				return s.providers.Listed(host)
			}})
	}
	s.router.SetCopier(s.copies.take)
	var tunnels hostinstall.Tunnels
	if s.tunnels != nil {
		tunnels = s.tunnels
	}
	s.installer = &hostinstall.Installer{Codes: s.codes, ServerFolder: cfg.ServerFolder,
		ToolsetFolder: cfg.ToolsetFolder,
		Log:           func(format string, args ...any) { s.log(fmt.Sprintf(format, args...)) },
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
	if cfg.PublicWeb != "" {
		// A build that doesn't match its manifest leaves the page off and says so; hosts and
		// clients carry on (071 R3).
		if s.page, err = web.NewPublic(cfg.PublicWeb, cfg.URL, cfg.PublicViews); err != nil {
			s.log(fmt.Sprintf("web: not serving the page at %s: %v", cfg.URL, err))
			s.page = nil
		} else {
			s.log("web: serving the page at " + s.page.Address())
			if views := s.page.ViewsOrigin(); views != "" {
				s.log("web: serving the views' sandbox proxy at " + views)
			}
		}
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
	if s.pushes == nil {
		s.log("notice: no APNs key, so this control plane sends no pushes; a Mac host that relays still does")
	}
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
		s.noteTeam()
		if kept, err := s.readPolicy(ctx); err == nil {
			s.notePolicy(kept)
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
		srv := timeouts(&http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second, ErrorLog: nil})
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
	go s.renewTokensEvery(time.Minute)
	go s.signIns.checkEvery(time.Hour, s.stop)
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
	public := s.publicKey()
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
	// The key before a rotation (#997), and a rotation that stopped half way.
	previous, err := s.takeUpPreviousKey(ctx, made)
	if err != nil {
		return err
	}
	if _, err := s.records.ChangeSettings(ctx, func(settings *records.Settings) {
		if previous != nil && !bytes.Equal(settings.PreviousKey, previous) {
			now := records.Now()
			settings.PreviousKey, settings.RotatedAt = previous, &now
		}
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
	// People (#994): the existing person becomes the local owner and the admin.
	if err := s.records.Migrate(ctx); err != nil {
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
	// The entries still queued are kept, for a while (#2433).
	ctx, cancel := context.WithTimeout(context.Background(), auditDrain)
	s.auditWriter.Close(ctx)
	cancel()
}

// auditDrain is how long Stop waits for the audit's queued entries.
const auditDrain = 10 * time.Second

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
	// A read that ran within readAgainEvery (for a member not known yet) is as good as
	// this one: the records are held to it all the same.
	ran, err := s.reads.read(func() error { return s.records.Load(context.Background()) })
	if err != nil {
		s.setReady(false)
		s.log("store: " + err.Error())
		return
	}
	if ran {
		s.setReady(true)
	}
	for _, h := range s.records.Hosts() {
		s.router.Know(h.ID)
	}
	s.reconcile()
	s.router.HoldToOwners()
	s.noteTeam()
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
func (s *Service) thisMacHost() *MachineJoinStatus {
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
	s.tellHostClients()
}

// hostClients is machine/clients: every paired window of the host's owner and its key,
// which a host checks its local socket against (#1118). Only a Mac's window is on the
// same machine as a host, and only its own person's reaches it there (FR-020).
func (s *Service) hostClients(host string) wire.MachineClients {
	return s.hostClientsFrom(host, s.macWindows())
}

// hostClientsFrom is hostClients from the windows macWindows read once for every host
// told, not once per host (#2059).
func (s *Service) hostClientsFrom(host string, windows map[string][]wire.MachineClient) wire.MachineClients {
	owner := s.ownerOf(host)
	out := wire.MachineClients{Clients: windows[owner], User: &owner}
	if out.Clients == nil {
		out.Clients = []wire.MachineClient{}
	}
	return out
}

// macWindows is every paired Mac window with a key, by its person, in the order paired.
func (s *Service) macWindows() map[string][]wire.MachineClient {
	local := s.localOwner()
	out := map[string][]wire.MachineClient{}
	for _, c := range s.records.Clients() {
		if c.Kind != records.KindMac || len(c.PublicKey) == 0 {
			continue
		}
		// PersonOf, from the record in hand.
		person := local
		if c.Owner != nil && *c.Owner != "" {
			person = *c.Owner
		}
		out[person] = append(out[person], wire.MachineClient{ID: wire.UUID(c.ID), Kind: c.Kind, PublicKey: c.PublicKey,
			Person: &person})
	}
	return out
}

// toldClients is a hash of the machine/clients each host whose uplink ends here was told last.
type toldClients struct {
	mu   sync.Mutex
	last map[string][sha256.Size]byte
}

// tellHostClients tells each host whose uplink ends here which windows it may let in on its
// local socket, so a window forgotten here is cut off there too. A host hears the list only
// when it differs from the one it heard last, not on every refresh (#1528). The hosts named
// (a host that says machine/hello, after a new uplink) hear it in any case.
func (s *Service) tellHostClients(only ...string) {
	s.told.mu.Lock()
	defer s.told.mu.Unlock()
	held := s.router.HostsHeldHere()
	hosts := only
	if len(hosts) == 0 {
		hosts = held
		// A host whose uplink went is told again when it says hello; forget it until then.
		for host := range s.told.last {
			if !slices.Contains(held, host) {
				delete(s.told.last, host)
			}
		}
	}
	if len(hosts) == 0 {
		return
	}
	if s.told.last == nil {
		s.told.last = map[string][sha256.Size]byte{}
	}
	windows := s.macWindows()
	for _, host := range hosts {
		clients := s.hostClientsFrom(host, windows)
		b, _ := json.Marshal(clients)
		sum := sha256.Sum256(b)
		if len(only) == 0 && s.told.last[host] == sum {
			continue
		}
		if s.router.Tell(host, wire.NotifyMachineClients.Name, clients) {
			s.told.last[host] = sum
		} else {
			delete(s.told.last, host)
		}
	}
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
	for _, relay := range relays {
		// A relay carries only its own person's devices (#994).
		owner := s.ownerOf(relay)
		devices := []device{}
		for _, c := range s.records.Clients() {
			// A browser has no mailbox to carry for (071), and a Mac's window no relay.
			if c.IsDevice() && len(c.PublicKey) > 0 && s.PersonOf(c.ID) == owner {
				devices = append(devices, device{c.ID, c.PublicKey})
			}
		}
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
	s.router.OnLinkChanged(func(client string, relayed *bool) {
		if relayed == nil {
			s.log("client " + client + " disconnected")
		}
		m.broadcast(peerLinkLine(client, relayed))
	})
	m.start()
}

// presenceHeard is a presence report a client made here: the other copies fold it, and a
// device's own word on whether it may show a notification is kept.
func (s *Service) presenceHeard(client string, device bool, report json.RawMessage) {
	var p wire.PresenceReport
	if device && json.Unmarshal(report, &p) == nil && p.MayNotify != nil {
		s.keepMayNotify(client, *p.MayNotify)
	}
	if s.mesh != nil {
		grant := records.LegacyGrant
		if device {
			grant = "device"
		}
		s.mesh.broadcast(encodePeer("presence", map[string]any{"client": client, "grant": grant, "report": report}))
	}
}

// keepMayNotify keeps a device's MayNotify in its record (#1509). A locked phone's
// session ends, and its report with it, so a need finds the phone only by its record.
// A move carries the record. A copy that is frozen for a move writes nothing.
func (s *Service) keepMayNotify(client string, may bool) {
	if c := s.records.Client(client); c == nil || c.MayNotify != nil && *c.MayNotify == may || s.phase.now() != phaseServing {
		return
	}
	err := s.records.ChangeClient(context.Background(), client, func(c *records.ClientRecord) bool {
		if c.MayNotify != nil && *c.MayNotify == may {
			return false
		}
		c.MayNotify = &may
		return true
	})
	if err != nil {
		s.log("notice: could not keep whether " + client + " may be notified: " + err.Error())
	}
}

// heard is a host's attention/need (R6): what to post where, told to the relay host held
// here. With no relay host here, a need reaches only the clients connected to its host,
// over their own channels. It goes only to the devices of the host's owner (#994).
func (s *Service) heard(host string, params json.RawMessage) {
	var need notices.AttentionNeed
	if json.Unmarshal(params, &need) != nil {
		return
	}
	// A bot has no devices: its machines' needs go to the admins (#1761, FR-032).
	if owner := s.ownerOf(host); s.isBot(owner) {
		for _, p := range s.records.People() {
			if p.IsAdmin() {
				s.deliver(need, false, p.ID)
			}
		}
		return
	}
	s.deliver(need, false, s.ownerOf(host))
}

// deliver posts a need through the relay host if it is held here. With none here but one
// online at another copy, it tells the other copies. With no relay host online anywhere,
// the copy that heard the need from its host pushes it through APNs itself (#1460), and
// no other copy does, so a notice goes one way and arrives once.
//
// owner is the person whose devices it goes to; "" (from an older copy) is every device.
func (s *Service) deliver(need notices.AttentionNeed, fromPeer bool, owner string) {
	relays := []string{}
	for _, r := range s.router.RelaysHeldHere() {
		if owner == "" || s.ownerOf(r) == owner {
			relays = append(relays, r)
		}
	}
	relay := ""
	if len(relays) > 0 {
		sort.Strings(relays)
		relay = relays[0]
	} else {
		if fromPeer {
			return
		}
		if s.pushes == nil || s.router.RelayOnline() {
			if s.mesh != nil {
				s.mesh.broadcast(encodeNeed(need, owner))
			}
			// Each way a need ends here with nothing sent is said (#1509).
			if need.Need != nil {
				needID, _ := json.Marshal(need.Need.ID)
				switch {
				case s.router.RelayOnline():
					s.log(fmt.Sprintf("notice: %s goes to the copy that holds the relay", needID))
				case s.mesh != nil:
					s.log(fmt.Sprintf("notice: %s goes to the other copies: no relay here, and this copy does not push", needID))
				default:
					s.log(fmt.Sprintf("notice: %s goes to no device: no relay is online, and this copy does not push", needID))
				}
			}
			return
		}
	}
	flags := s.router.NotifyFlags()
	var devices []notices.Device
	for _, c := range s.records.Clients() {
		if !c.IsDevice() || len(c.PublicKey) == 0 || owner != "" && s.PersonOf(c.ID) != owner {
			continue
		}
		// Pushed from here, only a device that gave its token can be chosen.
		if relay == "" && c.PushToken == nil {
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
	noDevice := need.Need != nil && !slices.ContainsFunc(devices, func(d notices.Device) bool { return d.MayNotify != nil && *d.MayNotify })
	if noDevice {
		needID, _ := json.Marshal(need.Need.ID)
		s.log(fmt.Sprintf("notice: %s goes to no device: none here may be notified", needID))
	}
	deliveries := s.desk.Heard(need, s.router.FoldedPresences(), devices, time.Now())
	if need.Need != nil && !noDevice && len(deliveries) == 0 {
		needID, _ := json.Marshal(need.Need.ID)
		s.log(fmt.Sprintf("notice: %s sent to no device: it is watched, at the Mac, or sent already", needID))
	}
	for _, delivery := range deliveries {
		did := "sent"
		if delivery.Headline == nil {
			did = "withdrew"
		}
		needID, _ := json.Marshal(delivery.NeedID)
		// A withdrawal goes the way its post went.
		if relay == "" || s.pushes != nil && delivery.Headline == nil && s.pushes.pushedHere(delivery) {
			s.pushes.deliver(delivery)
			s.log(fmt.Sprintf("notice: %s %s for %s through APNs", did, needID, delivery.Device))
			continue
		}
		s.router.Tell(relay, "relay/deliver", delivery)
		s.log(fmt.Sprintf("notice: %s %s for %s to relay %s", did, needID, delivery.Device, relay))
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
	case (path == "/v1/install.sh" || strings.HasPrefix(path, "/v1/servers/") || strings.HasPrefix(path, "/v1/toolsets/")) && !s.mayDownload(r):
		plain(w, http.StatusTooManyRequests, "too many downloads from this address; try again in a minute\n")
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
		http.NewResponseController(w).SetWriteDeadline(time.Now().Add(downloadWriteTimeout))
		w.Write(data)
	case strings.HasPrefix(path, "/v1/toolsets/"):
		data, ok := toolsetFile(strings.TrimPrefix(path, "/v1/toolsets/"), s.cfg.ToolsetFolder)
		if !ok {
			plain(w, http.StatusNotFound, "this control plane has no such toolset\n")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)
	case strings.HasPrefix(path, "/v1/oidc/"):
		s.signIns.serveOIDC(w, r)
	case path == scim.Base || strings.HasPrefix(path, scim.Base+"/"):
		s.scimServer.ServeHTTP(w, r)
	case path == readAPIPath:
		s.readAPI.serve(w, r)
	case path == "/v1/join" || strings.HasPrefix(path, "/v1/join/"):
		s.joins.serve(w, r)
	case path == "/v1/connect":
		// Refused before the socket opens, so a refused source costs a reply and no more.
		source := s.sources.of(r)
		if s.full() {
			s.refusals.note("full", "", fmt.Sprintf("refused a connection from %s: %d sockets are open, the most this copy holds", source, s.socketsMost))
			w.Header().Set("Retry-After", "60")
			plain(w, http.StatusServiceUnavailable, "this control plane has too many connections; try again in a minute\n")
			return
		}
		proved, ok := s.sources.enter(source)
		if !ok {
			w.Header().Set("Retry-After", "60")
			plain(w, http.StatusTooManyRequests, "too many tries from this address; try again in a minute\n")
			return
		}
		// The page's own socket (#1459): its exchange is bound to the page's origin, and only
		// a browser proves anything on it. Every other socket is a window's, a phone's or a
		// host's, as before.
		webOrigin := ""
		if s.page != nil && s.page.FromPage(r.Header) {
			webOrigin = s.page.Origin()
		}
		// A socket stays open as long as it is used: the listener's timeouts are for requests.
		noDeadlines(w)
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			proved(false)
			return
		}
		go s.accept(s.adopt(newConn(ws, source)), webOrigin, proved)
	default:
		if s.page != nil && s.page.Serve(w, r) {
			return
		}
		plain(w, http.StatusNotFound, "not here\n")
	}
}

func plain(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	w.Write([]byte(text))
}

// full says as many sockets are open as this copy holds (#2150).
func (s *Service) full() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sockets) >= s.socketsMost
}

// mayDownload takes one of the address's downloads, and logs a refusal once a minute.
func (s *Service) mayDownload(r *http.Request) bool {
	source := s.sources.of(r)
	if s.downloads.allow(source) {
		return true
	}
	s.refusals.note("download", keyOf(source), "refused downloads from "+keyOf(source)+": over the rate")
	return false
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
			s.accept(s.adopt(newConn(ws, remote)), origin, nil)
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
// origin, never to anything the peer says (071, FR-006). proved, when not nil, is told
// once whether the socket proved a key, for its source's budget (P3).
func (s *Service) accept(conn *Conn, webOrigin string, proved func(failed bool)) {
	s.acceptVia(conn, webOrigin, proved, "")
}

// acceptVia is accept, for a socket a host carries from its loopback listener (#1480):
// via is that host, and webOrigin its listener's origin.
func (s *Service) acceptVia(conn *Conn, webOrigin string, proved func(failed bool), via string) {
	settle := func(failed bool) {
		if proved != nil {
			proved(failed)
			proved = nil
		}
	}
	defer settle(false)
	serverNonce := controllink.Nonce()
	keys := s.currentKeys()
	hello := controllink.Hello{V: int64(controllink.Version), Name: s.cfg.Name, Control: controllink.B64URL(keys.public),
		Nonce: controllink.B64URL(serverNonce), Copy: s.copyID}
	if keys.previousPublic != nil {
		hello.Previous = new(controllink.B64URL(keys.previousPublic))
	}
	// why says more of a refusal in the log, where the reason alone says too little.
	why := ""
	refuse := func(err error) {
		var r *controllink.Refusal
		refused := errors.As(err, &r)
		// A store that can't be read is not the peer's failure; any other refusal is.
		var theirs notTheirs
		settle(refused && !errors.As(err, &theirs))
		if refused {
			conn.SendNow(controllink.Message{Refused: r.Reason}.Line())
			s.log(fmt.Sprintf("refused a connection from %s: %s%s", conn.Remote, r.Reason, why))
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
		// Nothing proved in time counts as a failed proof.
		settle(true)
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
		// On the loopback listener only a browser or its code may prove anything (071). The
		// page on this domain also signs in with an org provider (#1002, FR-027): an s:
		// whose ticket comes back to it.
		signingIn := strings.HasPrefix(auth.ID, "s:") && s.page != nil && webOrigin == s.page.Origin()
		if !strings.HasPrefix(auth.ID, "c:") && !strings.HasPrefix(auth.ID, "p:") && !signingIn {
			refuse(controllink.Refuse(controllink.Unknown))
			return
		}
		bound = []string{webOrigin}
	}
	var shared []byte
	verify := func(private []byte) (controllink.Identity, []byte, error) {
		return controllink.Verify(auth, serverNonce, bound, func(id controllink.Identity) ([]byte, error) {
			// A client signing in with no code (#995): its new key, which it proves here.
			if id.Kind == 's' {
				key, err := s.signIns.key(id, auth.PublicKey, private)
				admittedAny, shared = err == nil, key
				return key, err
			}
			key, c, h, err := s.keyWith(id, private)
			client, host, admittedAny, shared = c, h, err == nil, key
			return key, err
		})
	}
	id, mac, err := verify(keys.private)
	// A member that still trusts the key before a rotation proves itself with it (#997),
	// and is given the new one in ok.
	var offer *controllink.NewKeyOffer
	if r := (*controllink.Refusal)(nil); errors.As(err, &r) && r.Reason == controllink.BadProof && keys.previousPrivate != nil &&
		(strings.HasPrefix(auth.ID, "c:") || strings.HasPrefix(auth.ID, "h:") || strings.HasPrefix(auth.ID, "w:")) {
		if id, mac, err = verify(keys.previousPrivate); err == nil {
			offer = newKeyFor(shared, keys.public)
		}
	}
	if err != nil {
		// A host refused for ever, and nothing else would say why (#1996).
		if r := (*controllink.Refusal)(nil); errors.As(err, &r) && r.Reason == controllink.BadProof && id.Kind == 'h' {
			why = " (host " + id.ID + " proved a key that is not the one it enrolled with; it must join again with a new host code)"
		}
		refuse(err)
		return
	}
	settle(false)
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
	case (phase == phaseFrozen || phase == phaseForwarding) && (id.Kind == 'p' || id.Kind == 'e' || id.Kind == 'w' || id.Kind == 's'):
		refuse(controllink.Refuse(controllink.Unknown))
		return
	case phase == phaseForwarding && (id.Kind == 'c' || id.Kind == 'h') && s.phase.forwardingUntil().Before(time.Now()):
		// Forwarding ended (30 days at most): anyone still to hear pairs again.
		refuse(controllink.Refuse(controllink.Unknown))
		return
	}
	// A browser's key works only through a page's socket (the loopback listener's, or the
	// page on this domain's, #1459), and nothing else's does there (071).
	if client != nil && (client.Kind == records.KindBrowser) != (webOrigin != "") {
		refuse(controllink.Refuse(controllink.Unknown))
		return
	}
	// A client key, or a person, holding as many sockets as it may (#2150): not a verdict
	// on it, so it tries again later, and logged once a minute. Said as crowded, not
	// unavailable, so a page can tell its person to close a tab (#2194).
	if client != nil && s.router.Crowded(client.ID) {
		settle(false)
		conn.SendNow(controllink.Message{Refused: controllink.Crowded}.Line())
		s.refusals.note("crowded", client.ID, fmt.Sprintf("refused a connection from %s: client %s holds as many sockets as it may", conn.Remote, client.ID))
		conn.Close()
		return
	}
	// A page a host carries (#1480): from a host that runs agents and whose uplink is up,
	// for a port it can listen on. Its origin is http://localhost:<page>, never anything
	// else, and the page proves itself to this control plane after the ok, bound to it.
	var pageOrigin string
	if id.Kind == 'w' {
		h := s.records.Host(host)
		switch {
		case auth.Page == nil || *auth.Page < 1 || *auth.Page > 65535:
			refuse(controllink.Refuse(controllink.BadMessage))
			return
		case h == nil || (h.Relay != nil && *h.Relay):
			refuse(controllink.Refuse(controllink.Unknown))
			return
		case !s.router.Reaches(host):
			refuse(controllink.Refuse(controllink.Unavailable))
			return
		}
		pageOrigin = web.OriginFor(int(*auth.Page))
	} else if auth.Page != nil {
		refuse(controllink.Refuse(controllink.BadMessage))
		return
	}
	// Only a client signing in says its key in the auth line.
	if (id.Kind == 's') != (len(auth.PublicKey) > 0) {
		refuse(controllink.Refuse(controllink.BadMessage))
		return
	}
	// A device through agents-relay (T096): the exchange is its own, end to end, and it
	// says it came that way, for itself only.
	relayed := auth.Kind == "relay"
	if relayed && (id.Kind != 'c' || deref(auth.For) != id.ID || client == nil || !client.IsDevice()) {
		refuse(controllink.Refuse(controllink.BadMessage))
		return
	}
	// Once a list has been announced, every member is given it (R16).
	settings := s.records.Settings()
	ok2 := controllink.OK{Mac: controllink.B64URL(mac), Host: optional(wire.MachineRef(host)), NewKey: offer}
	if client != nil {
		ok2.Grant = new(records.LegacyGrant)
	}
	if relayed {
		ok2.Relayed = &relayed
	}
	if settings != nil && settings.Epoch != nil {
		ok2.Endpoints = currentEndpoints(settings)
		ok2.Epoch = int64Of(settings.Epoch)
	}
	if err := conn.SendNow(controllink.Message{OK: &ok2}.Line()); err != nil {
		conn.Close()
		return
	}
	// A member that says an epoch keeps a list, and takes the one just given.
	if auth.Epoch != nil {
		epoch := int(*auth.Epoch)
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
	// The largest message by what proved a key (#2150): a host or a copy carries files and
	// records, a client its largest upload, and a code or a page's exchange little.
	switch id.Kind {
	case 'c':
		conn.SetReadLimit(clientMessageMost)
	case 'h', 'x':
		conn.SetReadLimit(peerMessageMost)
	}
	switch id.Kind {
	case 'c':
		s.router.AttachClient(client, conn, relayed, auth.Capabilities)
		// Forgotten while it joined (#1229): the forget's sweep of sessions may have come
		// before this one was attached, and admitting it would write it back over its
		// tombstone. It is closed as any forgotten client is.
		if s.records.Client(client.ID) == nil && s.records.WasForgotten(client.ID) {
			s.router.ForgetClient(client.ID)
			return
		}
		if err := s.methods.Admit(context.Background(), *client); err != nil {
			s.log("store: could not note " + client.Name + " connecting: " + err.Error())
		}
		s.renewClient(context.Background(), client.ID)
		through := ""
		if relayed {
			through = " through the relay"
		}
		if via != "" {
			through = " through " + via + "'s loopback listener"
		}
		s.log(fmt.Sprintf("client %s (%s) connected%s from %s", client.Name, client.Kind, through, conn.Remote))
	case 'h':
		s.hostArrived(host, conn)
	case 'w':
		// The page's own exchange, on the same socket, bound to the host's listener.
		s.log(fmt.Sprintf("host %s carries a page from %s", host, pageOrigin))
		s.acceptVia(conn, pageOrigin, nil, host)
	case 'p', 'e':
		s.spend(conn, id.ID, webOrigin)
	case 's':
		s.signIns.pairing(conn, id.ID, auth.PublicKey, serverNonce)
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
	return s.keyWith(id, s.privateKey())
}

// keyWith is key, with the control plane's key now or the one before a rotation (#997).
func (s *Service) keyWith(id controllink.Identity, private []byte) ([]byte, *records.ClientRecord, string, error) {
	// Being filled by a handover, its records are not whole yet: try again, which says
	// nothing about the member (#81), where unknown would have a browser forget its key.
	if id.Kind != 'x' && s.phase.now() == phaseReceiving {
		return nil, nil, "", notTheirs{controllink.Refuse(controllink.Unavailable)}
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
			return nil, nil, "", notTheirs{controllink.Refuse(controllink.Unavailable)}
		}
		if c == nil || len(c.PublicKey) == 0 {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		// Not used for its whole lifetime (#997): it pairs again.
		if keyExpired(c.Expires, time.Now()) {
			return nil, nil, "", controllink.Refuse(controllink.Expired)
		}
		// Its person's org provider suspended them (#1002, D13): it keeps its key.
		if c.Owner != nil && s.suspended(*c.Owner) {
			return nil, nil, "", controllink.Refuse(controllink.Suspended)
		}
		key, err := controllink.ClientKey(private, c.PublicKey, c.ID)
		if err != nil {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return key, c, "", nil
	case 'h', 'w':
		if s.records.Host(id.ID) == nil {
			if err := s.readAgain(); err != nil {
				return nil, nil, "", err
			}
		}
		h := s.records.Host(id.ID)
		if h == nil && s.records.HostUnreadable(id.ID) {
			return nil, nil, "", notTheirs{controllink.Refuse(controllink.Unavailable)}
		}
		if h == nil || len(h.PublicKey) == 0 {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		if keyExpired(h.Expires, time.Now()) {
			return nil, nil, "", controllink.Refuse(controllink.Expired)
		}
		key, err := controllink.HostKey(private, h.PublicKey, h.ID)
		if err != nil {
			return nil, nil, "", controllink.Refuse(controllink.Unknown)
		}
		return key, nil, h.ID, nil
	case 'p', 'e':
		// Spent or not: a join replayed by the key that spent it is told apart in announce.
		stored, err := s.codes.Stored(context.Background(), id.ID, true)
		if err != nil {
			var r *controllink.Refusal
			if errors.As(err, &r) {
				return nil, nil, "", err
			}
			// The store's error may name the code's key: it stays out of the log.
			s.log("store: could not read a code")
			return nil, nil, "", notTheirs{controllink.Refuse(controllink.Unavailable)}
		}
		wanted := (id.Kind == 'e') == (stored.Purpose == "host")
		secret := controllink.CodeSecret(s.privateKey(), id.ID)
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
		return controllink.CopyKey(s.privateKey()), nil, "", nil
	}
	return nil, nil, "", controllink.Refuse(controllink.Unknown)
}

// readAgainEvery is how often at most a member not in the records reads the store
// again (#174). A stranger's made-up ids cost no more than one read in this time,
// however many there are (public-security.md P1).
const readAgainEvery = 3 * time.Second

// readAgain reads the store again for a member not in the records, or refuses as
// unavailable when it cannot: not known yet is not the same as not a member. It shares
// the read already running, and within readAgainEvery of the last read it refuses as
// unavailable at once, so the member tries again.
func (s *Service) readAgain() error {
	ran, err := s.reads.read(func() error { return s.records.Load(context.Background()) })
	if err != nil {
		s.log("store: could not read it to admit a member: " + err.Error())
		return notTheirs{controllink.Refuse(controllink.Unavailable)}
	}
	if !ran {
		return controllink.Refuse(controllink.Unavailable)
	}
	return nil
}

// notTheirs is a refusal that says nothing about the peer: the store can't be read, or a
// handover is filling this copy. Its source's budget doesn't count it (P3).
type notTheirs struct{ error }

func (e notTheirs) Unwrap() error { return e.error }

// readGate runs one read at a time, and at most one every so often, whatever the number
// of callers: one that comes while a read runs waits for it, and has its result.
type readGate struct {
	every   time.Duration
	mu      sync.Mutex
	last    time.Time
	running *gateRead
}

type gateRead struct {
	done chan struct{}
	err  error
}

// read runs read, or shares the one running. ran is false when a read finished within
// every: the caller goes by what is in memory.
func (g *readGate) read(read func() error) (ran bool, err error) {
	g.mu.Lock()
	if r := g.running; r != nil {
		g.mu.Unlock()
		<-r.done
		return true, r.err
	}
	if !g.last.IsZero() && time.Since(g.last) < g.every {
		g.mu.Unlock()
		return false, nil
	}
	r := &gateRead{done: make(chan struct{})}
	g.running = r
	g.mu.Unlock()
	r.err = read()
	g.mu.Lock()
	g.running, g.last = nil, time.Now()
	g.mu.Unlock()
	close(r.done)
	return true, r.err
}

// hostArrived takes a host's uplink: its first line is machine/hello on channel 0 (kept
// from the first build), then the router reads it.
func (s *Service) hostArrived(host string, conn *Conn) {
	first, err := conn.ReadWithin(15 * time.Second)
	f, ok := readHostFrame(first)
	var m *message
	if err == nil && ok && f.channel == 0 && !f.close && !f.open && f.channels == nil {
		m, ok = decode(f.msg)
	}
	if err != nil || !ok || m == nil || m.Method != "machine/hello" || !m.isRequest() {
		s.log("host " + host + " connected without saying hello; closing it")
		conn.Close()
		return
	}
	s.router.AttachHost(host, conn)
	s.renewHost(context.Background(), host)
	// This copy holds the host now (T063): every peer reaches it through here.
	if s.mesh != nil {
		if epoch, err := s.mesh.leases.take(context.Background(), host); err == nil {
			s.mesh.holding(host, epoch)
		} else {
			s.log("the store would not give " + host + "'s lease to this copy; serving it anyway")
		}
	}
	result, err := s.methods.HostSaid(host, "machine/hello", m.Params)
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
// (wire.md). webOrigin is the page's origin for a socket from a page, else "".
func (s *Service) spend(conn *Conn, id string, webOrigin string) {
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
	result, err := s.spendCode(id, m.Method, m.Params, webOrigin)
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

func (s *Service) spendCode(id, method string, params json.RawMessage, webOrigin string) (*wire.Admitted, error) {
	ctx := context.Background()
	fromPage := webOrigin != ""
	stored, err := s.codes.Stored(ctx, id, true)
	if err != nil {
		return nil, err
	}
	// A code a removed person made does nothing now (FR-029).
	if stored.Owner != nil {
		if p := s.records.Person(*stored.Owner); p != nil && p.IsRemoved() {
			return nil, controllink.Refuse(controllink.Unknown)
		}
	}
	switch {
	case stored.Purpose == "client" && method == "clients/announce":
		var said wire.ClientAnnounce
		if json.Unmarshal(params, &said) != nil || len(said.PublicKey) == 0 || !controllink.IsUUID(string(said.ID)) {
			return nil, fail(invalidParams, "Say who you are.")
		}
		// A kind a later build added reads as unknown (ClientKind's fallback).
		a := struct {
			ID, Name, Kind string
			PublicKey      []byte
		}{strings.ToUpper(string(said.ID)), said.Name, string(said.Kind), said.PublicKey}
		// A browser pairs through a page, and only a browser does (071, #1459).
		if (a.Kind == records.KindBrowser) != fromPage {
			return nil, fail(invalidParams, "Pair that kind of client elsewhere.")
		}
		// And with a code made for one, which is good nowhere else (R2): on the page on the
		// Mac or on this domain's. Refused before it is spent, so the browser it was made for
		// can still use it.
		browser := stored.Browser != nil && *stored.Browser
		if browser != fromPage {
			if browser {
				return nil, fail(invalidParams, "That code is for a browser. Paste it in the Agents page.")
			}
			return nil, fail(invalidParams, "That code is for a window or a phone. Get one from Add a Browser….")
		}
		name := a.Name
		if a.Kind == records.KindBrowser {
			name = browserName(a.Name, s.page != nil && webOrigin == s.page.Origin())
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
		result := &wire.Admitted{Client: new(wire.UUID(client)), Grant: new(records.LegacyGrant)}
		// The same join again (#212): it paired, and could not keep it.
		if old := s.records.Client(client); sp.replayed && old != nil && bytes.Equal(old.PublicKey, a.PublicKey) {
			s.log(name + " paired again with the code it spent (" + a.Kind + ")")
			return result, nil
		}
		record := records.ClientRecord{ID: client, Name: name, Kind: a.Kind, PublicKey: a.PublicKey, Paired: records.Now(),
			Owner: stored.Owner, Expires: s.newExpiry()}
		// An invite's first client is a new person's (#994).
		if stored.Invite != nil {
			person, err := s.redeemInvite(ctx, id, *stored.Invite)
			if err != nil {
				return nil, err
			}
			record.Owner = &person
		}
		if err := s.methods.Admit(ctx, record); err != nil {
			return nil, err
		}
		s.log(name + " paired (" + a.Kind + ")")
		// Known at every copy at once: the relay host may be held at another.
		s.announce("clientPaired", client, "code")
		return result, nil
	case stored.Purpose == "host" && method == "machines/announce":
		var a wire.MachineAnnounce
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
		result := &wire.Admitted{Host: new(wire.MachineRef(host))}
		// The same join again (#212): it enrolled, and could not keep it.
		if old := s.records.Host(host); sp.replayed && old != nil && bytes.Equal(old.PublicKey, a.PublicKey) {
			s.log("host " + a.Name + " enrolled again as " + host + " with the code it spent")
			return result, nil
		}
		mid := a.MachineID
		// The machine is the person's who made the code (FR-017).
		record := records.MachineRecord{ID: host, Name: a.Name, PublicKey: a.PublicKey, Platform: a.Platform,
			Version: a.Version, MachineID: &mid, Owner: stored.Owner, Expires: s.newExpiry()}
		if relay {
			record.Relay = &relay
		}
		if deref(a.Implementation) != "" {
			impl, _ := json.Marshal(*a.Implementation)
			record.Extra = records.Extra{"implementation": impl}
		}
		// Only ever a new record (#1996): another host's, or its key, is never written over.
		err = s.records.AddHost(ctx, record)
		if errors.Is(err, records.ErrHostTaken) && host == "mac" {
			// Another host on this machine enrolled as mac first, at this copy or another: this
			// one gets an id of its own, and the code says so to a replay.
			other := records.NewHostID()
			if err := s.codes.Respend(ctx, id, spent{PublicKey: a.PublicKey, Host: &other}); err != nil {
				return nil, err
			}
			s.log("host " + a.Name + " joined from this machine as another host enrolled as mac: it enrols as " + other)
			host, record.ID = other, other
			result.Host = new(wire.MachineRef(host))
			err = s.records.AddHost(ctx, record)
		}
		if errors.Is(err, records.ErrHostTaken) {
			s.log("refused host " + a.Name + ": another host is already enrolled as " + host)
			return nil, fail(invalidParams, "Another host is already enrolled as %s. Make a new host code and join again.", host)
		}
		if err != nil {
			return nil, err
		}
		if relay {
			s.router.SetRelay(host, &relay)
		}
		// Every other copy knows it at once.
		s.announce("hostEnrolled", host, "code")
		s.router.Know(host)
		s.router.HoldToOwners()
		s.log("host " + a.Name + " enrolled as " + host)
		return result, nil
	}
	return nil, fail(notPermitted, "That code is not for %s.", method)
}

// browserName is "Safari on Alex's MacBook": the page can't learn the Mac's name, and the
// loopback listener only ever runs on the Mac it names (071, FR-010). A browser that paired
// on the page on this domain (#1459) may be anywhere: "Safari on the web".
func browserName(said string, public bool) string {
	product := strings.TrimSpace(said)
	if r := []rune(product); len(r) > 40 {
		product = strings.TrimSpace(string(r[:40]))
	}
	if product == "" {
		product = "A browser"
	}
	if public {
		return product + " on the web"
	}
	return product + " on " + LocalName()
}
