package hosted

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
)

// Each account's control plane is a copy in this process, on a port of its own on
// loopback, started the first time it is asked for and stopped when it has had no
// request for idleLimit (P20261020-23). A request still open (a host's uplink, a
// client's WebSocket: the proxy holds it until it ends) keeps it in use.

type copyRunning struct {
	service *controlplane.Service
	proxy   *httputil.ReverseProxy
	// Its store, held to its plan (#2224, limits.go).
	limits *limitedStore
	// Its gate on agents running at once, held to its plan (#2243, limits.go).
	agents *agentsCap
	// Under Service.mu: the requests open now, and when the last one ended.
	open int
	last time.Time
	// Under Service.mu: its WebSockets open now, against the plan's connections.
	sockets int
	// When the sweep last deleted its old events.
	eventsSwept time.Time
}

// loopback is where this service reaches its copies from: they believe its
// X-Forwarded-For, which is one address, decided by clientOf.
var loopback = []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32"), netip.MustParsePrefix("::1/128")}

// copyFor is an account's running copy, started if it is not running, and in use until
// done is called with it.
func (s *Service) copyFor(ctx context.Context, id string) (*copyRunning, error) {
	for {
		s.mu.Lock()
		if s.stopped {
			s.mu.Unlock()
			return nil, errors.New("the service is stopping")
		}
		if c := s.copies[id]; c != nil {
			c.open++
			s.mu.Unlock()
			return c, nil
		}
		wait, busy := s.starting[id]
		if !busy {
			// At the most copies (#2152 FR-007): the one idle longest makes room, or none.
			if len(s.copies)+len(s.starting) >= s.cfg.MaxCopies {
				room := s.makeRoomLocked()
				s.mu.Unlock()
				if !room {
					return nil, errFull
				}
				continue
			}
			done := make(chan struct{})
			s.starting[id] = done
			s.mu.Unlock()
			c, err := s.startCopy(ctx, id)
			s.mu.Lock()
			delete(s.starting, id)
			if err == nil {
				if s.stopped {
					c.service.Stop()
					err = errors.New("the service is stopping")
				} else {
					c.open = 1
					s.copies[id] = c
				}
			}
			s.mu.Unlock()
			close(done)
			return c, err
		}
		s.mu.Unlock()
		select {
		case <-wait:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

func (s *Service) startCopy(ctx context.Context, id string) (*copyRunning, error) {
	acc, err := s.accounts.get(ctx, id)
	if err != nil {
		return nil, err
	}
	if acc == nil {
		return nil, errors.New("the account is gone")
	}
	st, err := s.limitedFor(ctx, acc)
	if err != nil {
		return nil, fmt.Errorf("its store's size: %w", err)
	}
	key, err := kms.Kept{Store: st, Keeper: s.cfg.Keeper}.ControlKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("its control key: %w", err)
	}
	trusted := append(append([]netip.Prefix(nil), loopback...), s.cfg.TrustedProxies...)
	views := ""
	if s.cfg.ViewsDomain != "" {
		views = "https://" + s.cfg.ViewsDomain
	}
	agents := &agentsCap{plan: PlanOf(acc), account: "https://" + s.cfg.Domain + "/account"}
	cfg := controlplane.Config{Store: st, PrivateKey: key, URL: s.accountURL(id), Bind: "127.0.0.1", Port: 0,
		Name: "Your control plane", MachineID: "hosted-" + id, PublicWeb: s.cfg.Web, PublicViews: views,
		TrustedProxies: trusted, Hosted: true, SecretKeeper: s.cfg.Keeper, AgentsRunningGate: agents.gate,
		Log: func(line string) { s.log(id + ": " + line) }}
	service, err := controlplane.New(cfg)
	if err != nil {
		return nil, err
	}
	port, err := service.Start(ctx)
	if err != nil {
		service.Stop()
		return nil, err
	}
	target := &url.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", port)}
	proxy := &httputil.ReverseProxy{FlushInterval: -1, Rewrite: func(pr *httputil.ProxyRequest) {
		pr.SetURL(target)
		// The copy answers only at its own name (DNS rebinding): the request keeps it.
		pr.Out.Host = pr.In.Host
		// Where the request came from, as one address: the copy believes it from
		// loopback and counts clients by it.
		pr.Out.Header.Set("X-Forwarded-For", s.clientOf(pr.In))
	}}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		s.log(id + ": proxy: " + err.Error())
		plain(w, http.StatusBadGateway, "Your control plane did not answer. Try again in a moment.\n")
	}
	s.log(fmt.Sprintf("%s: started at %s", id, cfg.URL))
	c := &copyRunning{service: service, proxy: proxy, limits: st, agents: agents, eventsSwept: s.cfg.Now()}
	if n, err := s.sweepEvents(ctx, st); err != nil {
		s.log(id + ": events sweep: " + err.Error())
	} else if n > 0 {
		s.log(fmt.Sprintf("%s: deleted %d events older than its plan keeps", id, n))
	}
	return c, nil
}

// clientOf is the address a request comes from: the last X-Forwarded-For entry when the
// peer is a trusted proxy (Caddy, which writes it), else the peer, never one a stranger
// says. As controlplane's sources.of.
func (s *Service) clientOf(r *http.Request) string {
	peer := r.RemoteAddr
	if host, _, err := net.SplitHostPort(peer); err == nil {
		peer = host
	}
	addr, err := netip.ParseAddr(peer)
	if err != nil {
		return peer
	}
	addr = addr.Unmap()
	for _, p := range s.cfg.TrustedProxies {
		if !p.Contains(addr) {
			continue
		}
		if values := r.Header.Values("X-Forwarded-For"); len(values) > 0 {
			list := strings.Split(values[len(values)-1], ",")
			if forwarded, err := netip.ParseAddr(strings.TrimSpace(list[len(list)-1])); err == nil {
				return forwarded.Unmap().String()
			}
		}
		break
	}
	return addr.String()
}

// makeRoomLocked stops the copy with no request open that has been idle longest, under
// s.mu, which it gives up and takes again while the copy stops. It says whether it found
// one.
func (s *Service) makeRoomLocked() bool {
	var oldest string
	for id, c := range s.copies {
		if c.open == 0 && (oldest == "" || c.last.Before(s.copies[oldest].last)) {
			oldest = id
		}
	}
	if oldest == "" {
		return false
	}
	c := s.copies[oldest]
	delete(s.copies, oldest)
	done := make(chan struct{})
	s.starting[oldest] = done
	s.mu.Unlock()
	s.stopRunning(oldest, c)
	s.log(oldest + ": stopped, to make room")
	s.mu.Lock()
	delete(s.starting, oldest)
	close(done)
	return true
}

// suspended is what a suspended account's address answers (#2152 FR-009).
func (s *Service) suspended(w http.ResponseWriter) {
	w.Header().Set("Agents-Refusal", "suspended")
	plain(w, http.StatusForbidden, "This hosted account is suspended. See https://"+s.cfg.Domain+"/account.\n")
}

// toAccount passes a request to an account's control plane.
func (s *Service) toAccount(w http.ResponseWriter, r *http.Request, id string) {
	if c := s.inUse(id); c != nil {
		defer s.done(c)
		s.serve(w, r, c)
		return
	}
	acc, err := s.accounts.get(r.Context(), id)
	if err != nil {
		s.log("store: " + err.Error())
		plain(w, http.StatusServiceUnavailable, "Accounts cannot be read just now. Try again in a moment.\n")
		return
	}
	if acc == nil {
		plain(w, http.StatusNotFound, "There is no control plane here.\n")
		return
	}
	if acc.Suspended != nil {
		s.suspended(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	c, err := s.copyFor(ctx, id)
	cancel()
	if errors.Is(err, errFull) {
		s.log(id + ": could not start: every copy is in use")
		plain(w, http.StatusServiceUnavailable, "The service is full just now. Try again in a few minutes.\n")
		return
	}
	if err != nil {
		s.log(id + ": could not start: " + err.Error())
		plain(w, http.StatusServiceUnavailable, "Your control plane could not start. Try again in a moment.\n")
		return
	}
	defer s.done(c)
	s.serve(w, r, c)
}

// serve passes a request to a running copy, and a WebSocket only under the plan's
// connections (#2224).
func (s *Service) serve(w http.ResponseWriter, r *http.Request, c *copyRunning) {
	if isWebSocket(r.Header) && c.limits != nil {
		p := c.limits.planNow()
		s.mu.Lock()
		if c.sockets >= p.Connections {
			s.mu.Unlock()
			w.Header().Set("Agents-Refusal", "limit")
			plain(w, http.StatusTooManyRequests, c.limits.refuse(p, "connections", plural(p.Connections, "connection", "connections")+" at once", "Close one").Error()+"\n")
			return
		}
		c.sockets++
		s.mu.Unlock()
		defer func() {
			s.mu.Lock()
			c.sockets--
			s.mu.Unlock()
		}()
	}
	c.proxy.ServeHTTP(w, r)
}

// inUse is an account's copy when it is running, in use until done is called with it.
// Delete Account stops the copy before it removes the account, so a running copy is an
// account that is there, and its requests need no store read (P20261020-24).
func (s *Service) inUse(id string) *copyRunning {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.copies[id]
	if c != nil {
		c.open++
	}
	return c
}

// stopCopy stops an account's copy, when it is running.
func (s *Service) stopCopy(id string) {
	s.mu.Lock()
	c := s.copies[id]
	delete(s.copies, id)
	s.mu.Unlock()
	if c != nil {
		s.stopRunning(id, c)
	}
}

// stopRunning stops a copy taken out of copies, and keeps its store's size for its next start.
func (s *Service) stopRunning(id string, c *copyRunning) {
	c.service.Stop()
	if c.limits != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		s.keepUsage(ctx, id, c.limits)
		cancel()
	}
}

// firstCode is a browser pairing code from an account's control plane, and the address
// that pairs this browser with it: the page pairs itself from #code= (#109).
func (s *Service) firstCode(ctx context.Context, id string) (string, error) {
	c, err := s.copyFor(ctx, id)
	if err != nil {
		return "", err
	}
	defer s.done(c)
	shown, err := c.service.Codes().Issue(ctx, false, true, controllink.CodeLifetime)
	if err != nil {
		return "", err
	}
	return s.accountURL(id) + "/#code=" + escapeCode(shown.Text), nil
}

// escapeCode escapes all but the unreserved characters, as BrowserOpening.pairingURL
// does, so the page's decodeURIComponent gives the code back whole.
func escapeCode(code string) string {
	const unreserved = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
	var b strings.Builder
	for i := 0; i < len(code); i++ {
		if c := code[i]; strings.IndexByte(unreserved, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// idleLimit is how long a copy runs with no request before it stops.
const idleLimit = 15 * time.Minute

// done says a request to c has ended.
func (s *Service) done(c *copyRunning) {
	s.mu.Lock()
	c.open--
	c.last = s.cfg.Now()
	s.mu.Unlock()
}

// sweepIdle stops every copy with no request open that has had none for idleLimit. Each
// stays in starting while it stops, so a request for it waits and then starts it again.
func (s *Service) sweepIdle() {
	now := s.cfg.Now()
	idle := map[string]*copyRunning{}
	s.mu.Lock()
	for id, c := range s.copies {
		if c.open == 0 && now.Sub(c.last) >= idleLimit {
			idle[id] = c
			delete(s.copies, id)
			s.starting[id] = make(chan struct{})
		}
	}
	s.mu.Unlock()
	for id, c := range idle {
		s.stopRunning(id, c)
		s.log(id + ": stopped, idle")
		s.mu.Lock()
		done := s.starting[id]
		delete(s.starting, id)
		s.mu.Unlock()
		close(done)
	}
}

// sweepAccounts reads each running copy's account again: it stops the copies whose
// accounts are suspended or gone, gives the rest their plan as it is now, keeps their
// store's size, and deletes their events older than the plan keeps, each hour. A request
// to a running copy reads no account (P20261020-24), so the operator's command and a
// change of plan, from elsewhere, reach a running copy here, within a minute.
func (s *Service) sweepAccounts(ctx context.Context) {
	s.mu.Lock()
	running := make(map[string]*copyRunning, len(s.copies))
	for id, c := range s.copies {
		running[id] = c
	}
	s.mu.Unlock()
	now := s.cfg.Now()
	for id, c := range running {
		acc, err := s.accounts.get(ctx, id)
		if err != nil {
			continue
		}
		if acc == nil || acc.Suspended != nil {
			s.stopCopy(id)
			s.log(id + ": stopped, suspended")
			continue
		}
		if c.limits == nil {
			continue
		}
		c.limits.setPlan(PlanOf(acc))
		if c.agents != nil {
			c.agents.setPlan(PlanOf(acc))
		}
		s.keepUsage(ctx, id, c.limits)
		s.mu.Lock()
		due := now.Sub(c.eventsSwept) >= time.Hour
		if due {
			c.eventsSwept = now
		}
		s.mu.Unlock()
		if due {
			if n, err := s.sweepEvents(ctx, c.limits); err != nil {
				s.log(id + ": events sweep: " + err.Error())
			} else if n > 0 {
				s.log(fmt.Sprintf("%s: deleted %d events older than its plan keeps", id, n))
			}
		}
	}
}

// sweepIdleEvery sweeps idle copies until the service stops.
func (s *Service) sweepIdleEvery(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			s.sweepIdle()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			s.sweepAccounts(ctx)
			cancel()
		}
	}
}
