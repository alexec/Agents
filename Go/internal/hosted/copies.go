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
// loopback, started the first time it is asked for and kept running.

type copyRunning struct {
	service *controlplane.Service
	proxy   *httputil.ReverseProxy
}

// loopback is where this service reaches its copies from: they believe its
// X-Forwarded-For, and through it the proxies in front.
var loopback = []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32"), netip.MustParsePrefix("::1/128")}

// copyFor is an account's running copy, started if it is not running.
func (s *Service) copyFor(ctx context.Context, id string) (*copyRunning, error) {
	for {
		s.mu.Lock()
		if s.stopped {
			s.mu.Unlock()
			return nil, errors.New("the service is stopping")
		}
		if c := s.copies[id]; c != nil {
			s.mu.Unlock()
			return c, nil
		}
		wait, busy := s.starting[id]
		if !busy {
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
	st := accountStore(s.cfg.Store, id)
	key, err := kms.Kept{Store: st, Keeper: s.cfg.Keeper}.ControlKey(ctx)
	if err != nil {
		return nil, fmt.Errorf("its control key: %w", err)
	}
	trusted := append(append([]netip.Prefix(nil), loopback...), s.cfg.TrustedProxies...)
	views := ""
	if s.cfg.ViewsDomain != "" {
		views = "https://" + s.cfg.ViewsDomain
	}
	cfg := controlplane.Config{Store: st, PrivateKey: key, URL: s.accountURL(id), Bind: "127.0.0.1", Port: 0,
		Name: "Your control plane", MachineID: "hosted-" + id, PublicWeb: s.cfg.Web, PublicViews: views,
		TrustedProxies: trusted, Hosted: true, Log: func(line string) { s.log(id + ": " + line) }}
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
		// Where the request came from, after what the proxies in front said: the copy
		// believes it from loopback, and the rest from TrustedProxies.
		from, _, err := net.SplitHostPort(pr.In.RemoteAddr)
		if err != nil {
			from = pr.In.RemoteAddr
		}
		if prior := pr.In.Header.Values("X-Forwarded-For"); len(prior) > 0 {
			from = strings.Join(prior, ", ") + ", " + from
		}
		pr.Out.Header.Set("X-Forwarded-For", from)
	}}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		s.log(id + ": proxy: " + err.Error())
		plain(w, http.StatusBadGateway, "Your control plane did not answer. Try again in a moment.\n")
	}
	s.log(fmt.Sprintf("%s: started at %s", id, cfg.URL))
	return &copyRunning{service: service, proxy: proxy}, nil
}

// toAccount passes a request to an account's control plane.
func (s *Service) toAccount(w http.ResponseWriter, r *http.Request, id string) {
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
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	c, err := s.copyFor(ctx, id)
	cancel()
	if err != nil {
		s.log(id + ": could not start: " + err.Error())
		plain(w, http.StatusServiceUnavailable, "Your control plane could not start. Try again in a moment.\n")
		return
	}
	c.proxy.ServeHTTP(w, r)
}

// stopCopy stops an account's copy, when it is running.
func (s *Service) stopCopy(id string) {
	s.mu.Lock()
	c := s.copies[id]
	delete(s.copies, id)
	s.mu.Unlock()
	if c != nil {
		c.service.Stop()
	}
}

// firstCode is a browser pairing code from an account's control plane, and the address
// that pairs this browser with it: the page pairs itself from #code= (#109).
func (s *Service) firstCode(ctx context.Context, id string) (string, error) {
	c, err := s.copyFor(ctx, id)
	if err != nil {
		return "", err
	}
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
