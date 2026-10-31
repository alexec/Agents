package agentsd

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// #2165: each answered call is counted by day, method and client, never what it said; the
// counts go to features-history.json, and reports/features says them, the least used first.

func featureOf(t *testing.T, u wire.FeatureUsage, method string) wire.FeatureUse {
	t.Helper()
	for _, f := range u.Features {
		if f.Method == method {
			return f
		}
	}
	t.Fatalf("no %s in %+v", method, u.Features)
	return wire.FeatureUse{}
}

func TestFeaturesAreCountedByClient(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	mac := &Client{Role: RoleControl, conn: newConn(), d: d}
	browser := &Client{Role: RoleControl, conn: deviceConn{newConn()}, d: d}
	helper := &Client{Role: RoleAgent, conn: newConn(), d: d}
	stranger := &Client{Role: RoleStranger, conn: newConn(), d: d}
	d.dispatch(mac, message{JSONRPC: "2.0", Method: "milestones/state"})
	d.dispatch(mac, message{JSONRPC: "2.0", Method: "milestones/state"})
	d.dispatch(browser, message{JSONRPC: "2.0", Method: "milestones/state", Params: json.RawMessage(`{"secret":"never kept"}`)})
	d.dispatch(helper, message{JSONRPC: "2.0", Method: "daemon/ping"})
	d.dispatch(stranger, message{JSONRPC: "2.0", Method: "daemon/ping"})
	// Not served, and refused: neither is a feature used.
	d.dispatch(mac, message{JSONRPC: "2.0", Method: "made/up"})
	d.dispatch(stranger, message{JSONRPC: "2.0", Method: "milestones/state"})
	d.countAppTool("00000000-0000-0000-0000-000000000000", "set_session_labels")

	u := d.featureUsage(time.Now())
	if u.Days != 90 || u.Since == nil {
		t.Fatalf("%+v", u)
	}
	m := featureOf(t, u, "milestones/state")
	if m.Week != 3 || m.Quarter != 3 || !slices.Equal(m.Clients, []string{"mac", "web"}) || m.LastUsed == nil {
		t.Fatalf("%+v", m)
	}
	// The helper's ping, not the stranger's.
	if p := featureOf(t, u, "daemon/ping"); p.Week != 1 || !slices.Equal(p.Clients, []string{"agent"}) {
		t.Fatalf("%+v", p)
	}
	if l := featureOf(t, u, appToolMethod("set_session_labels")); l.Quarter != 1 || !slices.Equal(l.Clients, []string{"agent"}) {
		t.Fatalf("%+v", l)
	}
	for _, f := range u.Features {
		if f.Method == "made/up" {
			t.Fatal("a method this host does not serve was counted")
		}
	}
	// The least used first.
	if !slices.IsSortedFunc(u.Features, func(a, b wire.FeatureUse) int { return int(a.Quarter - b.Quarter) }) {
		t.Fatal("not the least used first")
	}

	d.saveFeatures()
	b, err := os.ReadFile(d.featuresPath())
	if err != nil || !strings.Contains(string(b), `"milestones/state"`) || strings.Contains(string(b), "never kept") {
		t.Fatalf("%s %v", b, err)
	}
}

func TestAPairedPhoneIsTheRemote(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.devMu.Lock()
	d.loadDevices()
	d.devRecords = append(d.devRecords, deviceRecord{Device: wire.Device{ID: "11111111-2222-3333-4444-555555555555", Name: "Phone", Kind: wire.DeviceKindIPhone}})
	d.devMu.Unlock()
	phone := &Client{Role: RoleControl, conn: deviceConn{newConn()}, d: d}
	if got := d.featureClient(phone); got != "remote" {
		t.Fatalf("%s", got)
	}
}

func TestFeaturesKeepNinetyDays(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	now := time.Now()
	d.featureMu.Lock()
	f := d.featuresLocked()
	for i := range 120 {
		f.Days[dayStamp(now.AddDate(0, 0, -i-1))] = map[string]map[string]int64{"milestones/state": {"mac": 1}}
	}
	d.featureMu.Unlock()
	d.countFeature("milestones/state", "mac")
	d.featureMu.Lock()
	kept := len(d.features.Days)
	d.featureMu.Unlock()
	if kept != 90 {
		t.Fatalf("%d days kept", kept)
	}
	m := featureOf(t, d.featureUsage(now), "milestones/state")
	if m.Week != 7 || m.Quarter != 90 {
		t.Fatalf("%+v", m)
	}
}
