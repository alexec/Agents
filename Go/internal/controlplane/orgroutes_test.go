package controlplane

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"maps"
	"slices"
	"strings"
	"sync"
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

// sealed is a delivered route that came with its secrets, not waiting.
func (d *routesTold) sealed(host, id string) *wire.DeliveredRoute {
	r := d.route(host, id)
	if r == nil || r.Waiting != nil && *r.Waiting {
		return nil
	}
	return r
}

// opened is what a delivered route's field opens to with the machine's own key.
func opened(t *testing.T, box *fakeHost, r *wire.DeliveredRoute, field string) string {
	t.Helper()
	plain, err := openRoute(box.private, *r, box.member.Host, field)
	if err != nil {
		t.Fatalf("%s's %s does not open: %v", r.ID, field, err)
	}
	return string(plain)
}

func openRoute(private []byte, r wire.DeliveredRoute, host, field string) ([]byte, error) {
	return controllink.Open(private, controllink.OrgRoutePurpose, controllink.DeliveredRouteAD(r, controllink.MachineRecipient(host), field),
		r.Sealed[field])
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

// valueFingerprint is the first 8 hex of a value's SHA-256, as a client works it out.
func valueFingerprint(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:8]
}

// sealRoute is what an admin's client does (#3397): ask who the route is sealed to, and
// seal each value to each of them, at sealVersion.
func sealRoute(t *testing.T, s *controllink.Session, route wire.OrgRoute, values map[string]string, sealVersion int64) *wire.OrgRouteSealed {
	t.Helper()
	var recipients wire.SealRecipients
	json.Unmarshal(call(t, s, "", "orgRoutes/recipients", wire.OrgRouteRecipientsRequest{Groups: route.Groups}), &recipients)
	return sealTo(t, recipients.Recipients, route, values, sealVersion)
}

func sealTo(t *testing.T, recipients []wire.SealRecipient, route wire.OrgRoute, values map[string]string, sealVersion int64) *wire.OrgRouteSealed {
	t.Helper()
	id := route.ID
	if id == "" {
		id = routeIDFrom(route.Name)
	}
	out := &wire.OrgRouteSealed{SealVersion: sealVersion, Fingerprint: map[string]string{}, Values: map[string]map[string]wire.SealedEnvelope{}}
	for field, value := range values {
		out.Fingerprint[field] = valueFingerprint(value)
	}
	for _, r := range recipients {
		out.Values[r.ID] = map[string]wire.SealedEnvelope{}
		for field, value := range values {
			ad := controllink.OrgRouteAD(id, r.ID, field, sealVersion, route.Kind, route.Vendor, route.Settings)
			e, err := controllink.Seal(r.PublicKey, controllink.OrgRoutePurpose, ad, []byte(value))
			if err != nil {
				t.Fatal(err)
			}
			out.Values[r.ID][field] = e
		}
	}
	return out
}

// setRoute adds or changes a route as an admin's client does: with its values sealed, one
// seal version on from was, when there are values.
func setRoute(t *testing.T, s *controllink.Session, route wire.OrgRoute, values map[string]string, rev *string, was int64) wire.OrgRouteKept {
	t.Helper()
	request := wire.OrgRouteSet{Route: route, Rev: rev}
	if len(values) > 0 {
		request.Sealed = sealRoute(t, s, route, values, was+1)
	}
	var kept wire.OrgRouteKept
	json.Unmarshal(call(t, s, "", "orgRoutes/set", request), &kept)
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
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
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
	if list := listRoutes(t, window); len(list.Routes) != 0 {
		t.Fatalf("%+v", list)
	}
	call(t, window, box.member.Host, "daemon/ping", nil)
	if objects, _ := p.store.List(t.Context(), "v1/org"); len(objects) != 0 {
		t.Fatalf("a route was written: %+v", objects)
	}
}

// FR-001 to FR-004, US2, #3397: an admin's save is bounded by the spec's table,
// conditional on its rev and one version higher; it carries envelopes only, and no method
// gives a value back; the store holds none; a member sees only names. A control plane with
// no keeper keeps a key: it never needed to open one.
func TestAnAdminKeepsARouteAndNoValueComesBack(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
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
		{wire.OrgRoute{Name: "Two lines", Kind: wire.OrgRouteKindBaseURL, Vendor: anthropic, Runtimes: []string{"claude"},
			Settings: &wire.OrgRouteSettings{Address: optional("https://gateway.example.com"), ApiVersion: optional("v1\nregion=elsewhere")}}, nil},
		{wire.OrgRoute{Name: "No group", Kind: wire.OrgRouteKindKey, Vendor: anthropic, Runtimes: []string{"claude"}, Groups: []string{"nobody"}}, nil},
	} {
		request := wire.OrgRouteSet{Route: bad.route}
		if len(bad.secrets) > 0 {
			request.Sealed = sealRoute(t, window, wire.OrgRoute{Name: bad.route.Name, Kind: bad.route.Kind, Vendor: bad.route.Vendor,
				Settings: bad.route.Settings}, bad.secrets, 1)
		}
		if e := callError(t, window, "", "orgRoutes/set", request); !strings.Contains(e, "-32602") {
			t.Errorf("%+v: %s", bad.route.Name, e)
		}
	}
	// Sealed one version on from none, or for no recipient, is refused.
	if e := callError(t, window, "", "orgRoutes/set", wire.OrgRouteSet{Route: good, Sealed: sealRoute(t, window, good, map[string]string{"apiKey": key}, 2)}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	if e := callError(t, window, "", "orgRoutes/set", wire.OrgRouteSet{Route: good, Sealed: sealTo(t, nil, good, map[string]string{"apiKey": key}, 1)}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	// A member changes nothing, and reads only the routes they may use, by name.
	for _, method := range []string{"orgRoutes/list", "orgRoutes/set", "orgRoutes/replaceKey", "orgRoutes/check", "orgRoutes/remove",
		"orgRoutes/recipients", "orgRoutes/sealed"} {
		if e := callError(t, sam.window, "", method, map[string]any{"route": good, "id": "x", "rev": "x"}); !strings.Contains(e, "-32045") {
			t.Errorf("%s: %s", method, e)
		}
	}

	first := setRoute(t, window, good, map[string]string{"apiKey": key}, nil, 0)
	r := first.Route
	if r.ID != "acme-anthropic" || deref(r.Version) != 1 || deref(r.SealVersion) != 1 || first.Rev == "" ||
		!slices.Equal(r.SecretFields, []string{"apiKey"}) || r.Fingerprint["apiKey"] != valueFingerprint(key) || r.Created == nil ||
		r.Created.By.User != p.s.localOwner() {
		t.Fatalf("%+v", first)
	}
	// The same id again, with no rev, is told to load it.
	if e := callError(t, priya.window, "", "orgRoutes/set", wire.OrgRouteSet{Route: good, Sealed: sealRoute(t, priya.window, good, map[string]string{"apiKey": key}, 1)}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	// Two admins read the same rev; the second to save is told to load it again. A rename
	// keeps the key, sealed as it was.
	renamed := r
	renamed.Name = "Acme"
	second := setRoute(t, window, renamed, nil, &first.Rev, 0)
	if deref(second.Route.Version) != 2 || deref(second.Route.SealVersion) != 1 || second.Route.Fingerprint["apiKey"] != r.Fingerprint["apiKey"] {
		t.Fatalf("%+v", second.Route)
	}
	if e := callError(t, priya.window, "", "orgRoutes/set", wire.OrgRouteSet{Route: renamed, Rev: &first.Rev}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	// A change to where the key goes is not taken without the key sealed again.
	moved := second.Route
	moved.Kind, moved.Settings = wire.OrgRouteKindBaseURL, &wire.OrgRouteSettings{Address: optional("https://elsewhere.example")}
	if e := callError(t, window, "", "orgRoutes/set", wire.OrgRouteSet{Route: moved, Rev: &second.Rev}); !strings.Contains(e, "seals the key again") {
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
	// The store holds envelopes, never the value.
	if storeHolds(t, p.store, key) {
		t.Fatal("the store holds the key")
	}
	if object, _ := p.store.Get(t.Context(), orgSecretKey("acme-anthropic")); object == nil {
		t.Fatal("no envelopes")
	}
	// Each admin's client has a copy that it alone opens, and orgRoutes/sealed gives it.
	var item wire.SealingItem
	json.Unmarshal(call(t, priya.window, "", "orgRoutes/sealed", wire.OrgRouteRequest{ID: "acme-anthropic"}), &item)
	ad := controllink.OrgRouteAD("acme-anthropic", controllink.ClientRecipient(priya.member.Client), "apiKey", 1, wire.OrgRouteKindKey, anthropic, nil)
	if plain, err := controllink.Open(priya.member.Private, controllink.OrgRoutePurpose, ad, item.Mine["apiKey"]); err != nil || string(plain) != key {
		t.Fatalf("%q %v", plain, err)
	}
}

// FR-005, SC-002, #3397: two copies, three machines of two people across them, and a route
// for a group: only the group's machines get it, within 5 seconds, each copy opens with
// that machine's key only, and not as another route, machine, field, version or address.
// A machine that joins later waits, and an admin's client seals it for that machine.
func TestARouteReachesOnlyTheMachinesAllowed(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	st, private := store.NewMemory(), controllink.NewPrivateKey()
	a, b := startCopy(t, st, private), startCopy(t, st, private)
	a.waitFor(func() bool { return len(a.s.mesh.peers()) == 1 && len(b.s.mesh.peers()) == 1 }, "the copies linked")
	told := newRoutesTold()
	a.told, b.told = told.heard, told.heard
	member, window := a.client("Admin's Mac")
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

	// The admin's client is told whom to seal to: Sam's two machines and its own self.
	var recipients wire.SealRecipients
	json.Unmarshal(call(t, window, "", "orgRoutes/recipients", wire.OrgRouteRecipientsRequest{Groups: []string{platform.ID}}), &recipients)
	var ids []string
	for _, r := range recipients.Recipients {
		ids = append(ids, r.ID)
	}
	want := []string{controllink.ClientRecipient(member.Client), controllink.MachineRecipient(samAtA.member.Host), controllink.MachineRecipient(samAtB.member.Host)}
	slices.Sort(want)
	if !slices.Equal(ids, want) {
		t.Fatalf("%v, not %v", ids, want)
	}

	const key = "sk-proj-org-key-for-platform"
	saved := time.Now()
	route := wire.OrgRoute{ID: "platform-openai", Name: "Platform OpenAI", Kind: wire.OrgRouteKindKey,
		Vendor: vendor(wire.OrgRouteVendorOpenai), Runtimes: []string{"codex"}, Groups: []string{platform.ID}}
	setRoute(t, window, route, map[string]string{"apiKey": key}, nil, 0)
	for _, m := range []*fakeHost{samAtA, samAtB} {
		a.waitFor(func() bool { return told.sealed(m.member.Host, "platform-openai") != nil }, "Sam's machines told the route")
	}
	if took := time.Since(saved); took > 5*time.Second {
		t.Fatalf("took %v", took)
	}
	time.Sleep(300 * time.Millisecond)
	if r := told.route(alexBox.member.Host, "platform-openai"); r != nil {
		t.Fatal("a machine of a person outside the group was told the route")
	}
	r := told.route(samAtB.member.Host, "platform-openai")
	if r.Version != 1 || r.SealVersion != 1 || r.Name != "Platform OpenAI" || !slices.Equal(r.SecretFields, []string{"apiKey"}) || len(r.Sealed) != 1 {
		t.Fatalf("%+v", r)
	}
	if got := opened(t, samAtB, r, "apiKey"); got != key {
		t.Fatalf("opened %q", got)
	}
	if bytes.Contains(r.Sealed["apiKey"].Ciphertext, []byte(key)) {
		t.Fatal("the key is in the clear")
	}
	// Another machine's key, another machine's id, another route's id, field or seal does
	// not open it; nor does the route with its address, header or kind changed.
	if _, err := openRoute(samAtA.private, *r, samAtB.member.Host, "apiKey"); err == nil {
		t.Fatal("another machine's key opens it")
	}
	if _, err := openRoute(samAtB.private, *r, samAtA.member.Host, "apiKey"); err == nil {
		t.Fatal("it opens as another machine's")
	}
	for what, edit := range map[string]func(r *wire.DeliveredRoute){
		"another route": func(r *wire.DeliveredRoute) { r.ID = "another" },
		"another seal":  func(r *wire.DeliveredRoute) { r.SealVersion++ },
		"another field": func(r *wire.DeliveredRoute) {
			r.Sealed = map[string]wire.SealedEnvelope{"azureKey": r.Sealed["apiKey"]}
		},
		"another address": func(r *wire.DeliveredRoute) {
			r.Settings = &wire.OrgRouteSettings{Address: new("https://elsewhere.example")}
		},
		"another header": func(r *wire.DeliveredRoute) { r.Settings = &wire.OrgRouteSettings{Header: new("X-Elsewhere")} },
		"another kind":   func(r *wire.DeliveredRoute) { r.Kind = wire.OrgRouteKindBaseURL },
		"another vendor": func(r *wire.DeliveredRoute) { r.Vendor = vendor(wire.OrgRouteVendorXai) },
	} {
		changed := *r
		changed.Sealed = maps.Clone(r.Sealed)
		edit(&changed)
		field := "apiKey"
		if what == "another field" {
			field = "azureKey"
		}
		if _, err := openRoute(samAtB.private, changed, samAtB.member.Host, field); err == nil {
			t.Fatalf("it opens as %s", what)
		}
	}

	// Each machine says it keeps it; the list counts them, and none waits.
	for _, m := range []*fakeHost{samAtA, samAtB} {
		if _, err := m.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesApplied.Name,
			wire.OrgRoutesApplied{Routes: []wire.OrgRouteVersion{{ID: "platform-openai", Version: 1}}}); err != nil {
			t.Fatal(err)
		}
	}
	a.waitFor(func() bool {
		list := listRoutes(t, window)
		return len(list.Routes) == 1 && deref(list.Routes[0].Route.Machines) == 2 && deref(list.Routes[0].Route.Waiting) == 0
	}, "two machines hold the route")

	// A machine that joins later waits: no copy is sealed to it. The list says so, and so
	// does Sam's orgRoutes/mine. The admin's clients are asked to seal it.
	later := b.machineSaying(sam, routesHello("MACHINE-5"))
	a.waitFor(func() bool { return told.route(later.member.Host, "platform-openai") != nil }, "a later machine told the route")
	waiting := told.route(later.member.Host, "platform-openai")
	if waiting.Waiting == nil || !*waiting.Waiting || len(waiting.Sealed) != 0 {
		t.Fatalf("%+v", waiting)
	}
	if list := listRoutes(t, window); deref(list.Routes[0].Route.Waiting) != 1 {
		t.Fatalf("%+v", list.Routes[0].Route)
	}
	var mine wire.OrgRoutesMine
	json.Unmarshal(call(t, sam.window, "", "orgRoutes/mine", nil), &mine)
	if len(mine.Routes) != 1 || !deref(mine.Routes[0].Waiting) {
		t.Fatalf("%+v", mine)
	}
	waitNote(t, window, wire.NotifyControlSealingWanted.Name)
	sealForMissing(t, window, member)
	a.waitFor(func() bool { return told.sealed(later.member.Host, "platform-openai") != nil }, "the later machine told its copy")
	if got := opened(t, later, told.route(later.member.Host, "platform-openai"), "apiKey"); got != key {
		t.Fatalf("opened %q", got)
	}
	if list := listRoutes(t, window); deref(list.Routes[0].Route.Waiting) != 0 {
		t.Fatalf("%+v", list.Routes[0].Route)
	}
	// One that asks again gets it again.
	n := told.count(later.member.Host)
	if _, err := later.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesAgain.Name, wire.Empty{}); err != nil {
		t.Fatal(err)
	}
	a.waitFor(func() bool { return told.count(later.member.Host) > n }, "the machine told again")
}

// sealForMissing is what a client does on control/sealingWanted: sealing/work, open its
// own copy of each item, seal it to each recipient missing, sealing/add.
func sealForMissing(t *testing.T, s *controllink.Session, member *controllink.ClientMembership) int {
	t.Helper()
	var work wire.SealingWork
	json.Unmarshal(call(t, s, "", "sealing/work", nil), &work)
	me := controllink.ClientRecipient(member.Client)
	add := wire.SealingAdd{Items: []wire.SealingAddItem{}}
	for _, item := range work.Items {
		next := wire.SealingAddItem{Item: item.Item, ID: item.ID, Version: item.Version, Values: map[string]map[string]wire.SealedEnvelope{}}
		for field, e := range item.Mine {
			info, ad := controllink.OrgRoutePurpose, controllink.OrgRouteAD(item.ID, me, field, item.Version, deref(item.Kind), item.Vendor, item.Settings)
			if item.Item == wire.SealingItemKindUserSecret {
				info, ad = controllink.UserSecretPurpose, controllink.UserSecretAD(deref(item.User), me, item.ID, item.Version)
			}
			plain, err := controllink.Open(member.Private, info, ad, e)
			if err != nil {
				t.Fatalf("%s's own copy does not open: %v", item.ID, err)
			}
			for _, r := range item.Missing {
				ad := controllink.OrgRouteAD(item.ID, r.ID, field, item.Version, deref(item.Kind), item.Vendor, item.Settings)
				if item.Item == wire.SealingItemKindUserSecret {
					ad = controllink.UserSecretAD(deref(item.User), r.ID, item.ID, item.Version)
				}
				sealed, err := controllink.Seal(r.PublicKey, info, ad, plain)
				if err != nil {
					t.Fatal(err)
				}
				if next.Values[r.ID] == nil {
					next.Values[r.ID] = map[string]wire.SealedEnvelope{}
				}
				next.Values[r.ID][field] = sealed
			}
		}
		add.Items = append(add.Items, next)
	}
	call(t, s, "", "sealing/add", add)
	return len(work.Items)
}

// FR-004, US4: a replaced key reaches the machines as a new seal; a person taken out of
// the group and a removed route give an empty list; the audit says "key replaced" and holds
// no value; a removed machine's person and the admins hear which routes it held.
func TestReplaceAndRemoveARoute(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	box := p.machineSaying(sam, routesHello("MACHINE-2"))
	spare := p.machineSaying(sam, routesHello("MACHINE-3"))
	var platform wire.Group
	json.Unmarshal(call(t, window, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id}}), &platform)

	const oldKey, newKey = "sk-ant-old-key-111111", "sk-ant-new-key-222222"
	route := wire.OrgRoute{Name: "Acme", Kind: wire.OrgRouteKindKey, Vendor: vendor(wire.OrgRouteVendorAnthropic),
		Runtimes: []string{"claude"}, Groups: []string{platform.ID}}
	kept := setRoute(t, window, route, map[string]string{"apiKey": oldKey}, nil, 0)
	p.waitFor(func() bool { return told.sealed(box.member.Host, "acme") != nil }, "the machine told the route")

	var replaced wire.OrgRouteKept
	json.Unmarshal(call(t, window, "", "orgRoutes/replaceKey", wire.OrgRouteReplaceKey{ID: "acme",
		Sealed: *sealRoute(t, window, kept.Route, map[string]string{"apiKey": newKey}, 2), Rev: kept.Rev}), &replaced)
	if deref(replaced.Route.Version) != 2 || deref(replaced.Route.SealVersion) != 2 || replaced.Route.Fingerprint["apiKey"] != valueFingerprint(newKey) ||
		replaced.Route.Name != "Acme" {
		t.Fatalf("%+v", replaced.Route)
	}
	p.waitFor(func() bool { r := told.sealed(box.member.Host, "acme"); return r != nil && r.SealVersion == 2 }, "the machine told seal 2")
	if got := opened(t, box, told.route(box.member.Host, "acme"), "apiKey"); got != newKey {
		t.Fatalf("opened %q", got)
	}
	// The old rev is spent.
	if e := callError(t, window, "", "orgRoutes/replaceKey", wire.OrgRouteReplaceKey{ID: "acme",
		Sealed: *sealRoute(t, window, kept.Route, map[string]string{"apiKey": oldKey}, 3), Rev: kept.Rev}); !strings.Contains(e, "-32093") {
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

	// Sam leaves the group: their machine's list is empty. Back in it, the copy sealed
	// before is still there.
	call(t, window, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Members: []string{}})
	p.waitFor(func() bool { d, _ := told.last(box.member.Host); return len(d.Routes) == 0 }, "the route gone from Sam's machine")
	call(t, window, "", "groups/set", wire.GroupSet{ID: &platform.ID, Name: "Platform", Members: []string{sam.id}})
	p.waitFor(func() bool { return told.sealed(box.member.Host, "acme") != nil }, "the route back on Sam's machine")

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

// #3397 (done when): the control plane never holds a route's value. This one has no keeper
// at all, so it could open nothing, and a store that holds only what it was given: the
// route still reaches the machine, which opens it, and the store holds no value.
func TestAControlPlaneWithNoKeyStillDeliversARoute(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	if p.s.users.Sealing() {
		t.Fatal("this control plane has a keeper")
	}
	told := newRoutesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	box := p.machineSaying(alex, routesHello("MACHINE-2"))
	// machine/hello is told, not asked, so it can land after the machine is online: a route
	// set before it is noted is sealed to no machine, and with no keeper stays so (#3636).
	p.waitFor(func() bool { _, ok := told.last(box.member.Host); return ok }, "the machine told at its join")
	const awsSecret = "aws-long-lived-secret-key"
	setRoute(t, window, wire.OrgRoute{ID: "bedrock", Name: "Acme Bedrock", Kind: wire.OrgRouteKindBedrock, Runtimes: []string{"claude"},
		Settings: &wire.OrgRouteSettings{Region: optional("us-east-1")}},
		map[string]string{"awsAccessKeyId": "AKIAEXAMPLE", "awsSecretAccessKey": awsSecret}, nil, 0)
	p.waitFor(func() bool { return told.sealed(box.member.Host, "bedrock") != nil }, "the machine told the route")
	r := told.route(box.member.Host, "bedrock")
	if !slices.Equal(r.SecretFields, []string{"awsAccessKeyId", "awsSecretAccessKey"}) {
		t.Fatalf("%+v", r.SecretFields)
	}
	if got := opened(t, box, r, "awsSecretAccessKey"); got != awsSecret {
		t.Fatalf("opened %q", got)
	}
	for _, value := range []string{awsSecret, "AKIAEXAMPLE"} {
		if storeHolds(t, p.store, value) {
			t.Fatalf("the store holds %q", value)
		}
	}
}

// #3397: orgRoutes/check asks a machine that holds the route's version, and gives its
// words; with none online, it says so.
func TestCheckARouteOnAMachine(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	var asked sync.Map
	p.asked = func(host, method string, params json.RawMessage) (any, bool) {
		if method != wire.CallMachineOrgRouteCheck.Name {
			return nil, false
		}
		asked.Store(host, string(params))
		return wire.OrgRouteCheck{Ok: true, Words: "The provider took the key."}, true
	}
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	setRoute(t, window, wire.OrgRoute{Name: "Acme", Kind: wire.OrgRouteKindKey, Vendor: vendor(wire.OrgRouteVendorAnthropic),
		Runtimes: []string{"claude"}}, map[string]string{"apiKey": "sk-ant-checked"}, nil, 0)
	var check wire.OrgRouteCheck
	json.Unmarshal(call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "acme"}), &check)
	if check.Ok || !strings.Contains(check.Words, "No machine that holds this route") {
		t.Fatalf("%+v", check)
	}
	box := p.machineSaying(alex, routesHello("MACHINE-2"))
	if _, err := box.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesApplied.Name,
		wire.OrgRoutesApplied{Routes: []wire.OrgRouteVersion{{ID: "acme", Version: 1}}}); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool { h := p.s.records.Host(box.member.Host); return h != nil && len(appliedOrgRoutes(*h)) == 1 }, "the route noted")
	json.Unmarshal(call(t, window, "", "orgRoutes/check", wire.OrgRouteRequest{ID: "acme"}), &check)
	if !check.Ok || !strings.Contains(check.Words, "The provider took the key, checked on box MACHINE-2.") {
		t.Fatalf("%+v", check)
	}
	if got, ok := asked.Load(box.member.Host); !ok || !strings.Contains(got.(string), `"acme"`) {
		t.Fatalf("%v", got)
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
