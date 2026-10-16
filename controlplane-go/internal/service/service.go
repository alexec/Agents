// Package service is ControlService.swift in Go: a store, the router, the methods the
// control plane answers itself, and a WebSocket server every client and host connects to.
// One copy: several copies over one store (US3), handovers (R16), the relay's notices,
// ssh installs, workspace providers and Slack are not in this spike.
package service

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

const Version = "0.1"

type Config struct {
	Store      store.Store
	PrivateKey []byte
	URL        string // the one address clients and hosts are given
	Pin        string
	TLS        *tls.Config // nil behind a load balancer
	Bind       string
	Port       int
	Name       string
	MachineID  string
	HostRoot   string // this Mac's host's root, for control/status (#113)
	Web        *WebConfig
	Log        func(string)
}

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
	web     *WebStatus

	readAgainMu sync.Mutex
	readAgainAt time.Time
	servers     []*http.Server
}

func New(cfg Config) (*Service, error) {
	pub, err := auth.PublicKey(cfg.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("the control plane's key: %w", err)
	}
	origin, err := auth.Origin(cfg.URL)
	if err != nil {
		return nil, fmt.Errorf("%s is not an address clients can dial", cfg.URL)
	}
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	s := &Service{cfg: cfg, public: pub, origin: origin, copyID: strings.ToLower(records.NewUUID()[:8]),
		records: records.New(cfg.Store), started: time.Now()}
	s.codes = &Codes{Store: cfg.Store, Private: cfg.PrivateKey, Public: pub, URL: cfg.URL, Pin: cfg.Pin, Name: cfg.Name}
	s.methods = &Methods{s: s}
	s.router = NewRouter(s.methods, s.log)
	return s, nil
}

func (s *Service) log(line string) { s.cfg.Log("agents-control[" + s.copyID + "]: " + line) }

func (s *Service) Router() *Router { return s.router }
func (s *Service) Codes() *Codes   { return s.codes }

// Start probes the store, takes up its records and listens. Returns the port bound.
func (s *Service) Start(ctx context.Context) (int, error) {
	if err := store.Probe(ctx, s.cfg.Store, s.copyID); err != nil {
		return 0, fmt.Errorf("the store can't be used: %w", err)
	}
	if err := s.records.Load(ctx); err != nil {
		return 0, err
	}
	pub := s.public
	made, err := s.records.SettingsOrMake(ctx, func() records.Settings {
		u, pin := s.cfg.URL, s.cfg.Pin
		st := records.Settings{Name: s.cfg.Name, Port: 8790, MachineID: s.cfg.MachineID, URL: &u, ControlKey: pub}
		if pin != "" {
			st.Pin = &pin
		}
		return st
	})
	if err != nil {
		return 0, err
	}
	if made.ControlKey != nil && string(made.ControlKey) != string(pub) {
		return 0, errors.New("this store belongs to a control plane with another key; give it that key, or another store")
	}
	if _, err := s.records.ChangeSettings(ctx, func(st *records.Settings) {
		u := s.cfg.URL
		st.URL = &u
		st.Pin = nil
		if s.cfg.Pin != "" {
			p := s.cfg.Pin
			st.Pin = &p
		}
		st.ControlKey = pub
	}); err != nil {
		return 0, err
	}
	for _, h := range s.records.Hosts() {
		s.router.Know(h.ID)
		s.router.SetRelay(h.ID, h.Relay)
	}
	if home := s.records.Settings().HomeHost; home != nil {
		s.router.SetHomeHost(*home)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ready") })
	mux.HandleFunc("/v1/connect", func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		go s.accept(newConn(ws, r.RemoteAddr), "")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "not here", http.StatusNotFound) })
	bind := s.cfg.Bind
	if bind == "" {
		bind = "0.0.0.0"
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(bind, fmt.Sprint(s.cfg.Port)))
	if err != nil {
		return 0, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	s.servers = append(s.servers, srv)
	if s.cfg.TLS != nil {
		go srv.Serve(tls.NewListener(ln, s.cfg.TLS))
	} else {
		go srv.Serve(ln)
	}
	if s.cfg.Web != nil {
		s.startWeb(*s.cfg.Web)
	}
	// The backstop for a change made by hand or by a copy this one never heard: the
	// records every 15 s, and a forgotten client's sessions closed.
	go func() {
		for range time.Tick(15 * time.Second) {
			if s.records.Load(context.Background()) == nil {
				for _, h := range s.records.Hosts() {
					s.router.Know(h.ID)
				}
			}
		}
	}()
	s.log(fmt.Sprintf("listening on %s:%d for %s", bind, port, s.cfg.URL))
	return port, nil
}

func (s *Service) Stop() {
	for _, srv := range s.servers {
		srv.Close()
	}
}

// accept is the server's side of the key exchange, then the socket goes where its
// identity says: a client to the router, a host's uplink to the router, a code holder to
// a one-time announce. webOrigin is the loopback listener's origin, or "" for TLS.
func (s *Service) accept(conn *Conn, webOrigin string) {
	serverNonce := auth.Nonce()
	hello := auth.Hello{V: auth.Version, Name: s.cfg.Name, Control: auth.ToB64URL(s.public), Nonce: auth.ToB64URL(serverNonce), Copy: s.copyID}
	refuse := func(err error) {
		var r *auth.Refusal
		if errors.As(err, &r) {
			conn.SendNow(auth.RefusedLine(r.Reason))
			s.log(fmt.Sprintf("refused a connection from %s: %s", conn.Remote, r.Reason))
		} else {
			s.log(fmt.Sprintf("a connection from %s ended: %v", conn.Remote, err))
		}
		conn.Close()
	}
	if err := conn.SendNow(auth.Line("hello", hello)); err != nil {
		conn.Close()
		return
	}
	line, err := conn.ReadWithin(15 * time.Second)
	if err != nil {
		conn.Close()
		return
	}
	a, err := auth.ReadAuth(line)
	if err != nil {
		refuse(err)
		return
	}
	bound := []string{s.origin}
	if webOrigin != "" {
		// On the loopback listener only a browser or its code may prove anything, and only
		// to that listener's own origin (071).
		if !strings.HasPrefix(a.ID, "c:") && !strings.HasPrefix(a.ID, "p:") {
			refuse(auth.Refuse(auth.Unknown))
			return
		}
		bound = []string{webOrigin}
	}
	var client *records.ClientRecord
	var host string
	var code *storedCode
	id, mac, err := auth.Verify(a, serverNonce, bound, func(id auth.Identity) ([]byte, error) {
		k, c, h, sc, err := s.key(id)
		client, host, code = c, h, sc
		return k, err
	})
	if err != nil {
		refuse(err)
		return
	}
	_ = code
	// A browser's key works only through the loopback listener, and nothing else's does there.
	if client != nil && (client.Kind == "browser") != (webOrigin != "") {
		refuse(auth.Refuse(auth.Unknown))
		return
	}
	relayed := a.Kind == "relay"
	if relayed && (id.Kind != 'c' || !strings.EqualFold(a.For, id.ID) || client == nil || !client.IsDevice()) {
		refuse(auth.Refuse(auth.BadMessage))
		return
	}
	ok := auth.OK{MAC: auth.ToB64URL(mac), Host: host}
	if client != nil {
		ok.Grant = "operator"
	}
	if relayed {
		ok.Relayed = &relayed
	}
	if err := conn.SendNow(auth.Line("ok", ok)); err != nil {
		conn.Close()
		return
	}
	switch id.Kind {
	case 'c':
		s.router.AttachClient(client, conn, relayed)
		s.admit(*client)
		s.log(fmt.Sprintf("client %s (%s) connected from %s", client.Name, client.Kind, conn.Remote))
	case 'h':
		s.hostArrived(host, conn)
	case 'p', 'e':
		s.announce(conn, id.ID, webOrigin != "")
	default:
		// Peer copies (x:) link with nobody in this spike.
		conn.Close()
	}
}

// key is the key an identity proves, and what it is admitted as.
func (s *Service) key(id auth.Identity) ([]byte, *records.ClientRecord, string, *storedCode, error) {
	switch id.Kind {
	case 'c':
		// Paired moments ago, or by hand: read the store again, at most once a second.
		if s.records.Client(id.ID) == nil {
			if err := s.readAgain(); err != nil {
				return nil, nil, "", nil, err
			}
		}
		c := s.records.Client(id.ID)
		if c == nil && s.records.WasForgotten(id.ID) {
			return nil, nil, "", nil, auth.Refuse(auth.Forgotten)
		}
		if c == nil && s.records.IsUnreadable(records.ClientKey(id.ID)) {
			return nil, nil, "", nil, auth.Refuse(auth.Unavailable)
		}
		if c == nil || len(c.PublicKey) == 0 {
			return nil, nil, "", nil, auth.Refuse(auth.Unknown)
		}
		k, err := auth.ClientKey(s.cfg.PrivateKey, c.PublicKey, c.ID)
		if err != nil {
			return nil, nil, "", nil, auth.Refuse(auth.Unknown)
		}
		return k, c, "", nil, nil
	case 'h':
		if s.records.Host(id.ID) == nil {
			if err := s.readAgain(); err != nil {
				return nil, nil, "", nil, err
			}
		}
		h := s.records.Host(id.ID)
		if h == nil && s.records.IsUnreadable(records.HostKey(id.ID)) {
			return nil, nil, "", nil, auth.Refuse(auth.Unavailable)
		}
		if h == nil || len(h.PublicKey) == 0 {
			return nil, nil, "", nil, auth.Refuse(auth.Unknown)
		}
		k, err := auth.HostKey(s.cfg.PrivateKey, h.PublicKey, h.ID)
		if err != nil {
			return nil, nil, "", nil, auth.Refuse(auth.Unknown)
		}
		return k, nil, h.ID, nil, nil
	case 'p', 'e':
		// Spent or not: a join replayed by the key that spent it is told apart in announce.
		sc, err := s.codes.Stored(context.Background(), id.ID, true)
		if err != nil {
			return nil, nil, "", nil, err
		}
		wanted := (id.Kind == 'e') == (sc.Purpose == "host")
		secret := auth.CodeSecret(s.cfg.PrivateKey, id.ID)
		if !wanted || secret == nil {
			return nil, nil, "", nil, auth.Refuse(auth.Unknown)
		}
		return auth.CodeKey(secret), nil, "", sc, nil
	case 'x':
		return auth.CopyKey(s.cfg.PrivateKey), nil, "", nil, nil
	}
	return nil, nil, "", nil, auth.Refuse(auth.Unknown)
}

func (s *Service) readAgain() error {
	s.readAgainMu.Lock()
	if time.Since(s.readAgainAt) < time.Second {
		s.readAgainMu.Unlock()
		return auth.Refuse(auth.Unavailable)
	}
	s.readAgainAt = time.Now()
	s.readAgainMu.Unlock()
	if err := s.records.Load(context.Background()); err != nil {
		s.log("store: could not read it to admit a member: " + err.Error())
		return auth.Refuse(auth.Unavailable)
	}
	return nil
}

// admit: lastSeen written at most hourly; a connect is not a write.
func (s *Service) admit(c records.ClientRecord) {
	if c.LastSeen != nil && time.Since(c.LastSeen.Time) < time.Hour {
		return
	}
	now := records.Now()
	c.LastSeen = &now
	if err := s.records.SaveClient(context.Background(), c); err != nil {
		s.records.Load(context.Background())
	}
}

// hostArrived: a host's first line is host/hello on channel 0, then the router reads it.
func (s *Service) hostArrived(host string, conn *Conn) {
	first, err := conn.ReadWithin(15 * time.Second)
	f, ok := readHostFrame(first)
	m, okm := decode(f.msg)
	if err != nil || !ok || f.channel != 0 || !okm || m.Method != "host/hello" {
		s.log("host " + host + " connected without saying hello; closing it")
		conn.Close()
		return
	}
	s.router.AttachHost(host, conn)
	result, err := s.methods.HostSaid(host, "host/hello", m.Params)
	if err != nil {
		conn.Send(channelFrame(0, replyError(m.ID, err)))
	} else {
		conn.Send(channelFrame(0, reply(m.ID, result)))
	}
	s.log("host " + host + " connected")
}

const spentWords = "This code has been used. Ask for a new one."

// announce: someone holding a code says who they are, once, and hangs up.
func (s *Service) announce(conn *Conn, id string, loopback bool) {
	defer func() {
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
		var r *auth.Refusal
		if errors.As(err, &r) {
			if r.Reason == auth.Spent {
				err = fail(notPermitted, spentWords)
			} else {
				err = fail(notPermitted, "That code can't be used: %s.", r.Reason)
			}
		} else if _, isRPC := err.(*rpcError); !isRPC {
			err = storeFailure(err)
		}
		s.log("a " + m.Method + " with a code failed: " + err.Error())
		conn.SendNow(replyError(m.ID, err))
		return
	}
	conn.SendNow(reply(m.ID, result))
}

func (s *Service) spendCode(id, method string, params json.RawMessage, loopback bool) (any, error) {
	c := context.Background()
	sc, err := s.codes.Stored(c, id, true)
	if err != nil {
		return nil, err
	}
	switch {
	case sc.Purpose == "client" && method == "clients/announce":
		var a struct {
			ID        string `json:"id"`
			PublicKey []byte `json:"publicKey"`
			Name      string `json:"name"`
			Kind      string `json:"kind"`
		}
		if json.Unmarshal(params, &a) != nil || len(a.PublicKey) == 0 || !auth.IsUUID(a.ID) {
			return nil, fail(invalidParams, "Say who you are.")
		}
		a.ID = strings.ToUpper(a.ID)
		// A browser pairs through the loopback listener, and only a browser does (071).
		if (a.Kind == "browser") != loopback {
			return nil, fail(invalidParams, "Pair that kind of client elsewhere.")
		}
		if (sc.Browser != nil && *sc.Browser) != loopback {
			if loopback {
				return nil, fail(invalidParams, "That code is for a window or a phone. Get one from Pair a Browser….")
			}
			return nil, fail(invalidParams, "That code is for a browser on this Mac.")
		}
		name := a.Name
		if a.Kind == "browser" {
			name = browserName(a.Name)
		}
		sp, err := s.codes.Spend(c, id, spent{PublicKey: a.PublicKey, Client: &a.ID})
		if err != nil {
			return nil, err
		}
		client := a.ID
		if sp.Client != nil {
			client = strings.ToUpper(*sp.Client)
		}
		admitted := map[string]any{"client": client, "grant": "operator"}
		if old := s.records.Client(client); sp.replayed && old != nil && string(old.PublicKey) == string(a.PublicKey) {
			s.log(name + " paired again with the code it spent (" + a.Kind + ")")
			return admitted, nil
		}
		now := records.Now()
		rec := records.ClientRecord{ID: client, Name: name, Kind: a.Kind, PublicKey: a.PublicKey, Paired: now, LastSeen: &now}
		if err := s.records.SaveClient(c, rec); err != nil {
			return nil, err
		}
		s.log(name + " paired (" + a.Kind + ")")
		s.router.BroadcastControl("control/clientChanged", map[string]any{"client": client})
		return admitted, nil
	case sc.Purpose == "host" && method == "hosts/announce":
		var a struct {
			PublicKey []byte `json:"publicKey"`
			Name      string `json:"name"`
			Platform  string `json:"platform"`
			Version   string `json:"version"`
			MachineID string `json:"machineID"`
			Relay     *bool  `json:"relay"`
		}
		if json.Unmarshal(params, &a) != nil {
			return nil, fail(invalidParams, "Say which host you are.")
		}
		// The host on the control plane's own machine is its home host, mac.
		relay := a.Relay != nil && *a.Relay
		home := s.cfg.MachineID != "" && a.MachineID == s.cfg.MachineID && s.records.Host("mac") == nil && !relay
		want := records.MakeHostID()
		if home {
			want = "mac"
		}
		sp, err := s.codes.Spend(c, id, spent{PublicKey: a.PublicKey, Host: &want})
		if err != nil {
			return nil, err
		}
		if sp.Host == nil {
			return nil, auth.Refuse(auth.Spent)
		}
		host := *sp.Host
		if old := s.records.Host(host); sp.replayed && old != nil && string(old.PublicKey) == string(a.PublicKey) {
			return map[string]any{"host": host}, nil
		}
		mid := a.MachineID
		rec := records.HostRecord{ID: host, Name: a.Name, PublicKey: a.PublicKey, Platform: a.Platform, Version: a.Version, MachineID: &mid}
		if relay {
			rec.Relay = &relay
		}
		if err := s.records.SaveHost(c, rec); err != nil {
			return nil, err
		}
		if relay {
			s.router.SetRelay(host, &relay)
		}
		s.router.Know(host)
		s.log("host " + a.Name + " enrolled as " + host)
		return map[string]any{"host": host}, nil
	}
	return nil, fail(notPermitted, "That code is not for %s.", method)
}

func browserName(said string) string {
	product := strings.TrimSpace(said)
	if len(product) > 40 {
		product = product[:40]
	}
	if product == "" {
		product = "A browser"
	}
	return product + " on " + LocalName()
}

func contextBackground() context.Context { return context.Background() }
