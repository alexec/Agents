package controlplane

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Metrics is what an operations team scrapes (#2176, T7): counters and request times in
// the Prometheus text format, on a listener of its own that is off unless asked for
// (ServeMetrics), never on the port clients and hosts use. Written by hand rather than with
// the Prometheus client, as the format is a few lines and the module stays small.
//
// Every label's values are bounded: a method that a client names is
// counted under its own name only for the first metricsMethods names, then as "other".
type Metrics struct {
	mu       sync.Mutex
	counters map[string]map[labels]float64
	times    map[string]map[labels]*histogram
	methods  map[string]bool
}

// metricsMethods is how many method names get a label of their own.
const metricsMethods = 300

// timeBuckets are the request and store time buckets, in seconds.
var timeBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// labels is a metric's label pairs, already written as Prometheus writes them: a="x",b="y".
type labels string

type histogram struct {
	buckets []uint64
	sum     float64
	count   uint64
}

func newMetrics() *Metrics {
	return &Metrics{counters: map[string]map[labels]float64{}, times: map[string]map[labels]*histogram{}, methods: map[string]bool{}}
}

// label writes pairs as a label set, its values escaped.
func label(pairs ...string) labels {
	var b strings.Builder
	for i := 0; i+1 < len(pairs); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(pairs[i] + `="` + escapeLabel(pairs[i+1]) + `"`)
	}
	return labels(b.String())
}

func escapeLabel(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

// method is name, or "other" once metricsMethods names have their own label.
func (m *Metrics) method(name string) string {
	if name == "" {
		return "none"
	}
	if m.methods[name] {
		return name
	}
	if len(m.methods) >= metricsMethods {
		return "other"
	}
	m.methods[name] = true
	return name
}

func (m *Metrics) add(name string, l labels, n float64) {
	set := m.counters[name]
	if set == nil {
		set = map[labels]float64{}
		m.counters[name] = set
	}
	set[l] += n
}

func (m *Metrics) observe(name string, l labels, seconds float64) {
	set := m.times[name]
	if set == nil {
		set = map[labels]*histogram{}
		m.times[name] = set
	}
	h := set[l]
	if h == nil {
		h = &histogram{buckets: make([]uint64, len(timeBuckets))}
		set[l] = h
	}
	for i, le := range timeBuckets {
		if seconds <= le {
			h.buckets[i]++
		}
	}
	h.sum += seconds
	h.count++
}

// Request counts a request a client made, by method and result: "ok", "error" (the
// control plane's own answer), "routed" (sent on to a machine) or "refused". took is the
// control plane's own time; zero for a routed one, which the machine answers.
func (m *Metrics) Request(method, result string, took time.Duration) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	method = m.method(method)
	m.add("agents_control_requests_total", label("method", method, "result", result), 1)
	if took > 0 {
		m.observe("agents_control_request_seconds", label("method", method), took.Seconds())
	}
}

// Event counts a notification sent to clients, by method, and how many it went to.
func (m *Metrics) Event(method string, sent int) {
	if m == nil || sent == 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.add("agents_control_events_sent_total", label("method", m.method(method)), float64(sent))
}

// Store counts a store operation (get, put, delete, list), whether it failed, and its time.
func (m *Metrics) Store(op string, err error, took time.Duration) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.add("agents_control_store_operations_total", label("op", op), 1)
	if err != nil {
		m.add("agents_control_store_errors_total", label("op", op), 1)
	}
	m.observe("agents_control_store_seconds", label("op", op), took.Seconds())
}

// help is each metric's HELP line and type.
var help = map[string][2]string{
	"agents_control_requests_total":         {"counter", "Requests from clients, by method and result (ok, error, routed, refused)."},
	"agents_control_request_seconds":        {"histogram", "Time the control plane took to answer its own requests, by method."},
	"agents_control_events_sent_total":      {"counter", "Notifications sent to clients, by method, one for each client sent to."},
	"agents_control_store_operations_total": {"counter", "Store operations, by op."},
	"agents_control_store_errors_total":     {"counter", "Store operations that failed, by op."},
	"agents_control_store_seconds":          {"histogram", "Time each store operation took, by op."},
	"agents_control_hosts_connected":        {"gauge", "Machines whose uplink this copy holds."},
	"agents_control_hosts_known":            {"gauge", "Machines in the store."},
	"agents_control_clients_connected":      {"gauge", "Clients (windows, phones, browsers) with a session here."},
	"agents_control_client_sessions":        {"gauge", "Client sessions here; a client can have more than one."},
	"agents_control_relay_sessions":         {"gauge", "Relays (agents-relay on a Mac) connected and relaying here."},
	"agents_control_leases_held":            {"gauge", "Machine leases this copy holds, with several copies over one store."},
	"agents_control_copies":                 {"gauge", "Copies of the control plane this copy knows of, itself too."},
	"agents_control_phase":                  {"gauge", "1 for this copy's phase: serving, receiving, frozen or forwarding."},
	"agents_control_up_seconds":             {"gauge", "Seconds since this copy started."},
	"agents_control_build_info":             {"gauge", "1, with this copy's version."},
}

// gauges is what is read when scraped, rather than counted.
type gauges struct {
	hostsConnected, hostsKnown, clients, sessions, relays, leases, copies int
	phase, version                                                        string
	up                                                                    time.Duration
}

// write writes every metric in the Prometheus text format (version 0.0.4). The text is made
// under m.mu and written after it is let go: a scraper that stops reading must not hold up
// every request, event and store operation, which count under the same lock (#2249).
func (m *Metrics) write(w io.Writer, g gauges) {
	var b bytes.Buffer
	m.text(&b, g)
	_, _ = w.Write(b.Bytes()) // a scraper that went is not ours to answer
}

func (m *Metrics) text(w *bytes.Buffer, g gauges) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := map[string][]string{}
	for name, set := range m.counters {
		for l, v := range set {
			out[name] = append(out[name], sample(name, l, v))
		}
	}
	for name, set := range m.times {
		for l, h := range set {
			for i, le := range timeBuckets {
				out[name] = append(out[name], sample(name+"_bucket", joined(l, label("le", strconv.FormatFloat(le, 'g', -1, 64))), float64(h.buckets[i])))
			}
			out[name] = append(out[name], sample(name+"_bucket", joined(l, label("le", "+Inf")), float64(h.count)),
				sample(name+"_sum", l, h.sum), sample(name+"_count", l, float64(h.count)))
		}
	}
	gauge := func(name string, l labels, v float64) { out[name] = append(out[name], sample(name, l, v)) }
	gauge("agents_control_hosts_connected", "", float64(g.hostsConnected))
	gauge("agents_control_hosts_known", "", float64(g.hostsKnown))
	gauge("agents_control_clients_connected", "", float64(g.clients))
	gauge("agents_control_client_sessions", "", float64(g.sessions))
	gauge("agents_control_relay_sessions", "", float64(g.relays))
	gauge("agents_control_leases_held", "", float64(g.leases))
	gauge("agents_control_copies", "", float64(g.copies))
	for _, p := range []string{phaseServing, phaseReceiving, phaseFrozen, phaseForwarding} {
		v := 0.0
		if p == g.phase {
			v = 1
		}
		gauge("agents_control_phase", label("phase", p), v)
	}
	gauge("agents_control_up_seconds", "", math.Round(g.up.Seconds()))
	gauge("agents_control_build_info", label("version", g.version), 1)

	names := make([]string, 0, len(out))
	for name := range out {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		h := help[name]
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", name, h[1], name, h[0])
		lines := out[name]
		if h[0] != "histogram" {
			sort.Strings(lines)
		}
		for _, line := range lines {
			w.WriteString(line)
		}
	}
}

func joined(a, b labels) labels {
	if a == "" {
		return b
	}
	return a + "," + b
}

func sample(name string, l labels, v float64) string {
	value := strconv.FormatFloat(v, 'g', -1, 64)
	if l == "" {
		return name + " " + value + "\n"
	}
	return name + "{" + string(l) + "} " + value + "\n"
}

// countedStore is a store whose every operation is counted.
type countedStore struct {
	store.Store
	m *Metrics
}

func (c countedStore) Get(ctx context.Context, key string) (*store.Object, error) {
	start := time.Now()
	o, err := c.Store.Get(ctx, key)
	c.m.Store("get", err, time.Since(start))
	return o, err
}

func (c countedStore) Put(ctx context.Context, key string, data []byte, when store.Condition) (string, error) {
	start := time.Now()
	etag, err := c.Store.Put(ctx, key, data, when)
	// A condition that did not hold is the store working, not failing.
	counted := err
	if store.IsConflict(err) {
		counted = nil
	}
	c.m.Store("put", counted, time.Since(start))
	return etag, err
}

func (c countedStore) Delete(ctx context.Context, key string) error {
	start := time.Now()
	err := c.Store.Delete(ctx, key)
	c.m.Store("delete", err, time.Since(start))
	return err
}

func (c countedStore) List(ctx context.Context, prefix string) ([]store.Key, error) {
	start := time.Now()
	keys, err := c.Store.List(ctx, prefix)
	c.m.Store("list", err, time.Since(start))
	return keys, err
}

// requested is told of each request a client made: counted, and logged at debug with its
// fields, never its params (which can carry a token or a prompt).
func (s *Service) requested(caller Caller, host, method string, id json.RawMessage, result string, took time.Duration) {
	s.metrics.Request(method, result, took)
	if !s.cfg.Logger.Enabled(context.Background(), slog.LevelDebug) {
		return
	}
	attrs := []slog.Attr{slog.String("copy", s.copyID), slog.String("method", method), slog.String("result", result),
		slog.String("request_id", idKey(id)), slog.String("client_id", caller.Client), slog.String("person_id", caller.Person)}
	if host != "" {
		attrs = append(attrs, slog.String("host_id", host))
	}
	if took > 0 {
		attrs = append(attrs, slog.Float64("ms", float64(took.Microseconds())/1000))
	}
	s.cfg.Logger.LogAttrs(context.Background(), slog.LevelDebug, "request", attrs...)
}

// Metrics is this copy's metrics.
func (s *Service) Metrics() *Metrics { return s.metrics }

// gauges reads what is scraped now.
func (s *Service) gauges() gauges {
	g := gauges{hostsConnected: len(s.router.HostsHeldHere()), hostsKnown: len(s.records.Hosts()),
		clients: len(s.router.ConnectedClients()), sessions: s.router.Sessions(), relays: len(s.router.RelaysHeldHere()),
		copies: 1, phase: s.phase.now(), version: s.cfg.Version, up: time.Since(s.started)}
	if s.mesh != nil {
		g.leases, g.copies = s.mesh.counts()
	}
	return g
}

// MetricsHandler serves /metrics, and nothing else. With a token, only a request that
// carries it as a bearer token is answered.
func (s *Service) MetricsHandler(token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/metrics" {
			http.NotFound(w, r)
			return
		}
		if token != "" {
			given, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
				w.Header().Set("WWW-Authenticate", `Bearer realm="metrics"`)
				http.Error(w, "a bearer token is needed", http.StatusUnauthorized)
				return
			}
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		s.metrics.write(w, s.gauges())
	})
}

// ServeMetrics listens on addr (host:port) for the scraper, apart from the port clients
// and hosts use. An address other than loopback needs a token: the metrics name methods
// and counts, and must not be open to anyone who can reach the machine. It returns the
// address bound.
func (s *Service) ServeMetrics(addr, token string) (string, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return "", fmt.Errorf("the metrics address %q is not host:port", addr)
	}
	if ip := net.ParseIP(host); token == "" && host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return "", fmt.Errorf("metrics on %s, which is not loopback, need a token: AGENTS_CONTROL_METRICS_TOKEN", addr)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return "", err
	}
	srv := timeouts(&http.Server{Handler: s.MetricsHandler(token), ReadHeaderTimeout: 10 * time.Second})
	s.mu.Lock()
	s.servers = append(s.servers, srv)
	s.mu.Unlock()
	go srv.Serve(ln)
	s.log("metrics: serving /metrics on " + ln.Addr().String())
	return ln.Addr().String(), nil
}
