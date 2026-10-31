package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The OTLP exporter of the report figures (#2019, #1804 decision 4): off unless
// OTEL_EXPORTER_OTLP_ENDPOINT (or _METRICS_ENDPOINT) is set. Each interval it sends the
// organisation's figures for today, UTC, by runtime, as OTLP/HTTP JSON: cumulative sums
// that start at midnight. Spend, tokens, outcomes and time are the rows reports/usage adds
// up; no person, folder or machine is named, so a collector holds no one's work.

const (
	otlpEveryLeast   = time.Minute
	otlpEveryDefault = 5 * time.Minute
	otlpTimeout      = 10 * time.Second
	otlpScope        = "agents-control"
)

// OTLPConfig is where the exporter sends, with what headers, and how often.
type OTLPConfig struct {
	Endpoint string
	Headers  map[string]string
	Every    time.Duration
}

// OTLPFromEnv is the exporter the standard OTel variables say, or nil when none is set:
// OTEL_EXPORTER_OTLP_METRICS_ENDPOINT as it is, or OTEL_EXPORTER_OTLP_ENDPOINT with
// /v1/metrics; OTEL_EXPORTER_OTLP_(METRICS_)HEADERS as k=v,k=v (values URL-encoded); and
// OTEL_METRIC_EXPORT_INTERVAL in milliseconds, at least a minute, five by default.
func OTLPFromEnv(getenv func(string) string) (*OTLPConfig, error) {
	endpoint := strings.TrimSpace(getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"))
	if endpoint == "" {
		if base := strings.TrimSpace(getenv("OTEL_EXPORTER_OTLP_ENDPOINT")); base != "" {
			endpoint = strings.TrimSuffix(base, "/") + "/v1/metrics"
		}
	}
	if endpoint == "" {
		return nil, nil
	}
	u, err := url.Parse(endpoint)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("the OTLP endpoint %q is not an http or https URL", endpoint)
	}
	c := &OTLPConfig{Endpoint: endpoint, Headers: map[string]string{}, Every: otlpEveryDefault}
	headers := getenv("OTEL_EXPORTER_OTLP_METRICS_HEADERS")
	if headers == "" {
		headers = getenv("OTEL_EXPORTER_OTLP_HEADERS")
	}
	for _, pair := range strings.Split(headers, ",") {
		k, v, ok := strings.Cut(pair, "=")
		if !ok || strings.TrimSpace(k) == "" {
			continue
		}
		if decoded, err := url.QueryUnescape(strings.TrimSpace(v)); err == nil {
			v = decoded
		}
		c.Headers[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	if ms := strings.TrimSpace(getenv("OTEL_METRIC_EXPORT_INTERVAL")); ms != "" {
		n, err := strconv.Atoi(ms)
		if err != nil {
			return nil, fmt.Errorf("OTEL_METRIC_EXPORT_INTERVAL %q is not milliseconds", ms)
		}
		c.Every = max(time.Duration(n)*time.Millisecond, otlpEveryLeast)
	}
	return c, nil
}

// otlpExporter is the exporter as this copy runs it, for readApi/list.
type otlpExporter struct {
	cfg    OTLPConfig
	client *http.Client
	mu     sync.Mutex
	state  wire.OTLPExport
}

func (e *otlpExporter) State() *wire.OTLPExport {
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	state := e.state
	return &state
}

// ExportOTLP starts sending the report figures to cfg's endpoint, the first a minute after
// start, while this copy serves.
func (s *Service) ExportOTLP(cfg OTLPConfig) {
	e := &otlpExporter{cfg: cfg, client: &http.Client{Timeout: otlpTimeout},
		state: wire.OTLPExport{Endpoint: redactedEndpoint(cfg.Endpoint), Every: int64(cfg.Every / time.Second)}}
	s.mu.Lock()
	s.otlp = e
	s.mu.Unlock()
	s.log("otlp: sending the report figures to " + e.state.Endpoint + " every " + cfg.Every.String())
	go func() {
		wait := time.Minute
		for {
			select {
			case <-s.stop:
				return
			case <-time.After(wait):
			}
			wait = cfg.Every
			if s.phase.now() != phaseServing {
				continue
			}
			ctx, cancel := context.WithTimeout(context.Background(), otlpTimeout+20*time.Second)
			err := s.sendOTLP(ctx, e, time.Now())
			cancel()
			if err != nil {
				s.log("otlp: not sent: " + err.Error())
			}
		}
	}()
}

// redactedEndpoint is the endpoint with no user or query, for the page and the log.
func redactedEndpoint(endpoint string) string {
	u, err := url.Parse(endpoint)
	if err != nil {
		return ""
	}
	u.User, u.RawQuery, u.Fragment = nil, "", ""
	return u.String()
}

func (s *Service) sendOTLP(ctx context.Context, e *otlpExporter, now time.Time) error {
	body, err := s.otlpBody(ctx, now)
	if err == nil {
		err = e.post(ctx, body)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if err != nil {
		e.state.LastFailure, e.state.FailedAt = optional(err.Error()), optional(dateOf(now))
		return err
	}
	e.state.LastSent = optional(dateOf(now))
	return nil
}

func (e *otlpExporter) post(ctx context.Context, body []byte) error {
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, e.cfg.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", "application/json")
	for k, v := range e.cfg.Headers {
		r.Header.Set(k, v)
	}
	resp, err := e.client.Do(r)
	if err != nil {
		return fmt.Errorf("%s: %w", redactedEndpoint(e.cfg.Endpoint), err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s answered %s", redactedEndpoint(e.cfg.Endpoint), resp.Status)
	}
	return nil
}

// otlpSeries is one metric's points, by their attributes.
type otlpSeries struct {
	name, unit, about string
	points            map[string]*otlpPoint
}

type otlpPoint struct {
	attrs map[string]string
	value float64
}

func (m *otlpSeries) add(value float64, attrs ...string) {
	if value == 0 {
		return
	}
	key := strings.Join(attrs, "\x00")
	p := m.points[key]
	if p == nil {
		p = &otlpPoint{attrs: map[string]string{}}
		for i := 0; i+1 < len(attrs); i += 2 {
			p.attrs[attrs[i]] = attrs[i+1]
		}
		m.points[key] = p
	}
	p.value += value
}

// otlpBody is today's figures, UTC, as an OTLP ExportMetricsServiceRequest in JSON.
func (s *Service) otlpBody(ctx context.Context, now time.Time) ([]byte, error) {
	day := now.UTC().Truncate(24 * time.Hour)
	rows, err := s.reportFrom(ctx, usageHoursPrefix, day.Format(usageHourLayout), func(string) bool { return true })
	if err != nil {
		return nil, err
	}
	series := func(name, unit, about string) *otlpSeries {
		return &otlpSeries{name: name, unit: unit, about: about, points: map[string]*otlpPoint{}}
	}
	cost := series("agents.cost", "{currency}", "What the agents' turns cost today, by currency and runtime.")
	tokens := series("agents.tokens", "{token}", "The tokens the agents used today, by kind and runtime.")
	turns := series("agents.turns", "{turn}", "The agents' turns today, by runtime.")
	sessions := series("agents.sessions", "{session}", "Sessions today, by runtime and outcome.")
	prs := series("agents.pull_requests", "{pull_request}", "Pull requests the agents opened, merged and reverted today, by runtime.")
	runs := series("agents.workflow.runs", "{run}", "Workflow runs today, by runtime and outcome.")
	seconds := series("agents.time", "s", "Seconds the agents worked, or waited for a person, today, by runtime.")
	for _, r := range rows {
		rt := r.Runtime
		for currency, amount := range r.Cost {
			cost.add(amount, "currency", currency, "runtime", rt)
		}
		tokens.add(float64(r.InputTokens), "kind", "input", "runtime", rt)
		tokens.add(float64(r.OutputTokens), "kind", "output", "runtime", rt)
		tokens.add(float64(r.ThoughtTokens), "kind", "thought", "runtime", rt)
		tokens.add(float64(r.CachedReadTokens), "kind", "cachedRead", "runtime", rt)
		tokens.add(float64(r.CachedWriteTokens), "kind", "cachedWrite", "runtime", rt)
		turns.add(float64(r.Turns), "runtime", rt)
		seconds.add(r.WorkingSeconds, "state", "working", "runtime", rt)
		seconds.add(r.WaitingSeconds, "state", "waiting", "runtime", rt)
		if c := r.Counts; c != nil {
			failed := c.FailedSessions
			sessions.add(float64(c.Sessions-failed), "outcome", "ended", "runtime", rt)
			sessions.add(float64(failed), "outcome", "failed", "runtime", rt)
			prs.add(float64(c.PrsOpened), "event", "opened", "runtime", rt)
			prs.add(float64(c.PrsMerged), "event", "merged", "runtime", rt)
			prs.add(float64(c.PrsReverted), "event", "reverted", "runtime", rt)
			fails := c.WorkflowFailures
			runs.add(float64(c.WorkflowRuns-fails), "outcome", "succeeded", "runtime", rt)
			runs.add(float64(fails), "outcome", "failed", "runtime", rt)
		}
	}
	start, at := strconv.FormatInt(day.UnixNano(), 10), strconv.FormatInt(now.UnixNano(), 10)
	var metrics []any
	for _, m := range []*otlpSeries{cost, tokens, turns, sessions, prs, runs, seconds} {
		var points []any
		keys := make([]string, 0, len(m.points))
		for k := range m.points {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			p := m.points[k]
			points = append(points, map[string]any{"attributes": otlpAttributes(p.attrs), "startTimeUnixNano": start,
				"timeUnixNano": at, "asDouble": p.value})
		}
		if len(points) == 0 {
			continue
		}
		metrics = append(metrics, map[string]any{"name": m.name, "unit": m.unit, "description": m.about,
			// AGGREGATION_TEMPORALITY_CUMULATIVE: today's total, from midnight.
			"sum": map[string]any{"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": points}})
	}
	if metrics == nil {
		metrics = []any{}
	}
	name := s.cfg.Name
	if name == "" {
		name = s.cfg.URL
	}
	return json.Marshal(map[string]any{"resourceMetrics": []any{map[string]any{
		"resource": map[string]any{"attributes": otlpAttributes(map[string]string{"service.name": "agents-control",
			"service.instance.id": name})},
		"scopeMetrics": []any{map[string]any{"scope": map[string]any{"name": otlpScope}, "metrics": metrics}},
	}}})
}

func otlpAttributes(attrs map[string]string) []any {
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := []any{}
	for _, k := range keys {
		out = append(out, map[string]any{"key": k, "value": map[string]any{"stringValue": attrs[k]}})
	}
	return out
}
