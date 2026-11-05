package controlplane

// The observability walk (#3417): a scratch control plane sends to real tools that
// Go/internal/controlplane/walk/observability starts in containers. The audit goes to
// Graylog by syslog over TLS and by HTTP, the report figures to an OpenTelemetry
// Collector with Prometheus behind it, and the read API is left up for Grafana's
// Infinity source to read. It runs only when walk.sh sets AGENTS_WALK_OBSERVABILITY to
// its folder; the checks of what arrived are walk.sh's. The SIEM's certificate is the
// walk's own CA's, as a company's SIEM often is, trusted by SSL_CERT_FILE as on a Linux
// control plane.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// walkBurst is three full batches of the 500 lines a send carries.
const walkBurst = 1500

func TestWalkObservability(t *testing.T) {
	folder := os.Getenv("AGENTS_WALK_OBSERVABILITY")
	if folder == "" {
		t.Skip("AGENTS_WALK_OBSERVABILITY is not set: walk.sh runs this")
	}
	env := func(name, otherwise string) string {
		if v := os.Getenv(name); v != "" {
			return v
		}
		return otherwise
	}
	// The plane is "walk" on the tools' network, so Grafana can reach the read API; its
	// own address stays loopback, which is all a code may name over http.
	keeper := withKeeper(newKeeperKey())
	port := ""
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		keeper(c)
		c.Bind, port = "0.0.0.0", itoa(c.Port)
	})
	_, admin := p.client("Walk window")
	host := p.host("WALK-MAC")

	token := env("WALK_HTTP_TOKEN", "walk-3417-token")
	var state wire.AuditSinksState
	json.Unmarshal(call(t, admin, "", "audit/setSinks", wire.AuditSinks{Sinks: []wire.AuditSink{
		{Kind: wire.AuditSinkKindSyslog, Address: env("WALK_SYSLOG", "tls://graylog:6514")},
		{Kind: wire.AuditSinkKindHttp, Address: env("WALK_HTTP", "https://graylog:8090/raw"), Token: &token},
	}}), &state)
	for days := int64(30); days <= 32; days++ {
		call(t, admin, "", "control/setAuditDays", wire.AuditDays{Days: days})
	}
	// Once a second: a device that asks faster is told to wait.
	sent := func() bool {
		json.Unmarshal(call(t, admin, "", "audit/sinks", wire.Empty{}), &state)
		for _, s := range state.Sinks {
			if s.Queued > 0 || s.SentAt == nil {
				return false
			}
		}
		return len(state.Sinks) == 2
	}
	for deadline := time.Now().Add(time.Minute); !sent(); time.Sleep(time.Second) {
		if time.Now().After(deadline) {
			t.Fatalf("the sinks did not send: %s", mustMarshal(state))
		}
	}
	// A burst, as after a SIEM was down: full batches of sinkBatch lines, each line the size
	// of a real entry.
	pad := strings.Repeat("x", 300)
	for n := range walkBurst {
		p.s.auditSinks.Add(fmt.Sprintf("v1/events/walk-burst/%d.json", n),
			[]byte(fmt.Sprintf(`{"method":"walk/burst","n":%d,"pad":%q}`, n, pad)))
	}
	for deadline := time.Now().Add(time.Minute); !sent(); time.Sleep(time.Second) {
		if time.Now().After(deadline) {
			t.Fatalf("the burst was not sent: %s", mustMarshal(state))
		}
	}
	t.Logf("sinks: %s", mustMarshal(state))

	sendUsage(t, p, host.member.Host,
		wire.UsageRollupRow{Folder: "walk", Runtime: "claude", Cost: map[string]float64{"USD": 2.5}, InputTokens: 1200,
			OutputTokens: 300, Turns: 4, WorkingSeconds: 90},
		wire.UsageRollupRow{Folder: "walk", Runtime: "codex", Cost: map[string]float64{"USD": 0.75}, InputTokens: 400,
			OutputTokens: 100, Turns: 2, WorkingSeconds: 30})
	p.s.ExportOTLP(OTLPConfig{Endpoint: env("WALK_OTLP", "http://collector:4318/v1/metrics"), Every: time.Hour})
	if err := p.s.sendOTLP(context.Background(), p.s.otlp, time.Now()); err != nil {
		t.Fatalf("OTLP: %v", err)
	}

	var made wire.ReadTokenMade
	json.Unmarshal(call(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "Grafana"}), &made)
	var listed wire.ReadAPI
	json.Unmarshal(call(t, admin, "", "readApi/list", wire.Empty{}), &listed)
	t.Logf("read API: %s", mustMarshal(listed))
	out, _ := json.Marshal(map[string]string{"url": "http://" + env("WALK_PLANE_HOST", "walk") + ":" + port,
		"made": made.URL, "token": made.Value, "tokenId": made.Token.ID})
	if err := os.WriteFile(filepath.Join(folder, "plane.json"), out, 0o600); err != nil {
		t.Fatal(err)
	}

	// walk.sh reads the tools, then revokes the token by writing revoke, and the plane
	// waits for done.
	stay, _ := strconv.Atoi(env("WALK_MINUTES", "10"))
	deadline := time.Now().Add(time.Duration(stay) * time.Minute)
	revoked := false
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(folder, "done")); err == nil {
			return
		}
		if _, err := os.Stat(filepath.Join(folder, "revoke")); err == nil && !revoked {
			call(t, admin, "", "readApi/revoke", wire.ReadTokenRevoke{ID: made.Token.ID})
			os.WriteFile(filepath.Join(folder, "revoked"), nil, 0o600)
			revoked = true
		}
		time.Sleep(500 * time.Millisecond)
	}
}
