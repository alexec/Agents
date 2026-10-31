package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// driver is Handover.Link: the handover's side that Agents Host's Swift tool takes.
type driver struct {
	t     *testing.T
	lines *controllink.Lines
	next  int
}

func drive(t *testing.T, at string, private []byte) *driver {
	public, _ := controllink.PublicKey(private)
	lines, _, err := controllink.Join(context.Background(), at, "", controllink.Credentials{
		Identity: "x:" + handoverPrefix + "test", Key: controllink.CopyKey(private), Kind: "copy", ControlKey: public})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lines.Close)
	return &driver{t: t, lines: lines}
}

func (d *driver) call(method string, params any) (json.RawMessage, string) {
	d.t.Helper()
	d.next++
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	d.lines.Write(ctx, request(itoa(d.next), method, params))
	line, err := d.lines.Read(ctx)
	if err != nil {
		d.t.Fatal(err)
	}
	var r struct {
		Result json.RawMessage `json:"result"`
		Error  *RPCError       `json:"error"`
	}
	json.Unmarshal([]byte(line), &r)
	if r.Error != nil {
		return nil, r.Error.Message
	}
	return r.Result, ""
}

func (d *driver) must(method string, params any) json.RawMessage {
	d.t.Helper()
	r, refused := d.call(method, params)
	if refused != "" {
		d.t.Fatalf("%s: %s", method, refused)
	}
	return r
}

func phaseOf(raw json.RawMessage) string {
	var s wire.HandoverStatus
	json.Unmarshal(raw, &s)
	return s.Phase
}

// Freezing refuses what changes records, in words, and unfreezing lets it through again;
// the relay switch goes the same way (#809).
func TestAFrozenCopyChangesNothing(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	d := drive(t, p.url, p.private)
	if phaseOf(d.must("handover/status", nil)) != phaseServing {
		t.Fatal("not serving")
	}
	if _, refused := d.call("store/list", nil); !strings.Contains(refused, "Freeze") {
		t.Fatal(refused)
	}
	d.must("handover/freeze", nil)
	if e := callError(t, window, "", "clients/startPairing", nil); !strings.Contains(e, "moving to another machine") {
		t.Fatal(e)
	}
	call(t, window, "", "hosts/list", nil)
	d.must("handover/unfreeze", nil)
	call(t, window, "", "clients/startPairing", nil)
	if _, refused := d.call("relay/set", map[string]any{"host": "nobody", "relay": true}); !strings.Contains(refused, "No machine is called nobody") {
		t.Fatal(refused)
	}
}

// The whole move (R16): a copy started empty to receive is filled from a frozen copy,
// takes over, and the old copy forwards; a member that comes back is given the new list,
// and joins the new copy with the pairing it had.
func TestAHandoverMovesAMemberWithoutPairingAgain(t *testing.T) {
	t.Parallel()
	key := controllink.NewPrivateKey()
	old := startPlane(t, store.NewMemory(), key)
	member, _ := old.client("Window")

	port := freePort(t)
	newURL := "http://127.0.0.1:" + itoa(port)
	fresh, err := New(Config{Store: store.NewMemory(), PrivateKey: key, URL: newURL, Bind: "127.0.0.1", Port: port,
		Name: "Moved", MachineID: "MACHINE-2", Receive: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fresh.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(fresh.Stop)
	// While it receives, a member is told to try again, not that it is unknown.
	m := *member
	m.URL = newURL
	if _, err := controllink.DialClient(context.Background(), &m); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatal(err)
	}

	from, to := drive(t, old.url, key), drive(t, newURL, key)
	if phaseOf(to.must("handover/status", nil)) != phaseReceiving {
		t.Fatal("not receiving")
	}
	// Hosts that never said an epoch would be left behind: none here.
	from.must("handover/freeze", nil)
	var keys []struct{ Key string }
	json.Unmarshal(from.must("store/list", map[string]string{"prefix": "v1/"}), &keys)
	for _, k := range keys {
		if strings.HasPrefix(k.Key, "v1/leases/") || strings.HasPrefix(k.Key, "v1/copies/") {
			continue
		}
		var object struct{ Data string }
		json.Unmarshal(from.must("store/get", map[string]string{"key": k.Key}), &object)
		to.must("store/put", map[string]string{"key": k.Key, "data": object.Data})
	}
	if phaseOf(to.must("handover/take", nil)) != phaseServing {
		t.Fatal("did not take over")
	}
	if phaseOf(from.must("handover/forward", map[string]any{"endpoints": []records.Endpoint{{URL: newURL}}})) != phaseForwarding {
		t.Fatal("not forwarding")
	}
	// Back at the old copy, the member's ok carries the new list, and the socket ends.
	public, _ := controllink.PublicKey(member.Private)
	_ = public
	clientKey, _ := controllink.ClientKey(member.Private, member.ControlKey, member.Client)
	epoch := 0
	_, ok, err := controllink.Join(context.Background(), old.url, "", controllink.Credentials{Identity: "c:" + member.Client,
		Key: clientKey, Kind: "mac", ControlKey: member.ControlKey, Epoch: &epoch})
	if err != nil {
		t.Fatal(err)
	}
	endpoints := ok.Endpoints
	if len(endpoints) != 1 || endpoints[0].URL != newURL || ok.Epoch == nil {
		t.Fatalf("%+v", ok.Endpoints)
	}
	// At the new copy, the same pairing works.
	window, err := controllink.DialClient(context.Background(), &m)
	if err != nil {
		t.Fatal(err)
	}
	defer window.Close()
	var status struct {
		Name string `json:"name"`
	}
	json.Unmarshal(call(t, window, "", "control/status", nil), &status)
	if status.Name == "" {
		t.Fatal("no status")
	}
}

// A Go host follows a move (R16, T125, #1490): told the new place in ok, it dials there,
// keeps the list in its root, and never dials the forwarding copy in a tight loop.
func TestAHostFollowsAMoveToAnotherCopy(t *testing.T) {
	t.Parallel()
	key := controllink.NewPrivateKey()
	old := startPlane(t, store.NewMemory(), key)
	host := old.host("MACHINE-H")
	fresh := startPlaneWith(t, store.NewMemory(), key, func(c *Config) { c.Receive = true })

	at := drive(t, old.url, key)
	at.must("handover/announce", map[string]any{"endpoint": records.Endpoint{URL: fresh.url}})
	at.must("handover/freeze", nil)
	if _, _, err := CopyStore(context.Background(), old.store, fresh.store); err != nil {
		t.Fatal(err)
	}
	drive(t, fresh.url, key).must("handover/take", nil)
	at.must("handover/forward", map[string]any{"endpoints": []records.Endpoint{{URL: fresh.url}}})

	fresh.waitFor(func() bool { s, ok := fresh.s.Router().State(host.member.Host); return ok && s.online() }, "the host at the new copy")
	kept, err := controllink.LoadMembership(host.root)
	if err != nil || kept.URL != fresh.url || kept.Epoch == nil || len(kept.Endpoints) != 1 {
		t.Fatalf("%+v %v", kept, err)
	}
}
