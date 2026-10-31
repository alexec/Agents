package controlplane

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The limits a paired client, and anyone on the internet, is held to (#2150).

// The listeners' timeouts. A WebSocket clears them once it is let through, so they close
// only a slow request, never a socket in use. Variables, so a test can shorten them.
var (
	httpReadTimeout  = 30 * time.Second
	httpWriteTimeout = 60 * time.Second
	httpIdleTimeout  = 2 * time.Minute
)

const (
	httpHeaderMost = 64 << 10
	// downloadWriteTimeout is a download's own: an agentsd build is tens of MB.
	downloadWriteTimeout = 10 * time.Minute

	// socketsMost is how many WebSockets may be open at once at this copy. Each holds a
	// queue of its own; an e2-micro has 1 GB.
	socketsMost = 1024
	// sessionsPerClient and sessionsPerPerson are how many a client key, and every client of
	// one person, may hold at once.
	sessionsPerClient = 8
	sessionsPerPerson = 32

	// The largest message a socket reads: until it proves a key, then by what proved one.
	// A client's largest real message is a 25 MiB drop box file, as base64.
	unprovenMessageMost = 64 << 10
	clientMessageMost   = 40 << 20
	peerMessageMost     = 64 << 20

	// A client key's rates: every line it sends, the costly methods, and its bytes.
	clientLinesPerSecond  = 100
	clientLinesBurst      = 1000
	costlyPerSecond       = 2
	costlyBurst           = 20
	clientBytesPerSecond  = 8 << 20
	clientBytesBurst      = 96 << 20
	clientRatesHeld       = 4096
	clientRateIdleDropped = 10 * time.Minute

	// The downloads, by address: install.sh, a server's build, a toolset.
	downloadsPerMinute = 30
	downloadsBurst     = 30

	// refusalLogWindow is how often one kind of refusal of one source is logged.
	refusalLogWindow = time.Minute
)

// tooManyRequests is the answer to a request over a client's rate. The socket stays open.
const tooManyRequests = wire.FailureTooManyRequests

var tooMany = fail(tooManyRequests, "Too many requests from this device. Wait a moment and try again.")

// bucket is a token bucket: up to burst at once, refilled at rate each second.
type bucket struct {
	tokens float64
	at     time.Time
}

func (b *bucket) take(now time.Time, n, rate, burst float64) bool {
	if b.at.IsZero() {
		b.tokens = burst
	} else {
		b.tokens = min(burst, b.tokens+now.Sub(b.at).Seconds()*rate)
	}
	b.at = now
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

// clientRates is every client key's buckets.
type clientRates struct {
	now func() time.Time
	mu  sync.Mutex
	of  map[string]*clientRate
}

type clientRate struct{ lines, costly, bytes bucket }

func newClientRates() *clientRates {
	return &clientRates{now: time.Now, of: map[string]*clientRate{}}
}

// allow takes a line of n bytes from client's buckets, and says whether it is let
// through. A request for a costly method takes from that bucket too.
func (c *clientRates) allow(client string, n int, method string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	r := c.of[client]
	if r == nil {
		if len(c.of) >= clientRatesHeld {
			for k, v := range c.of {
				if now.Sub(v.bytes.at) > clientRateIdleDropped {
					delete(c.of, k)
				}
			}
		}
		r = &clientRate{}
		c.of[client] = r
	}
	if !r.bytes.take(now, float64(n), clientBytesPerSecond, clientBytesBurst) {
		return false
	}
	if method == "" {
		return true
	}
	if costly(method) && !r.costly.take(now, 1, costlyPerSecond, costlyBurst) {
		return false
	}
	return r.lines.take(now, 1, clientLinesPerSecond, clientLinesBurst)
}

// costly is a method that reads much of the store, or starts work outside it.
func costly(method string) bool {
	if strings.HasPrefix(method, "reports/") || strings.HasPrefix(method, "audit/") || strings.HasPrefix(method, "console/") ||
		strings.HasPrefix(method, "governance/") || strings.HasPrefix(method, "readApi/") {
		return true
	}
	switch method {
	case "usage/rollup", "projects/joined", "projects/list", "hosts/install", "hosts/detect", "hosts/sshHosts", "hosts/update", "hosts/startEnroll",
		"clients/startPairing", "devices/startPairing", "bots/make", "control/rotate", "links/check":
		return true
	}
	return false
}

// addressRates is a bucket for each address (an IPv6 /64 as one), for the downloads.
type addressRates struct {
	now func() time.Time
	mu  sync.Mutex
	of  map[string]*bucket
}

func newAddressRates() *addressRates { return &addressRates{now: time.Now, of: map[string]*bucket{}} }

func (a *addressRates) allow(addr string) bool {
	key := keyOf(addr)
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	b := a.of[key]
	if b == nil {
		if len(a.of) >= sourcesHeld {
			for k, v := range a.of {
				if now.Sub(v.at) > time.Minute*downloadsBurst/downloadsPerMinute {
					delete(a.of, k)
				}
			}
		}
		if len(a.of) >= sourcesHeld {
			// Every address held is busy: this one shares a bucket with every other one.
			key = "*"
			if b = a.of[key]; b == nil {
				b = &bucket{}
				a.of[key] = b
			}
		} else {
			b = &bucket{}
			a.of[key] = b
		}
	}
	return b.take(now, 1, downloadsPerMinute/60.0, downloadsBurst)
}

// refusalLog logs a refusal once a window for each kind and source, and how many it
// did not log.
type refusalLog struct {
	log func(string)
	now func() time.Time
	mu  sync.Mutex
	of  map[string]*refusalCount
}

type refusalCount struct {
	since  time.Time
	unsaid int
}

func newRefusalLog(log func(string)) *refusalLog {
	return &refusalLog{log: log, now: time.Now, of: map[string]*refusalCount{}}
}

func (l *refusalLog) note(kind, source, line string) {
	key := kind + " " + source
	l.mu.Lock()
	now := l.now()
	c := l.of[key]
	if c != nil && now.Sub(c.since) < refusalLogWindow {
		c.unsaid++
		l.mu.Unlock()
		return
	}
	unsaid := 0
	if c != nil {
		unsaid = c.unsaid
	}
	if len(l.of) >= sourcesHeld {
		for k, v := range l.of {
			if now.Sub(v.since) >= refusalLogWindow {
				delete(l.of, k)
			}
		}
	}
	l.of[key] = &refusalCount{since: now}
	l.mu.Unlock()
	if unsaid > 0 {
		line += fmt.Sprintf(" (and %d more since the last line)", unsaid)
	}
	l.log(line)
}

// timeouts sets a listener's timeouts and header limit (#2150).
func timeouts(srv *http.Server) *http.Server {
	srv.ReadTimeout = httpReadTimeout
	srv.WriteTimeout = httpWriteTimeout
	srv.IdleTimeout = httpIdleTimeout
	srv.MaxHeaderBytes = httpHeaderMost
	return srv
}

// noDeadlines clears a request's timeouts, for one that becomes a WebSocket.
func noDeadlines(w http.ResponseWriter) {
	rc := http.NewResponseController(w)
	rc.SetReadDeadline(time.Time{})
	rc.SetWriteDeadline(time.Time{})
}

// refusedRate answers a line over its client key's rate: a request with tooManyRequests,
// anything else by dropping it. The socket stays open, so the client does not reconnect.
func (r *Router) refusedRate(sessionID, host, line, msg string, kind int) bool {
	r.mu.Lock()
	s := r.clients[sessionID]
	r.mu.Unlock()
	if s == nil {
		return false
	}
	if kind == frameBad {
		msg = line
	}
	// A large line is a file's, never a costly method's: it is not read twice to say so.
	var m *message
	method := "-"
	if len(msg) <= unprovenMessageMost {
		if m, _ = decode(msg); m != nil {
			method = m.Method
		}
	}
	if r.rates.allow(s.caller.Client, len(line), method) {
		return false
	}
	r.refusals.note("rate", s.caller.Client, "control: refused lines from client "+s.caller.Client+": over its rate")
	if m == nil {
		m, _ = decode(msg)
	}
	if m != nil && m.isRequest() {
		e := replyError(m.ID, tooMany)
		if kind != frameLegacy {
			e = wrap(host, e)
		}
		r.mu.Lock()
		r.writeLocked(sessionID, e)
		r.mu.Unlock()
	}
	return true
}

// Crowded says a client key, or its person, holds as many sessions here as it may.
func (r *Router) Crowded(client string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	person := ""
	if r.owners != nil {
		person = r.owners.PersonOf(client)
	}
	mine, theirs := 0, 0
	for _, s := range r.clients {
		if strings.EqualFold(s.caller.Client, client) {
			mine++
		}
		if person != "" && s.caller.Person == person {
			theirs++
		}
	}
	return mine >= sessionsPerClient || theirs >= sessionsPerPerson
}

// heaviest is the source that holds the most places, when it holds more than one, or ""
// (#2150): when every place is taken, its oldest goes before a newcomer is turned away, so
// a few addresses can't hold every place for long.
func heaviest(counts map[string]int) string {
	most, out := 1, ""
	for source, n := range counts {
		if n > most || n == most && out != "" && source < out {
			most, out = n, source
		}
	}
	return out
}
