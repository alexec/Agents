package controlplane

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// The budget of one source address before it proves a key (public-security.md P3).
const (
	// failedProofsAllowed failed proofs in failedProofWindow, then refusedFor of no
	// sockets at all.
	failedProofsAllowed = 20
	failedProofWindow   = time.Minute
	refusedFor          = time.Minute
	// waitingAllowed sockets at once that have not proved a key yet.
	waitingAllowed = 50
	// sourcesHeld is how many addresses the table holds; past it, an idle one goes.
	sourcesHeld = 4096
	// unprovenMost sockets at once, from every address, that have not proved a key yet: the
	// cap that holds when an attacker turns over more addresses than the table holds
	// (#2150).
	unprovenMost = 512
)

// sources is the per-source table: a socket from an address that failed to prove a key
// too often, or that has too many sockets still to prove one, is refused before the
// WebSocket opens. The address is the peer's, or the last X-Forwarded-For entry when
// the peer is a trusted proxy (Caddy, which writes it), never one a stranger says.
type sources struct {
	trusted []netip.Prefix
	log     func(string)
	now     func() time.Time

	mu    sync.Mutex
	table map[string]*source
	// waiting is every socket still to prove a key, counted in the table or not.
	waiting int
}

type source struct {
	waiting  int
	failed   int
	since    time.Time
	refusing time.Time
}

func newSources(trusted []netip.Prefix, log func(string)) *sources {
	return &sources{trusted: trusted, log: log, now: time.Now, table: map[string]*source{}}
}

// of is the address a request comes from.
func (t *sources) of(r *http.Request) string {
	peer := r.RemoteAddr
	if host, _, err := net.SplitHostPort(peer); err == nil {
		peer = host
	}
	addr, err := netip.ParseAddr(peer)
	if err != nil {
		return peer
	}
	addr = addr.Unmap()
	if t.trusts(addr) {
		values := r.Header.Values("X-Forwarded-For")
		if len(values) > 0 {
			list := strings.Split(values[len(values)-1], ",")
			if forwarded, err := netip.ParseAddr(strings.TrimSpace(list[len(list)-1])); err == nil {
				return forwarded.Unmap().String()
			}
		}
	}
	return addr.String()
}

func (t *sources) trusts(addr netip.Addr) bool {
	for _, p := range t.trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// keyOf is what the table counts by: an IPv4 address, or an IPv6 address's /64, which
// one machine is usually given whole.
func keyOf(addr string) string {
	a, err := netip.ParseAddr(addr)
	if err != nil || !a.Is6() {
		return addr
	}
	p, _ := a.Prefix(64)
	return p.String()
}

// enter counts a socket from addr as waiting to prove a key, and gives what to call once
// it has, or has failed to. ok is false when addr is refused for now.
func (t *sources) enter(addr string) (proved func(failed bool), ok bool) {
	key := keyOf(addr)
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	if t.waiting >= unprovenMost {
		return nil, false
	}
	s := t.table[key]
	if s == nil {
		if len(t.table) >= sourcesHeld {
			t.prune(now)
		}
		if len(t.table) >= sourcesHeld {
			// Every address held is busy: this one goes uncounted rather than refused, so
			// many addresses can't shut out one that has done nothing. It still counts
			// towards unprovenMost.
			t.waiting++
			var once sync.Once
			return func(bool) {
				once.Do(func() {
					t.mu.Lock()
					t.waiting--
					t.mu.Unlock()
				})
			}, true
		}
		s = &source{since: now}
		t.table[key] = s
	}
	if now.Before(s.refusing) || s.waiting >= waitingAllowed {
		return nil, false
	}
	s.waiting++
	t.waiting++
	var once sync.Once
	return func(failed bool) { once.Do(func() { t.leave(key, s, failed) }) }, true
}

func (t *sources) leave(key string, s *source, failed bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	s.waiting--
	t.waiting--
	if !failed {
		return
	}
	now := t.now()
	if now.Sub(s.since) >= failedProofWindow {
		s.since, s.failed = now, 0
	}
	s.failed++
	if s.failed >= failedProofsAllowed {
		s.refusing = now.Add(refusedFor)
		s.since, s.failed = now, 0
		t.log(fmt.Sprintf("refusing %s for %v: %d failed proofs in %v", key, refusedFor, failedProofsAllowed, failedProofWindow))
	}
}

// prune lets go of every address with nothing waiting, nothing counted and no refusal.
func (t *sources) prune(now time.Time) {
	for key, s := range t.table {
		if s.waiting == 0 && !now.Before(s.refusing) && (s.failed == 0 || now.Sub(s.since) >= failedProofWindow) {
			delete(t.table, key)
		}
	}
}

// ParseTrustedProxies reads AGENTS_CONTROL_TRUSTED_PROXIES: addresses or prefixes,
// separated by commas.
func ParseTrustedProxies(text string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, part := range strings.Split(text, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if p, err := netip.ParsePrefix(part); err == nil {
			out = append(out, p.Masked())
			continue
		}
		a, err := netip.ParseAddr(part)
		if err != nil {
			return nil, fmt.Errorf("%q is not an address or a prefix", part)
		}
		out = append(out, netip.PrefixFrom(a.Unmap(), a.Unmap().BitLen()))
	}
	return out, nil
}
