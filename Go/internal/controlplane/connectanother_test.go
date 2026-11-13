package controlplane

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// clientOfKind is p.client, recorded as a client of that kind.
func (p *plane) clientOfKind(name string, kind string) *controllink.Session {
	m, session := p.client(name)
	if err := p.s.Records().ChangeClient(context.Background(), m.Client, func(c *records.ClientRecord) bool {
		c.Kind = kind
		return true
	}); err != nil {
		p.t.Fatal(err)
	}
	return session
}

// The page this Mac serves asks for Connect to Another… (#4257): the Mac's window is told
// what to connect to, not the browser, and what the window reports reaches the page.
func TestThePageAsksTheMacWindowToConnectAnother(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		c.HostJoinFile = filepath.Join(t.TempDir(), "control-join.json")
	})
	page := p.clientOfKind("browser", records.KindBrowser)
	if got := callError(t, page, "", "control/connectAnother", map[string]any{"hosted": true}); !strings.Contains(got, "isn’t open on this Mac") {
		t.Fatalf("with no window: %s", got)
	}
	window := p.clientOfKind("Mac", records.KindMac)
	// The window says control/status first, as it does on each connect.
	call(t, window, "", "control/status", nil)
	if got := callError(t, page, "", "control/connectAnother", map[string]any{"hosted": true, "code": "agents://x"}); !strings.Contains(got, "not both") {
		t.Fatalf("both: %s", got)
	}
	call(t, page, "", "control/connectAnother", map[string]any{"code": " agents://pair#code "})
	var want wire.ConnectAnotherRequest
	if err := json.Unmarshal(waitNote(t, window, wire.NotifyControlConnectWanted.Name).Params, &want); err != nil {
		t.Fatal(err)
	}
	if want.Code == nil || *want.Code != "agents://pair#code" || want.Hosted != nil {
		t.Fatalf("the window was told %+v", want)
	}
	if got := callError(t, page, "", "control/connectReport", map[string]any{"step": "Pairing…"}); !strings.Contains(got, "Only Agents on a Mac") {
		t.Fatalf("a browser reports: %s", got)
	}
	call(t, window, "", "control/connectReport", map[string]any{"step": "Pairing…"})
	var report wire.ConnectReport
	if err := json.Unmarshal(waitNote(t, page, wire.NotifyControlConnectReported.Name).Params, &report); err != nil {
		t.Fatal(err)
	}
	if report.Step == nil || *report.Step != "Pairing…" {
		t.Fatalf("the page heard %+v", report)
	}
}

// A control plane that no Mac's Agents started (a server's, Hosted's) has nothing to connect.
func TestOnlyAControlPlaneOnAMacConnectsAnother(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	page := p.clientOfKind("browser", records.KindBrowser)
	p.clientOfKind("Mac", records.KindMac)
	if got := callError(t, page, "", "control/connectAnother", map[string]any{"hosted": true}); !strings.Contains(got, "isn’t run by Agents on a Mac") {
		t.Fatal(got)
	}
}
