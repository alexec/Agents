package hosted

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"sync"
	"time"
)

// Metrics (#2226, spec 1003 FR-042): Prometheus text on a listener of its own, answered only
// from loopback and the addresses in Config.MetricsFrom, never through Caddy, which passes
// only the service's own port. The counters are this process's, since it started.
//
//	agents_hosted_accounts{plan,state}        accounts, by plan and state
//	agents_hosted_waitlist                    people on the waitlist
//	agents_hosted_copies_running              control planes running now
//	agents_hosted_signups_total{kind}         new accounts and waitlist entries
//	agents_hosted_refusals_total{kind}        refusals: blocked, closed, rate, waitlist_full,
//	                                          store, full, suspended, certificates, and each
//	                                          plan limit (machines, clients, storage, connections)
//	agents_hosted_certificates_allowed_total  new names allowed a certificate
//	agents_hosted_requests_total{status}      requests answered, by status
type metrics struct {
	mu       sync.Mutex
	signups  map[string]int64
	refusals map[string]int64
	certs    int64
	requests map[int]int64
}

func (m *metrics) add(into *map[string]int64, kind string) {
	m.mu.Lock()
	if *into == nil {
		*into = map[string]int64{}
	}
	(*into)[kind]++
	m.mu.Unlock()
}

func (m *metrics) signedUp(kind string) { m.add(&m.signups, kind) }
func (m *metrics) refused(kind string)  { m.add(&m.refusals, kind) }

func (m *metrics) certificate() {
	m.mu.Lock()
	m.certs++
	m.mu.Unlock()
}

func (m *metrics) answered(status int) {
	m.mu.Lock()
	if m.requests == nil {
		m.requests = map[int]int64{}
	}
	m.requests[status]++
	m.mu.Unlock()
}

// Metrics is the handler for the metrics listener.
func (s *Service) Metrics() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.metricsAllowed(r.RemoteAddr) {
			plain(w, http.StatusForbidden, "Metrics are not served to this address.\n")
			return
		}
		if r.URL.Path != "/metrics" {
			plain(w, http.StatusNotFound, "Not found.\n")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		text, err := s.metricsText(ctx)
		if err != nil {
			s.log("metrics: " + err.Error())
			plain(w, http.StatusServiceUnavailable, "The store cannot be read just now.\n")
			return
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = w.Write([]byte(text))
	})
}

// metricsAllowed is loopback, or an address in MetricsFrom: never X-Forwarded-For.
func (s *Service) metricsAllowed(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	if addr.IsLoopback() {
		return true
	}
	for _, p := range s.cfg.MetricsFrom {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

func (s *Service) metricsText(ctx context.Context) (string, error) {
	list, err := s.accounts.all(ctx)
	if err != nil {
		return "", err
	}
	waiting, err := s.cfg.Store.List(ctx, waitlistFolder)
	if err != nil {
		return "", err
	}
	type planState struct{ plan, state string }
	accounts := map[planState]int{}
	for _, p := range plans {
		accounts[planState{p.ID, "active"}] = 0
	}
	for i := range list {
		state := "active"
		if list[i].Suspended != nil {
			state = "suspended"
		}
		accounts[planState{PlanOf(&list[i]).ID, state}]++
	}
	s.mu.Lock()
	running := len(s.copies)
	s.mu.Unlock()

	var b metricsWriter
	b.head("agents_hosted_accounts", "gauge", "Accounts, by plan and state.")
	keys := make([]planState, 0, len(accounts))
	for k := range accounts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		return keys[i].plan+keys[i].state < keys[j].plan+keys[j].state
	})
	for _, k := range keys {
		b.line(fmt.Sprintf(`agents_hosted_accounts{plan=%q,state=%q}`, k.plan, k.state), int64(accounts[k]))
	}
	b.head("agents_hosted_waitlist", "gauge", "People on the waitlist.")
	b.line("agents_hosted_waitlist", int64(len(waiting)))
	b.head("agents_hosted_copies_running", "gauge", "Control planes running now.")
	b.line("agents_hosted_copies_running", int64(running))

	m := &s.metrics
	m.mu.Lock()
	defer m.mu.Unlock()
	b.counters("agents_hosted_signups_total", "New accounts and waitlist entries, by kind.", "kind", m.signups)
	b.counters("agents_hosted_refusals_total", "Refusals, by kind.", "kind", m.refusals)
	b.head("agents_hosted_certificates_allowed_total", "counter", "New names allowed a certificate.")
	b.line("agents_hosted_certificates_allowed_total", m.certs)
	statuses := map[string]int64{}
	for code, n := range m.requests {
		statuses[strconv.Itoa(code)] = n
	}
	b.counters("agents_hosted_requests_total", "Requests answered, by status.", "status", statuses)
	return b.String(), nil
}

type metricsWriter struct{ text []byte }

func (b *metricsWriter) head(name, kind, help string) {
	b.text = fmt.Appendf(b.text, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
}

func (b *metricsWriter) line(series string, n int64) {
	b.text = fmt.Appendf(b.text, "%s %d\n", series, n)
}

func (b *metricsWriter) counters(name, help, label string, values map[string]int64) {
	b.head(name, "counter", help)
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		b.line(fmt.Sprintf(`%s{%s=%q}`, name, label, k), values[k])
	}
}

func (b *metricsWriter) String() string { return string(b.text) }

// statusWriter keeps the status a request is answered with. A WebSocket's upgrade and a
// stream's flush go through to the writer under it.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if w.status == 0 {
		w.status = http.StatusSwitchingProtocols
	}
	return http.NewResponseController(w.ResponseWriter).Hijack()
}
