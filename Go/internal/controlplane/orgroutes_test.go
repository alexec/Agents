package controlplane

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// routesTold is every machine/orgRoutes each machine was told, by machine.
type routesTold struct {
	mu  sync.Mutex
	got map[string][]wire.OrgRouteDelivery
}

func newRoutesTold() *routesTold { return &routesTold{got: map[string][]wire.OrgRouteDelivery{}} }

func (d *routesTold) heard(host, method string, params json.RawMessage) {
	if method != wire.NotifyMachineOrgRoutes.Name {
		return
	}
	var delivery wire.OrgRouteDelivery
	json.Unmarshal(params, &delivery)
	d.mu.Lock()
	d.got[host] = append(d.got[host], delivery)
	d.mu.Unlock()
}

func (d *routesTold) last(host string) (wire.OrgRouteDelivery, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	list := d.got[host]
	if len(list) == 0 {
		return wire.OrgRouteDelivery{}, false
	}
	return list[len(list)-1], true
}

func (d *routesTold) count(host string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.got[host])
}

// route is the route id in what host was told last, or nil.
func (d *routesTold) route(host, id string) *wire.DeliveredRoute {
	delivery, _ := d.last(host)
	for _, r := range delivery.Routes {
		if r.ID == id {
			return &r
		}
	}
	return nil
}

// opened is what a delivered route's field opens to with the machine's own key.
func opened(t *testing.T, box *fakeHost, r *wire.DeliveredRoute, field string) string {
	t.Helper()
	plain, err := OpenOrgRoute(box.private, r.ID, box.member.Host, r.Version, r.Sealed[field])
	if err != nil {
		t.Fatalf("%s's %s does not open: %v", r.ID, field, err)
	}
	return string(plain)
}

// routesHello is a machine that keeps org routes.
func routesHello(name string) controllink.MachineHello {
	hello := fakeHello(name)
	hello.Capabilities = append(slices.Clone(hello.Capabilities), CapHostOrgRoutes)
	return hello
}

// withKeeper is a control plane with a local keeper for secrets.
func withKeeper(key []byte) func(*Config) {
	return func(c *Config) { c.SecretKeeper = "base64key://" + base64.URLEncoding.EncodeToString(key) }
}

func newKeeperKey() []byte {
	key := make([]byte, 32)
	rand.Read(key)
	return key
}

func setRoute(t *testing.T, s *controllink.Session, route wire.OrgRoute, secrets map[string]string, rev *string) wire.OrgRouteKept {
	t.Helper()
	var kept wire.OrgRouteKept
	json.Unmarshal(call(t, s, "", "orgRoutes/set", wire.OrgRouteSet{Route: route, Secrets: secrets, Rev: rev}), &kept)
	return kept
}

func listRoutes(t *testing.T, s *controllink.Session) wire.OrgRouteList {
	t.Helper()
	var list wire.OrgRouteList
	json.Unmarshal(call(t, s, "", "orgRoutes/list", nil), &list)
	return list
}

func vendor(v wire.OrgRouteVendor) *wire.OrgRouteVendor { return &v }

// storeHolds says whether any object under v1/ holds a value: as it is, in base64 or in hex.
func storeHolds(t *testing.T, st store.Store, value string) bool {
	t.Helper()
	keys, err := st.List(t.Context(), "v1/")
	if err != nil {
		t.Fatal(err)
	}
	forms := [][]byte{[]byte(value), []byte(base64.StdEncoding.EncodeToString([]byte(value))),
		[]byte(base64.RawURLEncoding.EncodeToString([]byte(value))), []byte(hex.EncodeToString([]byte(value)))}
	for _, k := range keys {
		object, _ := st.Get(t.Context(), k.Key)
		if object == nil {
			continue
		}
		for _, f := range forms {
			if bytes.Contains(object.Data, f) {
				t.Logf("%s holds it", k.Key)
				return true
			}
		}
	}
	return false
}

// SC-001, US1: a control plane with no route sends an empty list to a machine that keeps
// routes, nothing to one that does not, and writes nothing.
func TestNoRouteSendsAnEmptyListAndChangesNothing(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), withKeeper(newKeeperKey()))
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	box := p.hostSaying(routesHello("MACHINE-2"), nil)
	older := p.host("MACHINE-3")

	p.waitFor(func() bool { _, ok := told.last(box.member.Host); return ok }, "the machine told at its join")
	if delivery, _ := told.last(box.member.Host); delivery.Routes == nil || len(delivery.Routes) != 0 {
		t.Fatalf("%+v", delivery)
	}
	if _, ok := told.last(older.member.Host); ok {
		t.Fatal("a machine that does not keep routes was told some")
	}
	var mine wire.OrgRoutesMine
	json.Unmarshal(call(t, window, "", "orgRoutes/mine", nil), &mine)
	if len(mine.Routes) != 0 {
		t.Fatalf("%+v", mine)
	}
	if list := listRoutes(t, window); len(list.Routes) != 0 || !list.Sealing {
		t.Fatalf("%+v", list)
	}
	call(t, window, box.member.Host, "daemon/ping", nil)
	if objects, _ := p.store.List(t.Context(), "v1/org"); len(objects) != 0 {
		t.Fatalf("a route was written: %+v", objects)
	}
}

// FR-001 to FR-004, US2: an admin's save is bounded by the spec's table, conditional on its
// rev and one version higher; no method gives a value back; the store holds none; a member
// sees only names; a control plane with no keeper keeps no secret.
func TestAnAdminKeepsARouteAndNoValueComesBack(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), withKeeper(newKeeperKey()))
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	priya := p.invite(window, "Priya", wire.UserRoleAdmin)
	const key = "sk-ant-org-0123456789abcdef"

	anthropic := vendor(wire.OrgRouteVendorAnthropic)
	good := wire.OrgRoute{Name: "Acme Anthropic", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"claude", "opencode"},
		DefaultFor: []string{"claude"}}
	for _, bad := range []struct {
		route   wire.OrgRoute
		secrets map[string]string
	}{
		{wire.OrgRoute{Name: "Grok", Kind: wire.OrgRouteKindKey, Vendor: vendor(wire.OrgRouteVendorXai), Runtimes: []string{"grok"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Codex Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"codex"},
			Settings: &wire.OrgRouteSettings{Region: optional("us-east-1")}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Codex Anthropic", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"codex"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Cursor", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"cursor"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: strings.Repeat("n", 61), Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"claude"}}, map[string]string{"apiKey": key}},
		{good, nil},
		{good, map[string]string{"password": key}},
		{good, map[string]string{"apiKey": strings.Repeat("k", 17<<10)}},
		{wire.OrgRoute{Name: "No vendor", Kind: wire.OrgRouteKindKey, Runtimes: []string{"claude"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Default", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"claude"}, DefaultFor: []string{"codex"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"}}, map[string]string{"apiKey": key}},
		{wire.OrgRoute{Name: "Bedrock both", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"}, Settings: &wire.OrgRouteSettings{Region: optional("us-east-1")}},
			map[string]string{"apiKey": key, "awsAccessKeyId": "AKIA", "awsSecretAccessKey": "s"}},
		{wire.OrgRoute{Name: "Plain http", Kind: wire.OrgRouteKindBaseURL, Vendor: anthropic, Runtimes: []string{"claude"},
			Settings: &wire.OrgRouteSettings{Address: optional("http://gateway.example.com")}}, nil},
		{wire.OrgRoute{Name: "Vertex", Kind: wire.OrgRouteKindVertex, Runtimes: []string{"claude"},
			Settings: &wire.OrgRouteSettings{Project: optional("p"), Location: optional("us-east5")}}, map[string]string{"serviceAccount": "{}"}},
		{wire.OrgRoute{Name: "No group", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"claude"}, Groups: []string{"nobody"}}, map[string]string{"apiKey": key}},
	} {
		if e := callError(t, window, "", "orgRoutes/set", wire.OrgRouteSet{Route: bad.route, Secrets: bad.secrets}); !strings.Contains(e, "-32602") {
			t.Errorf("%+v: %s", bad.route.Name, e)
		}
	}
	// A member changes nothing, and reads only the routes they may use, by name.
	for _, method := range []string{"orgRoutes/list", "orgRoutes/set", "orgRoutes/replaceKey", "orgRoutes/check", "orgRoutes/remove"} {
		if e := callError(t, sam.window, "", method, map[string]any{"route": good, "id": "x", "rev": "x", "secrets": map[string]string{"apiKey": key}}); !strings.Contains(e, "-32045") {
			t.Errorf("%s: %s", method, e)
		}
	}

	first := setRoute(t, window, good, map[string]string{"apiKey": key}, nil)
	r := first.Route
	if r.ID != "acme-anthropic" || deref(r.Version) != 1 || first.Rev == "" || !slices.Equal(r.SecretFields, []string{"apiKey"}) ||
		len(r.Fingerprint["apiKey"]) != 8 || r.Created == nil || r.Created.By.User != p.s.localOwner() {
		t.Fatalf("%+v", first)
	}
	// The same id again, with no rev, is told to load it.
	if e := callError(t, priya.window, "", "orgRoutes/set", wire.OrgRouteSet{Route: good, Secrets: map[string]string{"apiKey": key}}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	// Two admins read the same rev; the second to save is told to load it again.
	renamed := r
	renamed.Name = "Acme"
	second := setRoute(t, window, renamed, nil, &first.Rev)
	if deref(second.Route.Version) != 2 || second.Route.Fingerprint["apiKey"] != r.Fingerprint["apiKey"] {
		t.Fatalf("%+v", second.Route)
	}
	if e := callError(t, priya.window, "", "orgRoutes/set", wire.OrgRouteSet{Route: renamed, Rev: &first.Rev}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}

	// No method gives the value back, to an admin or a member.
	var mine wire.OrgRoutesMine
	answers := [][]byte{call(t, window, "", "orgRoutes/list", nil), call(t, sam.window, "", "orgRoutes/mine", nil),
		call(t, priya.window, "", "orgRoutes/list", nil)}
	json.Unmarshal(answers[1], &mine)
	if len(mine.Routes) != 1 || mine.Routes[0].Name != "Acme" || !slices.Equal(mine.Routes[0].DefaultFor, []string{"claude"}) {
		t.Fatalf("%+v", mine)
	}
	for _, a := range answers {
		if bytes.Contains(a, []byte(key)) || bytes.Contains(a, []byte("sk-ant")) {
			t.Fatalf("a value came back: %s", a)
		}
	}
	if bytes.Contains(answers[1], []byte("fingerprint")) || bytes.Contains(answers[1], []byte("settings")) {
		t.Fatalf("a member was told more than names: %s", answers[1])
	}
	// The store holds the envelope, never the value.
	if storeHolds(t, p.store, key) {
		t.Fatal("the store holds the key")
	}
	if object, _ := p.store.Get(t.Context(), orgSecretKey("acme-anthropic")); object == nil {
		t.Fatal("no envelope")
	}

	// A control plane with no keeper keeps no secret; a base URL with no key it may keep.
	bare := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, bareWindow := bare.client("Alex's Mac")
	if e := callError(t, bareWindow, "", "orgRoutes/set", wire.OrgRouteSet{Route: good, Secrets: map[string]string{"apiKey": key}}); !strings.Contains(e, "-32009") || !strings.Contains(e, "no key to seal") {
		t.Fatal(e)
	}
	gateway := setRoute(t, bareWindow, wire.OrgRoute{Name: "Local LiteLLM", Kind: wire.OrgRouteKindBaseURL, Vendor: vendor(wire.OrgRouteVendorOpenai),
		Runtimes: []string{"codex"}, Settings: &wire.OrgRouteSettings{Address: optional("http://127.0.0.1:4000")}}, nil, nil)
	if deref(gateway.Route.Version) != 1 || len(gateway.Route.SecretFields) != 0 {
		t.Fatalf("%+v", gateway)
	}
	if list := listRoutes(t, bareWindow); list.Sealing || len(list.Routes) != 1 {
		t.Fatalf("%+v", list)
	}
}

// FR-005, SC-002: two copies, three machines of two people across them, and a route for a
// group: only the group's machines get it, within 5 seconds, and each envelope opens with
// that machine's key only, and not as another route, machine or version.
func TestARouteReachesOnlyTheMachinesAllowed(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	st, private, keeper := store.NewMemory(), controllink.NewPrivateKey(), newKeeperKey()
	a, b := startCopyWith(t, st, private, withKeeper(keeper)), startCopyWith(t, st, private, withKeeper(keeper))
	a.waitFor(func() bool { return len(a.s.mesh.peers()) == 1 && len(b.s.mesh.peers()) == 1 }, "the copies linked")
	told := newRoutesTold()
	a.told, b.told = told.heard, told.heard
	_, window := a.client("Admin's Mac")
	alex := &person{id: a.s.localOwner(), window: window}
	sam := a.invite(window, "Sam", wire.UserRoleMember)
	alexBox := a.machineSaying(alex, routesHello("MACHINE-2"))
	samAtA := a.machineSaying(sam, routesHello("MACHINE-3"))
	samAtB := b.machineSaying(sam, routesHello("MACHINE-4"))
	for _, m := range []*fakeHost{alexBox, samAtA, samAtB} {
		a.waitFor(func() bool { _, ok := told.last(m.member.Host); return ok }, "each machine told at its join")
	}
	var platform wire.Group
	json.Unmarshal(call(t, window, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)

	const key = "sk-proj-org-key-for-platform"
	saved := time.Now()
	kept := setRoute(t, window, wire.OrgRoute{ID: "platform-openai", Name: "Platform OpenAI", Kind: wire.OrgRouteKindKey,
		Vendor: vendor(wire.OrgRouteVendorOpenai), Runtimes: []string{"codex"}, Groups: []string{platform.ID}}, map[string]string{"apiKey": key}, nil)
	for _, m := range []*fakeHost{samAtA, samAtB} {
		a.waitFor(func() bool { return told.route(m.member.Host, "platform-openai") != nil }, "Sam's machines told the route")
	}
	if took := time.Since(saved); took > 5*time.Second {
		t.Fatalf("took %v", took)
	}
	time.Sleep(300 * time.Millisecond)
	if r := told.route(alexBox.member.Host, "platform-openai"); r != nil {
		t.Fatal("a machine of a person outside the group was told the route")
	}
	r := told.route(samAtB.member.Host, "platform-openai")
	if r.Version != 1 || r.Name != "Platform OpenAI" || !slices.Equal(r.SecretFields, []string{"apiKey"}) || r.Expires != nil {
		t.Fatalf("%+v", r)
	}
	if got := opened(t, samAtB, r, "apiKey"); got != key {
		t.Fatalf("opened %q", got)
	}
	sealed := r.Sealed["apiKey"]
	if bytes.Contains(sealed.Ciphertext, []byte(key)) {
		t.Fatal("the key is in the clear")
	}
	// Another machine's key, another machine's id, another route's id or an older version
	// does not open it.
	if _, err := OpenOrgRoute(samAtA.private, r.ID, samAtB.member.Host, r.Version, sealed); err == nil {
		t.Fatal("another machine's key opens it")
	}
	if _, err := OpenOrgRoute(samAtB.private, r.ID, samAtA.member.Host, r.Version, sealed); err == nil {
		t.Fatal("it opens as another machine's")
	}
	if _, err := OpenOrgRoute(samAtB.private, "another", samAtB.member.Host, r.Version, sealed); err == nil {
		t.Fatal("it opens as another route")
	}
	if _, err := OpenOrgRoute(samAtB.private, r.ID, samAtB.member.Host, r.Version+1, sealed); err == nil {
		t.Fatal("it opens as another version")
	}

	// Each machine says it keeps it; the list counts them.
	for _, m := range []*fakeHost{samAtA, samAtB} {
		if _, err := m.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesApplied.Name,
			wire.OrgRoutesApplied{Routes: []wire.OrgRouteVersion{{ID: "platform-openai", Version: 1}}}); err != nil {
			t.Fatal(err)
		}
	}
	a.waitFor(func() bool {
		list := listRoutes(t, window)
		return len(list.Routes) == 1 && deref(list.Routes[0].Route.Machines) == 2
	}, "two machines hold the route")

	// A machine that joins later gets it at its join; one that asks again gets it again.
	later := b.machineSaying(sam, routesHello("MACHINE-5"))
	a.waitFor(func() bool { return told.route(later.member.Host, "platform-openai") != nil }, "a later machine told the route")
	n := told.count(later.member.Host)
	if _, err := later.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesAgain.Name, wire.Empty{}); err != nil {
		t.Fatal(err)
	}
	a.waitFor(func() bool { return told.count(later.member.Host) > n }, "the machine told again")
	_ = kept
}

// FR-004, US4: a replaced key reaches the machines as a new version; a person taken out of
// the group and a removed route give an empty list; the audit says "key replaced" and holds
// no value; a removed machine's person and the admins hear which routes it held.
func TestReplaceAndRemoveARoute(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), withKeeper(newKeeperKey()))
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	box := p.machineSaying(sam, routesHello("MACHINE-2"))
	spare := p.machineSaying(sam, routesHello("MACHINE-3"))
	var platform wire.Group
	json.Unmarshal(call(t, window, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)

	const oldKey, newKey = "sk-ant-old-key-111111", "sk-ant-new-key-222222"
	kept := setRoute(t, window, wire.OrgRoute{Name: "Acme", Kind: wire.OrgRouteKindKey, Vendor: vendor(wire.OrgRouteVendorAnthropic),
		Runtimes: []string{"claude"}, Groups: []string{platform.ID}}, map[string]string{"apiKey": oldKey}, nil)
	p.waitFor(func() bool { return told.route(box.member.Host, "acme") != nil }, "the machine told the route")

	var replaced wire.OrgRouteKept
	json.Unmarshal(call(t, window, "", "orgRoutes/replaceKey", wire.OrgRouteReplaceKey{ID: "acme", Secrets: map[string]string{"apiKey": newKey}, Rev: kept.Rev}), &replaced)
	if deref(replaced.Route.Version) != 2 || replaced.Route.Fingerprint["apiKey"] == kept.Route.Fingerprint["apiKey"] || replaced.Route.Name != "Acme" {
		t.Fatalf("%+v", replaced.Route)
	}
	p.waitFor(func() bool { r := told.route(box.member.Host, "acme"); return r != nil && r.Version == 2 }, "the machine told version 2")
	if got := opened(t, box, told.route(box.member.Host, "acme"), "apiKey"); got != newKey {
		t.Fatalf("opened %q", got)
	}
	// The old rev is spent.
	if e := callError(t, window, "", "orgRoutes/replaceKey", wire.OrgRouteReplaceKey{ID: "acme", Secrets: map[string]string{"apiKey": oldKey}, Rev: kept.Rev}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}

	// The audit says what changed, and holds no value.
	p.waitFor(func() bool {
		var list wire.AuditList
		json.Unmarshal(call(t, window, "", "audit/list", wire.AuditQuery{}), &list)
		added, replacedKey := false, false
		for _, e := range list.Entries {
			if strings.Contains(deref(e.Target), "sk-ant") {
				t.Fatalf("the audit holds a value: %+v", e)
			}
			added = added || e.Method == "orgRoutes/set" && deref(e.Target) == "acme: added Acme"
			replacedKey = replacedKey || e.Method == "orgRoutes/replaceKey" && deref(e.Target) == "acme: key replaced" &&
				e.Action == "Replaced an org route's key"
		}
		return added && replacedKey
	}, "the add and the replaced key in the audit")

	// Sam's machine is removed: Alex, an admin, and Sam hear which routes it held.
	if _, err := spare.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesApplied.Name,
		wire.OrgRoutesApplied{Routes: []wire.OrgRouteVersion{{ID: "acme", Version: 2}}}); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool {
		h := p.s.records.Host(spare.member.Host)
		return h != nil && len(appliedOrgRoutes(*h)) == 1
	}, "the machine's routes noted")
	call(t, sam.window, "", "machines/remove", map[string]string{"host": spare.member.Host})
	for _, s := range []*controllink.Session{window, sam.window} {
		var left wire.OrgRoutesLeft
		json.Unmarshal(waitNote(t, s, wire.NotifyControlOrgRoutesLeft.Name).Params, &left)
		if string(left.Host) != spare.member.Host || !slices.Equal(left.Routes, []string{"Acme"}) || left.User != sam.id {
			t.Fatalf("%+v", left)
		}
	}

	// Sam leaves the group: their machine's list is empty.
	call(t, window, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Members: []string{}})
	p.waitFor(func() bool { d, _ := told.last(box.member.Host); return len(d.Routes) == 0 }, "the route gone from Sam's machine")
	call(t, window, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Members: []string{sam.id}})
	p.waitFor(func() bool { return told.route(box.member.Host, "acme") != nil }, "the route back on Sam's machine")

	// The route is removed: both records go, and the machine's list is empty.
	if e := callError(t, window, "", "orgRoutes/remove", wire.OrgRouteRequest{ID: "acme", Rev: &kept.Rev}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	call(t, window, "", "orgRoutes/remove", wire.OrgRouteRequest{ID: "acme", Rev: &replaced.Rev})
	p.waitFor(func() bool { d, _ := told.last(box.member.Host); return len(d.Routes) == 0 }, "the route removed from the machine")
	if objects, _ := p.store.List(t.Context(), orgRoutesPrefix); len(objects) != 0 {
		t.Fatalf("%+v", objects)
	}
	waitNote(t, sam.window, wire.NotifyControlOrgRoutesChanged.Name)
}

// fakeClouds is AWS STS, Google's OAuth and Entra, each counting the tokens it made.
type fakeClouds struct {
	server              *httptest.Server
	sts, google, entra  atomic.Int32
	refuseSTS           atomic.Bool
	stsAuth, stsActions []string
	mu                  sync.Mutex
}

func newFakeClouds(t *testing.T) *fakeClouds {
	f := &fakeClouds{}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		switch {
		case strings.HasPrefix(r.URL.Path, "/sts/"):
			n := f.sts.Add(1)
			if f.refuseSTS.Load() {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			f.mu.Lock()
			f.stsAuth = append(f.stsAuth, r.Header.Get("Authorization"))
			f.stsActions = append(f.stsActions, r.PostForm.Get("Action")+" "+r.PostForm.Get("RoleArn")+" "+r.PostForm.Get("ExternalId"))
			f.mu.Unlock()
			w.Write([]byte(`<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIA-SESSION</AccessKeyId>` +
				`<SecretAccessKey>session-secret</SecretAccessKey><SessionToken>aws-session-` + itoa(int(n)) + `</SessionToken>` +
				`<Expiration>` + time.Now().Add(2*time.Hour).UTC().Format(time.RFC3339) + `</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>`))
		case r.URL.Path == "/google":
			if r.PostForm.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || strings.Count(r.PostForm.Get("assertion"), ".") != 2 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			n := f.google.Add(1)
			json.NewEncoder(w).Encode(map[string]any{"access_token": "ya29.google-" + itoa(int(n)), "expires_in": 3599})
		case strings.HasPrefix(r.URL.Path, "/entra/"):
			if r.PostForm.Get("client_secret") != "entra-app-secret" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			n := f.entra.Add(1)
			json.NewEncoder(w).Encode(map[string]any{"access_token": "entra-" + itoa(int(n)), "expires_in": 86400})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}

// fakeServiceAccount is a service account's JSON key with a fresh RSA key.
func fakeServiceAccount(t *testing.T) string {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	raw, _ := json.Marshal(map[string]string{"type": "service_account", "client_email": "agents@acme.iam.gserviceaccount.com",
		"private_key_id": "kid1", "private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	return string(raw)
}

// FR-007, US7 (Q1 A): a cloud credential stays here; a machine gets only a token that ends
// within an hour, and a new one about 10 minutes before it ends.
func TestCloudCredentialsGoAsShortLivedTokens(t *testing.T) {
	t.Parallel()
	clouds := newFakeClouds(t)
	var clock atomic.Int64
	clock.Store(time.Now().UnixNano())
	endpoints := &orgEndpoints{
		STS:         func(region string) string { return clouds.server.URL + "/sts/" + region },
		GoogleToken: clouds.server.URL + "/google",
		Entra:       func(tenant string) string { return clouds.server.URL + "/entra/" + tenant },
		Client:      clouds.server.Client(),
		Now:         func() time.Time { return time.Unix(0, clock.Load()) },
	}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.orgEndpoints = endpoints
	})
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	box := p.machineSaying(alex, routesHello("MACHINE-2"))

	const awsSecret, entraSecret = "aws-long-lived-secret-key", "entra-app-secret"
	account := fakeServiceAccount(t)
	setRoute(t, window, wire.OrgRoute{ID: "bedrock", Name: "Acme Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"},
		Settings: &wire.OrgRouteSettings{Region: optional("us-east-1")}, Models: map[string]string{"claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-v1:0"}},
		map[string]string{"awsAccessKeyId": "AKIAEXAMPLE", "awsSecretAccessKey": awsSecret, "awsRoleArn": "arn:aws:iam::1:role/agents", "externalId": "ext-1"}, nil)
	setRoute(t, window, wire.OrgRoute{ID: "vertex", Name: "Acme Vertex", Kind: wire.OrgRouteKindVertex, Runtimes: []string{"claude", "gemini"},
		Settings: &wire.OrgRouteSettings{Project: optional("acme-ai"), Location: optional("us-east5")}}, map[string]string{"serviceAccount": account}, nil)
	setRoute(t, window, wire.OrgRoute{ID: "azure", Name: "Acme Azure", Kind: wire.OrgRouteKindAzure, Vendor: vendor(wire.OrgRouteVendorOpenai),
		Runtimes: []string{"codex"}, Settings: &wire.OrgRouteSettings{Resource: optional("acme-openai"), Tenant: optional("acme.onmicrosoft.com"),
			ClientID: optional("00000000-0000-0000-0000-000000000001")}}, map[string]string{"entraClientSecret": entraSecret}, nil)

	p.waitFor(func() bool { d, _ := told.last(box.member.Host); return len(d.Routes) == 3 }, "the machine told three routes")
	now := endpoints.Now()
	tokens := map[string]string{"bedrock": "awsSession", "vertex": "googleToken", "azure": "entraToken"}
	for id, field := range tokens {
		r := told.route(box.member.Host, id)
		if !slices.Equal(r.SecretFields, []string{field}) || len(r.Sealed) != 1 {
			t.Fatalf("%s: %+v", id, r.SecretFields)
		}
		if r.Expires == nil || r.Expires.Time().After(now.Add(time.Hour+time.Second)) || r.Expires.Time().Before(now.Add(50*time.Minute)) {
			t.Fatalf("%s ends at %v", id, r.Expires)
		}
		value := opened(t, box, r, field)
		for _, long := range []string{awsSecret, entraSecret, "PRIVATE KEY", "AKIAEXAMPLE"} {
			if strings.Contains(value, long) {
				t.Fatalf("%s sent a long-lived credential", id)
			}
		}
	}
	var session map[string]string
	json.Unmarshal([]byte(opened(t, box, told.route(box.member.Host, "bedrock"), "awsSession")), &session)
	if session["sessionToken"] != "aws-session-1" || session["accessKeyId"] != "ASIA-SESSION" {
		t.Fatalf("%+v", session)
	}
	if got := opened(t, box, told.route(box.member.Host, "vertex"), "googleToken"); got != "ya29.google-1" {
		t.Fatal(got)
	}
	if got := opened(t, box, told.route(box.member.Host, "azure"), "entraToken"); got != "entra-1" {
		t.Fatal(got)
	}
	clouds.mu.Lock()
	auth, actions := slices.Clone(clouds.stsAuth), slices.Clone(clouds.stsActions)
	clouds.mu.Unlock()
	if !strings.HasPrefix(auth[0], "AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/") || !strings.Contains(auth[0], "/us-east-1/sts/aws4_request") ||
		strings.Contains(auth[0], awsSecret) || actions[0] != "AssumeRole arn:aws:iam::1:role/agents ext-1" {
		t.Fatalf("%v %v", auth, actions)
	}
	// One token per route, however many machines join.
	other := p.machineSaying(alex, routesHello("MACHINE-3"))
	p.waitFor(func() bool { d, _ := told.last(other.member.Host); return len(d.Routes) == 3 }, "a second machine told three routes")
	if clouds.sts.Load() != 1 || clouds.google.Load() != 1 || clouds.entra.Load() != 1 {
		t.Fatalf("%d %d %d", clouds.sts.Load(), clouds.google.Load(), clouds.entra.Load())
	}

	// 52 minutes on, every token is within 10 minutes of its end: each machine gets new ones.
	clock.Add(int64(52 * time.Minute))
	if !p.s.tokensEndingSoon() {
		t.Fatal("no token is ending")
	}
	p.s.resendOrgRoutes()
	p.waitFor(func() bool {
		return opened(t, box, told.route(box.member.Host, "vertex"), "googleToken") == "ya29.google-2"
	},
		"the machine told a new token")
	p.waitFor(func() bool { return opened(t, box, told.route(box.member.Host, "azure"), "entraToken") == "entra-2" }, "a new Entra token")
	if p.s.tokensEndingSoon() {
		t.Fatal("a new token ends soon")
	}

	// The store holds none of the credentials, nor a token.
	for _, value := range []string{awsSecret, entraSecret, "ya29.google", "aws-session-", "PRIVATE KEY"} {
		if storeHolds(t, p.store, value) {
			t.Fatalf("the store holds %q", value)
		}
	}

	// orgRoutes/check makes a token; a refused credential says so, with no value.
	var check wire.OrgRouteCheck
	json.Unmarshal(call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "vertex"}), &check)
	if !check.Ok || !strings.Contains(check.Words, "A token was made") {
		t.Fatalf("%+v", check)
	}
}

// A cloud credential that is refused is tried again once per backoff step for every
// machine, not once a minute for each one; and a machine keeps the last token until it
// ends (#2250).
func TestARefusedCredentialBacksOff(t *testing.T) {
	t.Parallel()
	clouds := newFakeClouds(t)
	var clock atomic.Int64
	clock.Store(time.Now().UnixNano())
	endpoints := &orgEndpoints{
		STS:    func(region string) string { return clouds.server.URL + "/sts/" + region },
		Client: clouds.server.Client(),
		Now:    func() time.Time { return time.Unix(0, clock.Load()) },
	}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.orgEndpoints = endpoints
	})
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	const machines = 10
	boxes := []*fakeHost{}
	for i := range machines {
		boxes = append(boxes, p.machineSaying(alex, routesHello("MACHINE-"+itoa(i+2))))
	}
	setRoute(t, window, wire.OrgRoute{ID: "bedrock", Name: "Acme Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"},
		Settings: &wire.OrgRouteSettings{Region: optional("us-east-1")}},
		map[string]string{"awsAccessKeyId": "AKIAEXAMPLE", "awsSecretAccessKey": "aws-long-lived-secret-key"}, nil)
	holds := func(box *fakeHost) bool { return told.route(box.member.Host, "bedrock") != nil }
	for _, box := range boxes {
		p.waitFor(func() bool { return holds(box) }, "each machine told the route")
	}
	if clouds.sts.Load() != 1 {
		t.Fatal(clouds.sts.Load())
	}
	// tick is renewTokensEvery's tick, each machine's delivery made before it returns.
	tick := func(by time.Duration) {
		clock.Add(int64(by))
		if p.s.tokensEndingSoon() {
			for _, box := range boxes {
				p.s.sendOrgRoutes(box.member.Host, false)
			}
		}
	}

	// The key is revoked. 52 minutes on, one renewal is tried for all ten machines, and
	// each keeps the token it holds, which has 8 minutes left.
	clouds.refuseSTS.Store(true)
	tick(52 * time.Minute)
	if clouds.sts.Load() != 2 {
		t.Fatal(clouds.sts.Load())
	}
	for _, box := range boxes {
		if !holds(box) {
			t.Fatal("a machine lost a token that has not ended")
		}
	}
	// Ticks a minute apart: tries at 1, 2, 4 and 8 minutes, not ten for each tick.
	for range 20 {
		tick(time.Minute)
	}
	if got := clouds.sts.Load(); got != 2+4 {
		t.Fatalf("%d calls to STS in 20 minutes", got)
	}
	// The token has ended: the route leaves the machines.
	for _, box := range boxes {
		p.waitFor(func() bool { return !holds(box) }, "the ended token taken from each machine")
	}

	// The key works again: the next try sends a new token to every machine.
	clouds.refuseSTS.Store(false)
	for range 16 {
		tick(time.Minute)
	}
	if got := clouds.sts.Load(); got != 2+4+1 {
		t.Fatalf("%d calls to STS", got)
	}
	for _, box := range boxes {
		p.waitFor(func() bool { return holds(box) }, "a new token sent to each machine")
	}
}

// orgRoutes/check sends one small request with a key, to the vendor or a gateway.
func TestCheckARoute(t *testing.T) {
	t.Parallel()
	const key = "sk-ant-checked-key"
	vendorAPI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" || r.Header.Get("x-api-key") != key || r.Header.Get("anthropic-version") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Write([]byte(`{"data":[]}`))
	}))
	t.Cleanup(vendorAPI.Close)
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.orgEndpoints = &orgEndpoints{Vendor: map[wire.OrgRouteVendor]string{wire.OrgRouteVendorAnthropic: vendorAPI.URL},
			Client: vendorAPI.Client(), Now: time.Now}
	})
	_, window := p.client("Alex's Mac")
	kept := setRoute(t, window, wire.OrgRoute{Name: "Acme", Kind: wire.OrgRouteKindKey, Vendor: vendor(wire.OrgRouteVendorAnthropic),
		Runtimes: []string{"claude"}}, map[string]string{"apiKey": key}, nil)
	var check wire.OrgRouteCheck
	json.Unmarshal(call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "acme"}), &check)
	if !check.Ok {
		t.Fatalf("%+v", check)
	}
	json.Unmarshal(call(t, window, "", "orgRoutes/replaceKey", wire.OrgRouteReplaceKey{ID: "acme", Secrets: map[string]string{"apiKey": "sk-ant-wrong"}, Rev: kept.Rev}), &kept)
	check = wire.OrgRouteCheck{}
	raw := call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "acme"})
	json.Unmarshal(raw, &check)
	if check.Ok || !strings.Contains(check.Words, "refused the key (401)") || bytes.Contains(raw, []byte("sk-ant")) {
		t.Fatalf("%s", raw)
	}
	// A Bedrock API key is checked from a machine.
	setRoute(t, window, wire.OrgRoute{ID: "bedrock", Name: "Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"},
		Settings: &wire.OrgRouteSettings{Region: optional("eu-west-1")}}, map[string]string{"apiKey": "bedrock-api-key"}, nil)
	json.Unmarshal(call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "bedrock"}), &check)
	if check.Ok || !strings.Contains(check.Words, "only from a machine") {
		t.Fatalf("%+v", check)
	}
}

// FR-008: the policy's reach and Antigravity's terms are bounded, and need host.org-routes/1.
func TestThePolicyReachAndAntigravityTerms(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Alex's Mac")
	for _, bad := range []wire.OrgPolicy{
		{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {Reach: []wire.PolicyReach{}}}},
		{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {Reach: []wire.PolicyReach{"apiKey"}}}},
		{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {Reach: []wire.PolicyReach{wire.PolicyReachOrgKey, wire.PolicyReachOrgKey}}}},
		{Notices: &wire.PolicyNotices{AntigravityTerms: optional("maybe")}},
	} {
		if e := callError(t, window, "", "policy/set", wire.PolicySet{Policy: bad}); !strings.Contains(e, "-32602") {
			t.Errorf("%+v: %s", bad, e)
		}
	}
	kept := setPolicy(t, window, wire.OrgPolicy{Runtimes: map[string]wire.PolicyRuntimeRule{"codex": {}}}, nil)
	if !slices.Equal(kept.Policy.Requires, []string{CapHostPolicy}) {
		t.Fatalf("%+v", kept.Policy.Requires)
	}
	orgOnly := []wire.PolicyReach{wire.PolicyReachOrgKey, wire.PolicyReachGateway}
	kept = setPolicy(t, window, wire.OrgPolicy{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {Reach: orgOnly}}}, kept.Rev)
	if !slices.Equal(kept.Policy.Requires, []string{CapHostPolicy, CapHostOrgRoutes}) || !slices.Equal(kept.Policy.Runtimes["claude"].Reach, orgOnly) {
		t.Fatalf("%+v", kept.Policy)
	}
	kept = setPolicy(t, window, wire.OrgPolicy{Notices: &wire.PolicyNotices{AntigravityTerms: optional("accepted")}}, kept.Rev)
	if !slices.Equal(kept.Policy.Requires, []string{CapHostPolicy, CapHostOrgRoutes}) || deref(kept.Policy.Notices.AntigravityTerms) != "accepted" {
		t.Fatalf("%+v", kept.Policy)
	}
	_ = context.Background
}

// A token whose route no machine here uses any more is dropped once it ends, and brings no
// resend each minute after (#2431); a machine that asks again gets a new one.
func TestAnEndedTokenNobodyUsesStopsTheResends(t *testing.T) {
	t.Parallel()
	clouds := newFakeClouds(t)
	var clock atomic.Int64
	clock.Store(time.Now().UnixNano())
	endpoints := &orgEndpoints{
		GoogleToken: clouds.server.URL + "/google",
		Client:      clouds.server.Client(),
		Now:         func() time.Time { return time.Unix(0, clock.Load()) },
	}
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.orgEndpoints = endpoints
	})
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	box := p.machineSaying(alex, routesHello("MACHINE-2"))
	setRoute(t, window, wire.OrgRoute{ID: "vertex", Name: "Acme Vertex", Kind: wire.OrgRouteKindVertex, Runtimes: []string{"claude"},
		Settings: &wire.OrgRouteSettings{Project: optional("acme-ai"), Location: optional("us-east5")}},
		map[string]string{"serviceAccount": fakeServiceAccount(t)}, nil)
	p.waitFor(func() bool { return told.route(box.member.Host, "vertex") != nil }, "the machine told the route")
	p.waitFor(func() bool {
		p.s.orgRoutes.mu.Lock()
		defer p.s.orgRoutes.mu.Unlock()
		return !p.s.orgRoutes.resent.IsZero() && !p.s.orgRoutes.resending
	}, "the resend done")

	// The machine stops using the route (none of the machines here asks for it), and the
	// token ends: ten ticks of renewTokensEvery bring one resend, not ten.
	clock.Add(int64(2 * time.Hour))
	resends := 0
	for range 10 {
		clock.Add(int64(time.Minute))
		if p.s.tokensEndingSoon() {
			resends++
			p.s.resendTo(nil)
		}
	}
	t.Logf("10 ticks after the token ended: %d resends", resends)
	if resends > 1 {
		t.Fatalf("%d resends for a token nobody uses", resends)
	}
	p.s.orgRoutes.mu.Lock()
	left := len(p.s.orgRoutes.tokens)
	p.s.orgRoutes.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d tokens kept", left)
	}
	// A machine that uses it again is sent a new token.
	made := clouds.google.Load()
	p.s.resendTo([]string{box.member.Host})
	if clouds.google.Load() != made+1 {
		t.Fatal("no new token made")
	}
}
