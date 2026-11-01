package controlplane

import (
	"context"
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// policyLine is host/policy as a machine reads it: the document's own bytes, to check.
type policyLine struct {
	Policy    json.RawMessage       `json:"policy"`
	Signature *wire.PolicySignature `json:"signature"`
	None      *bool                 `json:"none"`
}

// policiesTold is every host/policy each machine was told, by machine.
type policiesTold struct {
	mu  sync.Mutex
	got map[string][]policyLine
}

func newPoliciesTold() *policiesTold { return &policiesTold{got: map[string][]policyLine{}} }

func (d *policiesTold) heard(host, method string, params json.RawMessage) {
	if method != wire.NewMethodName(wire.NotifyHostPolicy.Name) {
		return
	}
	var line policyLine
	json.Unmarshal(params, &line)
	d.mu.Lock()
	d.got[host] = append(d.got[host], line)
	d.mu.Unlock()
}

func (d *policiesTold) last(host string) (policyLine, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	list := d.got[host]
	if len(list) == 0 {
		return policyLine{}, false
	}
	return list[len(list)-1], true
}

// version is the version host was told last, 0 for none.
func (d *policiesTold) version(host string) int64 {
	line, ok := d.last(host)
	if !ok || line.Policy == nil {
		return 0
	}
	var p wire.OrgPolicy
	json.Unmarshal(line.Policy, &p)
	return p.Version
}

// policyHello is a machine that keeps and follows the policy.
func policyHello(name string) controllink.MachineHello {
	hello := fakeHello(name)
	hello.Capabilities = append(slices.Clone(hello.Capabilities), CapHostPolicy)
	return hello
}

func setPolicy(t *testing.T, s *controllink.Session, policy wire.OrgPolicy, rev *string) wire.PolicyKept {
	t.Helper()
	var kept wire.PolicyKept
	json.Unmarshal(call(t, s, "", "policy/set", wire.PolicySet{Policy: policy, Rev: rev}), &kept)
	return kept
}

func getPolicy(t *testing.T, s *controllink.Session) wire.PolicyKept {
	t.Helper()
	var kept wire.PolicyKept
	json.Unmarshal(call(t, s, "", "policy/get", nil), &kept)
	return kept
}

// SC-001, US1: a control plane with no policy sends "no policy" and nothing else changes.
func TestNoPolicySendsNoneAndChangesNothing(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := newPoliciesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	box := p.hostSaying(policyHello("MACHINE-2"), nil)
	older := p.host("MACHINE-3")

	p.waitFor(func() bool { _, ok := told.last(box.member.Host); return ok }, "the machine told at its join")
	if line, _ := told.last(box.member.Host); line.None == nil || !*line.None || line.Policy != nil || line.Signature != nil {
		t.Fatalf("%+v", line)
	}
	if _, ok := told.last(older.member.Host); ok {
		t.Fatal("a machine that does not follow the policy was told one")
	}
	var view wire.PolicyView
	json.Unmarshal(call(t, window, "", "policy/mine", nil), &view)
	if view.Policy != nil {
		t.Fatalf("%+v", view)
	}
	if kept := getPolicy(t, window); kept.Policy != nil || kept.Rev != nil {
		t.Fatalf("%+v", kept)
	}
	// Every call that worked before still works, a start included.
	call(t, window, box.member.Host, "daemon/ping", nil)
	if e := callError(t, window, box.member.Host, "agents/start", map[string]any{}); strings.Contains(e, "-32076") {
		t.Fatal(e)
	}
	if objects, _ := p.store.List(t.Context(), "v1/policy"); len(objects) != 0 {
		t.Fatalf("a policy was written: %+v", objects)
	}
}

// FR-002 to FR-005, US2: an admin's save is bounded, one version higher, signed by the
// control key, conditional on the rev read, audited and kept as it was; a member is refused.
func TestAnAdminSavesASignedPolicy(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := newPoliciesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	priya := p.invite(window, "Priya", wire.UserRoleAdmin)
	box := p.machineSaying(sam, policyHello("MACHINE-2"))

	// Out of bounds, refused in words, and nothing kept.
	for _, bad := range []wire.OrgPolicy{
		{PermissionMode: optional(wire.PermissionLevel("yolo"))},
		{Sandbox: optional("sometimes")},
		{Budgets: &wire.PolicyBudgets{Daily: optional(2_000_000.0)}},
		{Budgets: &wire.PolicyBudgets{DailyTokens: optional(int64(-1))}},
		{Environment: &wire.PolicyEnvironment{PassThrough: []string{"NOT A NAME"}}},
		{Runtimes: map[string]wire.PolicyRuntimeRule{"claude": {Models: []string{"claude-*-x*"}}}},
		{Marketplaces: &wire.PolicyMarketplaces{Allowed: []string{"github"}, CustomServers: "maybe"}},
		{Helpers: &wire.PolicyHelpers{MostRunning: optional(int64(5000))}},
		{Runtimes: map[string]wire.PolicyRuntimeRule{strings.Repeat("r", 70_000): {}}},
	} {
		if e := callError(t, window, "", "policy/set", wire.PolicySet{Policy: bad}); !strings.Contains(e, "-32602") {
			t.Errorf("%+v: %s", bad, e)
		}
	}
	// A member may read the rules, not the document, and changes nothing.
	for _, method := range []string{"policy/get", "policy/set", "policy/stopAll", "policy/raise"} {
		if e := callError(t, sam.window, "", method, map[string]any{"policy": map[string]any{}, "on": true, "user": sam.id}); !strings.Contains(e, "-32045") {
			t.Errorf("%s: %s", method, e)
		}
	}

	rules := wire.OrgPolicy{
		PermissionMode: optional(wire.PermissionLevelApproveForMe), Sandbox: optional("required"),
		Runtimes:    map[string]wire.PolicyRuntimeRule{"claude": {Models: []string{"claude-sonnet-*"}}, "codex": {}},
		Budgets:     &wire.PolicyBudgets{Daily: optional(40.0), DailyTokens: optional(int64(500_000))},
		Environment: &wire.PolicyEnvironment{PassThrough: []string{"AWS_*", "HTTPS_PROXY"}},
		// The kill switch and raises change only by their own methods; version is the plane's.
		StopAll: &wire.PolicyStopAll{On: true}, Version: 41,
	}
	first := setPolicy(t, window, rules, nil)
	if first.Policy == nil || first.Policy.Version != 1 || first.Rev == nil || first.Policy.StopAll != nil ||
		!slices.Equal(first.Policy.Requires, []string{CapHostPolicy, wire.CapHostPolicyLayers1}) || first.Policy.ChangedBy.User != p.s.localOwner() {
		t.Fatalf("%+v", first.Policy)
	}

	// Two admins read the same rev; the second to save is told to load it again.
	var priyaRead wire.PolicyKept
	json.Unmarshal(call(t, priya.window, "", "policy/get", nil), &priyaRead)
	second := setPolicy(t, window, wire.OrgPolicy{PermissionMode: optional(wire.PermissionLevelAsk)}, first.Rev)
	if second.Policy.Version != 2 {
		t.Fatalf("%+v", second.Policy)
	}
	if e := callError(t, priya.window, "", "policy/set", wire.PolicySet{Policy: rules, Rev: priyaRead.Rev}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	// Nor may one save over a policy it never read.
	if e := callError(t, priya.window, "", "policy/set", wire.PolicySet{Policy: rules}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	third := setPolicy(t, priya.window, rules, second.Rev)
	if third.Policy.Version != 3 || third.Policy.ChangedBy.User != priya.id {
		t.Fatalf("%+v", third.Policy)
	}

	// The machine has version 3, signed by the control key; one changed byte fails.
	p.waitFor(func() bool { return told.version(box.member.Host) == 3 }, "the machine told version 3")
	line, _ := told.last(box.member.Host)
	if line.Signature == nil || line.Signature.Version != 3 || line.Signature.Alg != "es256" ||
		line.Signature.KeyID != controllink.KeyID(p.s.publicKey()) {
		t.Fatalf("%+v", line.Signature)
	}
	if !controllink.VerifyPolicy(p.s.publicKey(), line.Policy, line.Signature.Sig) {
		t.Fatal("the signature does not check with the control key")
	}
	changed := []byte(strings.Replace(string(line.Policy), `"approveForMe"`, `"bypassPermissions"`, 1))
	if string(changed) == string(line.Policy) || controllink.VerifyPolicy(p.s.publicKey(), changed, line.Signature.Sig) {
		t.Fatal("a changed policy checks")
	}
	flipped := append([]byte(nil), line.Policy...)
	flipped[len(flipped)/2] ^= 1
	if controllink.VerifyPolicy(p.s.publicKey(), flipped, line.Signature.Sig) {
		t.Fatal("a policy with one changed byte checks")
	}
	if controllink.VerifyPolicy(mustPublic(t), line.Policy, line.Signature.Sig) {
		t.Fatal("another key's check passes")
	}

	// Each version is kept as it was, before and after (FR-005).
	versions, _ := p.store.List(t.Context(), policyVersionsKey)
	if len(versions) != 3 {
		t.Fatalf("%+v", versions)
	}
	// The audit names who changed it.
	p.waitFor(func() bool {
		var list wire.AuditList
		json.Unmarshal(call(t, window, "", "audit/list", wire.AuditQuery{}), &list)
		n := 0
		for _, e := range list.Entries {
			if e.Method == "policy/set" && e.Action == "Changed the organisation's policy" {
				n++
			}
		}
		return n == 3
	}, "three policy changes in the audit")

	// Sam reads the rules in force.
	var view wire.PolicyView
	json.Unmarshal(call(t, sam.window, "", "policy/mine", nil), &view)
	if view.Policy == nil || view.Policy.Version != 3 || deref(view.Policy.PermissionMode) != wire.PermissionLevelApproveForMe {
		t.Fatalf("%+v", view)
	}
}

// SC-002, FR-006: two copies over one store, three machines across them: a save reaches all
// three within 5 seconds; a machine that does not say host.policy/1 gets nothing; a
// machine that connects later gets the newest.
func TestAPolicyReachesEveryMachineOnEveryCopy(t *testing.T) {
	// Not parallel (#2512): it holds a wall-clock limit, which other tests running beside it would make flaky.
	a, b := twoCopies(t)
	told := newPoliciesTold()
	a.told, b.told = told.heard, told.heard
	_, window := a.client("Admin's Mac")
	machines := []*fakeHost{a.hostSaying(policyHello("MACHINE-2"), nil), b.hostSaying(policyHello("MACHINE-3"), nil),
		b.hostSaying(policyHello("MACHINE-4"), nil)}
	older := a.host("MACHINE-5")
	for _, m := range machines {
		a.waitFor(func() bool { _, ok := told.last(m.member.Host); return ok }, "each machine told at its join")
	}

	kept := setPolicy(t, window, wire.OrgPolicy{PermissionMode: optional(wire.PermissionLevelApproveForMe)}, nil)
	saved := time.Now()
	for _, m := range machines {
		a.waitFor(func() bool { return told.version(m.member.Host) == 1 }, "each machine told version 1")
	}
	if took := time.Since(saved); took > 5*time.Second {
		t.Fatalf("took %v", took)
	}
	if _, ok := told.last(older.member.Host); ok {
		t.Fatal("an older machine was told the policy")
	}

	setPolicy(t, window, wire.OrgPolicy{PermissionMode: optional(wire.PermissionLevelAsk)}, kept.Rev)
	later := b.hostSaying(policyHello("MACHINE-6"), nil)
	a.waitFor(func() bool { return told.version(later.member.Host) == 2 }, "a later machine told the newest")
	line, _ := told.last(later.member.Host)
	if !controllink.VerifyPolicy(b.s.publicKey(), line.Policy, line.Signature.Sig) {
		t.Fatal("the other copy's line does not check")
	}
}

// US5, FR-015: the kill switch is audited and pushed, and control/stopAll reaches every
// person's clients, on and off.
func TestTheKillSwitchReachesEveryone(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := newPoliciesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	box := p.machineSaying(sam, policyHello("MACHINE-2"))

	var kept wire.PolicyKept
	json.Unmarshal(call(t, window, "", "policy/stopAll", wire.PolicyStopAllRequest{On: true, Note: optional("A token leaked.")}), &kept)
	if kept.Policy == nil || kept.Policy.StopAll == nil || !kept.Policy.StopAll.On || kept.Policy.StopAll.By.User != p.s.localOwner() ||
		deref(kept.Policy.StopAll.Note) != "A token leaked." || kept.Policy.Version != 1 {
		t.Fatalf("%+v", kept.Policy)
	}
	var view wire.PolicyView
	json.Unmarshal(waitNote(t, sam.window, wire.NotifyControlStopAll.Name).Params, &view)
	if view.Policy == nil || view.Policy.StopAll == nil || !view.Policy.StopAll.On {
		t.Fatalf("%+v", view)
	}
	p.waitFor(func() bool {
		line, _ := told.last(box.member.Host)
		var policy wire.OrgPolicy
		json.Unmarshal(line.Policy, &policy)
		return policy.StopAll != nil && policy.StopAll.On
	}, "the machine told the switch is on")

	// A save keeps the switch as it is.
	kept = setPolicy(t, window, wire.OrgPolicy{PermissionMode: optional(wire.PermissionLevelApproveForMe)}, kept.Rev)
	if kept.Policy.StopAll == nil || !kept.Policy.StopAll.On {
		t.Fatalf("%+v", kept.Policy)
	}

	call(t, window, "", "policy/stopAll", wire.PolicyStopAllRequest{On: false})
	view = wire.PolicyView{}
	json.Unmarshal(waitNote(t, sam.window, wire.NotifyControlStopAll.Name).Params, &view)
	if view.Policy == nil || view.Policy.StopAll == nil || view.Policy.StopAll.On || view.Policy.Version != 3 {
		t.Fatalf("%+v", view.Policy)
	}
	p.waitFor(func() bool { return told.version(box.member.Host) == 3 }, "the machine told the switch is off")
	p.waitFor(func() bool {
		var list wire.AuditList
		json.Unmarshal(call(t, window, "", "audit/list", wire.AuditQuery{}), &list)
		n := 0
		for _, e := range list.Entries {
			if e.Method == "policy/stopAll" && e.Action == "Turned the kill switch on or off" {
				n++
			}
		}
		return n == 2
	}, "both turns of the switch in the audit")
}

// FR-019: a raise is for one person and today; a person sees only their own.
func TestARaiseIsForOnePersonAndToday(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Alex's Mac")
	sam := p.invite(window, "Sam", wire.UserRoleMember)
	bea := p.invite(window, "Bea", wire.UserRoleMember)

	if e := callError(t, window, "", "policy/raise", wire.PolicyRaiseRequest{User: sam.id, Daily: optional(80.0)}); !strings.Contains(e, "no budget") {
		t.Fatal(e)
	}
	setPolicy(t, window, wire.OrgPolicy{Budgets: &wire.PolicyBudgets{Daily: optional(40.0)}}, nil)
	if e := callError(t, window, "", "policy/raise", wire.PolicyRaiseRequest{User: "nobody", Daily: optional(80.0)}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	call(t, window, "", "policy/raise", wire.PolicyRaiseRequest{User: sam.id, Daily: optional(60.0)})
	var kept wire.PolicyKept
	json.Unmarshal(call(t, window, "", "policy/raise", wire.PolicyRaiseRequest{User: sam.id, Daily: optional(80.0), Request: optional("R1")}), &kept)
	raises := kept.Policy.Budgets.Raises
	today := time.Now().UTC().Format(time.DateOnly)
	if len(raises) != 1 || raises[0].User != sam.id || raises[0].Day != today || deref(raises[0].Daily) != 80 || deref(raises[0].Request) != "R1" {
		t.Fatalf("%+v", raises)
	}
	var view wire.PolicyView
	json.Unmarshal(call(t, bea.window, "", "policy/mine", nil), &view)
	if len(view.Policy.Budgets.Raises) != 0 {
		t.Fatalf("Bea sees %+v", view.Policy.Budgets.Raises)
	}
	view = wire.PolicyView{}
	json.Unmarshal(call(t, sam.window, "", "policy/mine", nil), &view)
	if len(view.Policy.Budgets.Raises) != 1 {
		t.Fatalf("%+v", view.Policy.Budgets)
	}
	// Yesterday's raise goes at the next change.
	if got := currentRaises([]wire.BudgetRaise{{User: sam.id, Day: "2026-01-01"}, raises[0]}, time.Now()); len(got) != 1 || got[0].Day != today {
		t.Fatalf("%+v", got)
	}
}

// Edge case "a machine of an older version": with requireFollowing, a machine that has not
// applied the current version starts no work, and does once it says it has.
func TestRequireFollowingRefusesAMachineBehind(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := newPoliciesTold()
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	box := p.hostSaying(policyHello("MACHINE-2"), nil)
	older := p.host("MACHINE-3")
	host := box.member.Host

	setPolicy(t, window, wire.OrgPolicy{RequireFollowing: optional(true)}, nil)
	for _, h := range []string{host, older.member.Host} {
		e := callError(t, window, h, "agents/start", map[string]any{})
		if !strings.Contains(e, "-32076") || !strings.Contains(e, "does not follow") {
			t.Fatalf("%s: %s", h, e)
		}
	}
	// Reading is never refused.
	call(t, window, host, "daemon/ping", nil)

	p.waitFor(func() bool { return told.version(host) == 1 }, "the machine told version 1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := box.uplink.Ask(ctx, wire.CallHostPolicyApplied.Name, wire.PolicyApplied{Version: 1}); err != nil {
		t.Fatal(err)
	}
	p.waitFor(func() bool {
		e := callError(t, window, host, "agents/start", map[string]any{})
		return !strings.Contains(e, "-32076")
	}, "starts let through once the machine follows")
	if kept := getPolicy(t, window); kept.Machines[host] != 1 {
		t.Fatalf("%+v", kept.Machines)
	}
}

// T012: at a rotation the policy is signed again with the new key, at the same version.
func TestARotationSignsThePolicyAgain(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	keeper := kms.File{Path: filepath.Join(root, "control-key")}
	key, err := keeper.ControlKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	p := startPlaneWith(t, store.NewMemory(), key, func(c *Config) { c.KeyKeeper = keeper })
	_, window := p.client("Window")
	setPolicy(t, window, wire.OrgPolicy{PermissionMode: optional(wire.PermissionLevelApproveForMe)}, nil)
	call(t, window, "", "control/rotate", map[string]any{})
	kept, err := p.s.readPolicy(t.Context())
	if err != nil || kept.signature == nil {
		t.Fatal(err)
	}
	if kept.signature.Version != 1 || kept.signature.KeyID != controllink.KeyID(p.s.publicKey()) ||
		!controllink.VerifyPolicy(p.s.publicKey(), kept.raw, kept.signature.Sig) {
		t.Fatalf("%+v", kept.signature)
	}
}

// TestAStoredModeCeilingIsReadOnceIntoPermissionMode covers #2957, T026: a policy stored
// before this change, with the old modeCeiling field and no permissionMode, is migrated the
// first time it is read, signed as a new version, and never migrated again (research R5:
// each mode-ceiling value maps onto Auto's four permission levels, the same or tighter).
func TestAStoredModeCeilingIsReadOnceIntoPermissionMode(t *testing.T) {
	t.Parallel()
	private := controllink.NewPrivateKey()
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	st := store.NewMemory()
	legacy := []byte(`{"version":1,"issued":1767225600,"changedBy":{"user":"admin"},"requires":["host.policy/1"],"modeCeiling":"acceptEdits"}`)
	canon, err := controllink.CanonicalJSON(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Put(t.Context(), policyKey, canon, store.Absent); err != nil {
		t.Fatal(err)
	}
	sig, err := controllink.SignPolicy(private, canon)
	if err != nil {
		t.Fatal(err)
	}
	sigBytes, _ := json.Marshal(wire.PolicySignature{Version: 1, KeyID: controllink.KeyID(public), Alg: controllink.PolicyAlg, Sig: sig})
	if _, err := st.Put(t.Context(), policySigKey, sigBytes, store.Absent); err != nil {
		t.Fatal(err)
	}

	p := startPlane(t, st, private)
	_, window := p.client("Alex's Mac")
	kept := getPolicy(t, window)
	if kept.Policy == nil || kept.Policy.Version != 2 || deref(kept.Policy.PermissionMode) != wire.PermissionLevelApproveForMe {
		t.Fatalf("the migration did not run as expected: %+v", kept.Policy)
	}
	again := getPolicy(t, window)
	if again.Policy == nil || again.Policy.Version != 2 {
		t.Fatalf("reading the migrated policy again migrated it a second time: %+v", again.Policy)
	}
}
