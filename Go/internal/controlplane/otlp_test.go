package controlplane

// The OTLP exporter (#2019, #1804 decision 4): off unless set, today's figures by runtime
// with no person, folder or machine named, and each send's outcome kept for the page.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func TestOTLPIsSetByTheStandardVariables(t *testing.T) {
	t.Parallel()
	env := func(vars map[string]string) func(string) string { return func(k string) string { return vars[k] } }
	if c, err := OTLPFromEnv(env(nil)); c != nil || err != nil {
		t.Fatal("on with nothing set")
	}
	c, err := OTLPFromEnv(env(map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.com:4318/",
		"OTEL_EXPORTER_OTLP_HEADERS": "authorization=Bearer%20abc, x-team = data"}))
	if err != nil || c.Endpoint != "https://otel.example.com:4318/v1/metrics" || c.Headers["authorization"] != "Bearer abc" ||
		c.Headers["x-team"] != "data" || c.Every != otlpEveryDefault {
		t.Fatalf("%+v %v", c, err)
	}
	c, _ = OTLPFromEnv(env(map[string]string{"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://collector/metrics",
		"OTEL_EXPORTER_OTLP_ENDPOINT": "http://other", "OTEL_METRIC_EXPORT_INTERVAL": "1000"}))
	if c.Endpoint != "http://collector/metrics" || c.Every != otlpEveryLeast {
		t.Fatalf("%+v", c)
	}
	for _, bad := range []map[string]string{{"OTEL_EXPORTER_OTLP_ENDPOINT": "collector:4318"},
		{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://c", "OTEL_METRIC_EXPORT_INTERVAL": "soon"}} {
		if _, err := OTLPFromEnv(env(bad)); err == nil {
			t.Fatalf("%v taken", bad)
		}
	}
}

func TestOTLPSendsTodaysFiguresByRuntime(t *testing.T) {
	t.Parallel()
	var got map[string]any
	var auth string
	fail := false
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fail {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		auth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &got)
	}))
	defer collector.Close()

	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	sendUsage(t, p, owner.member.Host,
		wire.UsageRollupRow{Folder: "secret-folder", Runtime: "claude", Cost: map[string]float64{"USD": 2}, InputTokens: 100, Turns: 2,
			WorkingSeconds: 60, Counts: &wire.ReportCounts{Sessions: 3, FailedSessions: 1, PrsMerged: 1}},
		wire.UsageRollupRow{Folder: "site", Runtime: "codex", Cost: map[string]float64{"USD": 1}, InputTokens: 50, Turns: 1})

	p.s.ExportOTLP(OTLPConfig{Endpoint: collector.URL + "/v1/metrics?key=x", Headers: map[string]string{"Authorization": "Bearer abc"}, Every: time.Hour})
	e := p.s.otlp
	if err := p.s.sendOTLP(t.Context(), e, time.Now()); err != nil {
		t.Fatal(err)
	}
	if auth != "Bearer abc" {
		t.Fatal(auth)
	}
	raw, _ := json.Marshal(got)
	text := string(raw)
	for _, want := range []string{`"agents.cost"`, `"agents.tokens"`, `"agents.sessions"`, `"agents.pull_requests"`, `"agents.time"`,
		`"aggregationTemporality":2`, `"stringValue":"codex"`, `"service.name"`} {
		if !strings.Contains(text, want) {
			t.Fatalf("no %s in %s", want, text)
		}
	}
	for _, never := range []string{"secret-folder", "OWNERS-MAC", "Local owner"} {
		if strings.Contains(text, never) {
			t.Fatalf("%s named in %s", never, text)
		}
	}
	// The claude cost point: 2 USD.
	if !strings.Contains(text, `{"asDouble":2,"attributes":[{"key":"currency","value":{"stringValue":"USD"}},{"key":"runtime","value":{"stringValue":"claude"}}]`) {
		t.Fatalf("%s", text)
	}

	// The page sees where it sends, with no query, and the last send; then a failure.
	var state wire.ReadAPI
	json.Unmarshal(call(t, admin, "", "readApi/list", wire.Empty{}), &state)
	if state.Otlp == nil || state.Otlp.Endpoint != collector.URL+"/v1/metrics" || state.Otlp.LastSent == nil || state.Otlp.Every != 3600 {
		t.Fatalf("%+v", state.Otlp)
	}
	fail = true
	if err := p.s.sendOTLP(t.Context(), e, time.Now()); err == nil {
		t.Fatal("a 503 was taken")
	}
	if s := e.State(); s.LastFailure == nil || !strings.Contains(*s.LastFailure, "503") || strings.Contains(*s.LastFailure, "key=x") {
		t.Fatalf("%+v", s)
	}
}
