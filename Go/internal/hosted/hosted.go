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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/hosted/billing"
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

	// Who may sign up (#2152): SignUpInvite (""), SignUpOpen or SignUpClosed.
	SignUp string
	// The most accounts; at the cap, new people wait. 0 is 100.
	MaxAccounts int
	// The youngest GitHub account that may sign up without an allowlist entry. 0 is 30
	// days; below 0 is none.
	MinGitHubAge time.Duration
	// New accounts and waitlist entries an hour, from one address and in all. 0 is 3 and 30.
	SignUpsPerAddress, SignUpsPerHour int
	// The most copies running at once. 0 is 50.
	MaxCopies int
	// The most new certificates an hour and a week. 0 is 10 and 40.
	CertsPerHour, CertsPerWeek int

	// Billing (#2225): Stripe's secret key; "" is billing off (FR-031). With it, the Pro
	// plan's price and the webhook's signing secret are needed too.
	StripeKey, StripePrice, StripeWebhookSecret string
	// Stripe's address, API when ""; Stripe itself, for tests (a fake), over the key.
	StripeAPI string
	Stripe    billing.Stripe
}

// Service is the hosted service.
type Service struct {
	cfg      Config
	accounts *accounts
	sessions sessions
	github   gitHub
	rates    rates
	certs    certificates
	// Stripe, or nil when billing is off.
	stripe billing.Stripe

	mu     sync.Mutex
	copies map[string]*copyRunning
	// Copies being started, so two requests start one.
	starting map[string]chan struct{}
	stopped  bool
	// Closed by Stop, for the idle sweep.
	stop chan struct{}
	// When the Stripe events acted on were last swept (billing.go).
	stripeSwept time.Time
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
	if cfg.SignUp == "" {
		cfg.SignUp = SignUpInvite
	}
	if cfg.SignUp != SignUpInvite && cfg.SignUp != SignUpOpen && cfg.SignUp != SignUpClosed {
		return nil, fmt.Errorf("sign-up is invite, open or closed, not %q", cfg.SignUp)
	}
	orDefault(&cfg.MaxAccounts, defaultMaxAccounts)
	orDefault(&cfg.SignUpsPerAddress, defaultSignUpsPerAddress)
	orDefault(&cfg.SignUpsPerHour, defaultSignUpsPerHour)
	orDefault(&cfg.MaxCopies, defaultMaxCopies)
	orDefault(&cfg.CertsPerHour, defaultCertsPerHour)
	orDefault(&cfg.CertsPerWeek, defaultCertsPerWeek)
	if cfg.MinGitHubAge == 0 {
		cfg.MinGitHubAge = defaultMinGitHubAge
	}
	var stripe billing.Stripe
	if cfg.StripeKey != "" || cfg.Stripe != nil {
		if cfg.StripePrice == "" || cfg.StripeWebhookSecret == "" {
			return nil, errors.New("billing needs the Pro plan's price and the webhook's signing secret: AGENTS_HOSTED_STRIPE_PRICE and AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET")
		}
		stripe = cfg.Stripe
		if stripe == nil {
			stripe = billing.NewHTTP(cfg.StripeKey, cfg.StripeAPI)
		}
	}
	own, err := kms.Kept{Store: store.NewPrefixed(cfg.Store, hostedPrefix), Keeper: cfg.Keeper}.ControlKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("the hosted service's own key: %w", err)
	}
	s := &Service{cfg: cfg, accounts: &accounts{store: cfg.Store, now: cfg.Now},
		sessions: sessions{key: controllink.HKDF(own, []byte("agents-hosted-session-v1"), nil, 32), now: cfg.Now},
		github: gitHub{clientID: cfg.GitHubClientID, secret: cfg.GitHubSecret, web: cfg.GitHubWeb, api: cfg.GitHubAPI,
			redirect: "https://" + cfg.Domain + "/signin/callback"},
		stripe: stripe, copies: map[string]*copyRunning{}, starting: map[string]chan struct{}{}, stop: make(chan struct{})}
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
	for id, c := range copies {
		s.stopRunning(id, c)
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
// every name under the domain; and a new one only under the caps (#2152 FR-008), below
// Let's Encrypt's limits. A suspended account keeps its name, so its refusal is served
// over TLS.
func (s *Service) tlsAllowed(w http.ResponseWriter, r *http.Request) {
	name := strings.ToLower(r.URL.Query().Get("domain"))
	if name == s.cfg.Domain {
		plain(w, http.StatusOK, "yes\n")
		return
	}
	if id, ok := strings.CutSuffix(name, "."+s.cfg.AccountsDomain); ok && validID(id) {
		if acc, err := s.accounts.get(r.Context(), id); err == nil && acc != nil {
			if acc.Certificate != nil || s.newCertificate(r.Context(), acc.ID) {
				plain(w, http.StatusOK, "yes\n")
				return
			}
			s.log(id + ": no certificate yet, at the cap")
		}
	}
	plain(w, http.StatusNotFound, "no\n")
}

// certificates are the times new names were allowed in the last week, filled from the
// accounts the first time they are needed.
type certificates struct {
	mu     sync.Mutex
	loaded bool
	times  []time.Time
}

// newCertificate allows a first certificate for an account, under the caps, and keeps
// when on the account so it counts once.
func (s *Service) newCertificate(ctx context.Context, id string) bool {
	c := &s.certs
	c.mu.Lock()
	defer c.mu.Unlock()
	now := s.cfg.Now()
	if !c.loaded {
		list, err := s.accounts.all(ctx)
		if err != nil {
			return false
		}
		for _, acc := range list {
			if acc.Certificate != nil {
				c.times = append(c.times, *acc.Certificate)
			}
		}
		sort.Slice(c.times, func(i, j int) bool { return c.times[i].Before(c.times[j]) })
		c.loaded = true
	}
	c.times = recent(c.times, now.Add(-7*24*time.Hour))
	if len(c.times) >= s.cfg.CertsPerWeek || len(recent(c.times, now.Add(-time.Hour))) >= s.cfg.CertsPerHour {
		return false
	}
	at := now.UTC()
	if _, err := s.accounts.update(ctx, id, func(acc *Account) {
		if acc.Certificate == nil {
			acc.Certificate = &at
		}
	}); err != nil {
		return false
	}
	c.times = append(c.times, at)
	return true
}

// certificateRoom says whether a new certificate would be allowed now.
func (s *Service) certificateRoom() bool {
	c := &s.certs
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loaded {
		return true
	}
	now := s.cfg.Now()
	return len(recent(c.times, now.Add(-7*24*time.Hour))) < s.cfg.CertsPerWeek &&
		len(recent(c.times, now.Add(-time.Hour))) < s.cfg.CertsPerHour
}

func orDefault(v *int, def int) {
	if *v == 0 {
		*v = def
	}
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
