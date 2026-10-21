// Package hosted is the hosted service (#1807, direction.md "From nothing to working"): a
// person signs up on the web with GitHub, and gets a control plane of their own. Each
// account's control plane is the single-organisation one, unchanged: a copy of its own in
// this process, with its own store prefix and its own control key. This service routes
// <account>.<accounts domain> to that copy, and serves the sign-up and account pages at
// its own domain. TLS ends in front of it (Caddy).
package hosted

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Config is what the service needs. Nothing in it is a secret except GitHubSecret.
type Config struct {
	// The store every account's records are kept in, each under accounts/<id>/.
	Store store.Store
	// The keeper that seals each account's control key, and this service's own, in the
	// store (kms: gcpkms://…, or base64key:// for a local one).
	Keeper string
	// Where the pages are: https://<Domain>.
	Domain string
	// Where each account's control plane is: https://<id>.<AccountsDomain>. "" is Domain.
	AccountsDomain string
	// The GitHub App's client id and secret, for the web sign-in.
	GitHubClientID, GitHubSecret string
	// github.com and api.github.com; other addresses in tests.
	GitHubWeb, GitHubAPI string
	// The built web app (Web/dist) each control plane serves; "" serves none (tests).
	Web string
	// The views' sandbox proxy's domain for the copies' pages; "" draws no views.
	ViewsDomain string
	// The proxies in front of this service (Caddy), whose X-Forwarded-For is believed.
	TrustedProxies []netip.Prefix
	Log            func(string)
	// Now, for tests.
	Now func() time.Time
}

// Service is the hosted service.
type Service struct {
	cfg      Config
	accounts *accounts
	sessions sessions
	github   gitHub

	mu     sync.Mutex
	copies map[string]*copyRunning
	// Copies being started, so two requests start one.
	starting map[string]chan struct{}
	stopped  bool
	// Closed by Stop, for the idle sweep.
	stop chan struct{}
}

// New makes the service: its session key comes from its own key, sealed in the store
// under hosted/ by the keeper, made the first time.
func New(ctx context.Context, cfg Config) (*Service, error) {
	if cfg.Store == nil || cfg.Keeper == "" || cfg.Domain == "" {
		return nil, errors.New("the hosted service needs a store, a keeper and a domain")
	}
	if cfg.AccountsDomain == "" {
		cfg.AccountsDomain = cfg.Domain
	}
	if cfg.GitHubWeb == "" {
		cfg.GitHubWeb = "https://github.com"
	}
	if cfg.GitHubAPI == "" {
		cfg.GitHubAPI = "https://api.github.com"
	}
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	own, err := kms.Kept{Store: store.NewPrefixed(cfg.Store, hostedPrefix), Keeper: cfg.Keeper}.ControlKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("the hosted service's own key: %w", err)
	}
	s := &Service{cfg: cfg, accounts: &accounts{store: cfg.Store, now: cfg.Now},
		sessions: sessions{key: controllink.HKDF(own, []byte("agents-hosted-session-v1"), nil, 32), now: cfg.Now},
		github: gitHub{clientID: cfg.GitHubClientID, secret: cfg.GitHubSecret, web: cfg.GitHubWeb, api: cfg.GitHubAPI,
			redirect: "https://" + cfg.Domain + "/signin/callback"},
		copies: map[string]*copyRunning{}, starting: map[string]chan struct{}{}, stop: make(chan struct{})}
	go s.sweepIdleEvery(time.Minute)
	return s, nil
}

// Stop stops every account's copy.
func (s *Service) Stop() {
	s.mu.Lock()
	if !s.stopped {
		close(s.stop)
	}
	s.stopped = true
	copies := s.copies
	s.copies = map[string]*copyRunning{}
	s.mu.Unlock()
	for _, c := range copies {
		c.service.Stop()
	}
}

// ServeHTTP routes by host name: the pages at Domain, an account's control plane at
// <id>.<AccountsDomain>, and nothing anywhere else.
func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host := strings.ToLower(r.Host)
	if h, _, err := splitHostPort(host); err == nil {
		host = h
	}
	switch r.URL.Path {
	case "/healthz":
		plain(w, http.StatusOK, "ok\n")
		return
	case "/v1/tls-allowed":
		s.tlsAllowed(w, r)
		return
	}
	if host == s.cfg.Domain {
		s.pages(w, r)
		return
	}
	if id, ok := strings.CutSuffix(host, "."+s.cfg.AccountsDomain); ok && validID(id) {
		s.toAccount(w, r, id)
		return
	}
	plain(w, http.StatusMisdirectedRequest, "Nothing is served at this name.\n")
}

// tlsAllowed is Caddy's on-demand TLS ask (deploy/Caddyfile.hosted): a certificate only
// for the pages' name and an account that exists, so nobody can have it fetch one for
// every name under the domain.
func (s *Service) tlsAllowed(w http.ResponseWriter, r *http.Request) {
	name := strings.ToLower(r.URL.Query().Get("domain"))
	if name == s.cfg.Domain {
		plain(w, http.StatusOK, "yes\n")
		return
	}
	if id, ok := strings.CutSuffix(name, "."+s.cfg.AccountsDomain); ok && validID(id) {
		if acc, err := s.accounts.get(r.Context(), id); err == nil && acc != nil {
			plain(w, http.StatusOK, "yes\n")
			return
		}
	}
	plain(w, http.StatusNotFound, "no\n")
}

func (s *Service) log(line string) { s.cfg.Log(line) }

// accountURL is where an account's control plane answers.
func (s *Service) accountURL(id string) string { return "https://" + id + "." + s.cfg.AccountsDomain }

func plain(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(text))
}

func splitHostPort(hostport string) (string, string, error) {
	i := strings.LastIndex(hostport, ":")
	if i < 0 || strings.Contains(hostport[i:], "]") {
		return hostport, "", errors.New("no port")
	}
	return hostport[:i], hostport[i+1:], nil
}
