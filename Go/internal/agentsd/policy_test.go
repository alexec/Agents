package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// The organisation's policy on a machine (#998, spec 998 slice 2a, T014–T018): kept and
// checked on disk, applied as a ceiling at every place a choice is made, the kill switch,
// budgets and requires.

// controlKeys is a scratch control key: what the control plane signs with, and what a
// member checks with.
type controlKeys struct{ private, public []byte }

func newControlKeys(t *testing.T) controlKeys {
	t.Helper()
	private := controllink.NewPrivateKey()
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return controlKeys{private, public}
}

// signed is host/policy for a policy of this version with these rules, signed by k.
func (k controlKeys) signed(t *testing.T, version int64, rules map[string]any) json.RawMessage {
	t.Helper()
	doc := map[string]any{"version": version, "issued": now(), "requires": []string{wire.CapHostPolicy1},
		"changedBy": map[string]any{"user": "priya", "name": "Priya"}}
	for k, v := range rules {
		doc[k] = v
	}
	raw, _ := json.Marshal(doc)
	sig, err := controllink.SignPolicy(k.private, raw)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"policy": json.RawMessage(raw),
		"signature": wire.PolicySignature{Version: version, KeyID: controllink.KeyID(k.public), Alg: controllink.PolicyAlg, Sig: sig}})
	return b
}

// joined is a daemon on root that trusts k, as a machine that joined a control plane.
func joined(t *testing.T, root string, k controlKeys) (*Daemon, *conn) {
	t.Helper()
	d, c := start(t, root)
	d.SettingsDir = filepath.Join(root, "settings")
	d.SetControlKey(k.public)
	return d, c
}

// refused checks a policyRefused error's reason and rule.
func refused(t *testing.T, e *Error, reason, rule string) {
	t.Helper()
	if e == nil || e.Code != wire.FailurePolicyRefused {
		t.Fatalf("not refused by the policy: %+v", e)
	}
	b, _ := json.Marshal(e.Data)
	var r wire.PolicyRefusal
	json.Unmarshal(b, &r)
	if r.Reason != reason || (rule != "" && (r.Rule == nil || *r.Rule != rule)) || r.Words == "" {
		t.Fatalf("refused %+v, wanted %s %s", r, reason, rule)
	}
}

// asError is a Go call's error as the wire's.
func asError(err error) *Error {
	if e, ok := err.(*Error); ok {
		return e
	}
	return nil
}

func startParams(dir, runtime string, values map[string]any) map[string]any {
	return map[string]any{"runtimeID": runtime, "cwd": "file://" + dir, "prompt": "hi",
		"startOptions": map[string]any{"values": values, "extraArguments": []string{}}}
}

// US1: with no control plane, or a control plane with no policy, nothing changes (SC-001).
func TestNoPolicyChangesNothing(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	d.Told(wire.NotifyHostPolicy.Name, json.RawMessage(`{"none":true}`))
	dir := t.TempDir()
	c.call(t, 1, "agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions", "model": "opus"}))
	var st wire.PolicyState
	json.Unmarshal(c.call(t, 2, "daemon/policyState", map[string]any{}), &st)
	if st.Version != nil || st.NoPolicy || st.StopAll || st.Refusal != nil {
		t.Fatalf("%+v", st)
	}
	// A policy signed by another key is no policy: it is refused, and nothing changes.
	other := newControlKeys(t)
	d.Told(wire.NotifyHostPolicy.Name, other.signed(t, 1, map[string]any{"modeCeiling": "ask"}))
	if d.orgPolicy() != nil {
		t.Fatal("a policy of another key was taken")
	}
	if _, err := os.Stat(filepath.Join(root, orgPolicyFile)); err == nil {
		t.Fatal("kept")
	}
	if !slices.Contains(d.Capabilities(), wire.CapHostPolicy1) {
		t.Fatal("the machine does not say host.policy/1")
	}
}

// T015, US6: the policy is kept on disk, 0600; a forged, missing, older or edited copy
// starts no work; a newer one and the same one signed again are taken (SC-005).
func TestThePolicyFileIsKeptAndChecked(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	var told []any
	var mu sync.Mutex
	d.SetControl(func(method string, params any) {
		mu.Lock()
		defer mu.Unlock()
		if method == wire.NewMethodName(wire.CallHostPolicyApplied.Name) {
			told = append(told, params)
		}
	})
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{"modeCeiling": "acceptEdits"}))
	st, err := os.Stat(filepath.Join(root, orgPolicyFile))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", st, err)
	}
	mu.Lock()
	if len(told) != 1 || told[0].(wire.PolicyApplied).Version != 2 {
		t.Fatalf("%+v", told)
	}
	mu.Unlock()
	dir := t.TempDir()
	refused(t, c.callError(t, 1, "agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions"})), "policy", "modeCeiling")

	// An older version is refused, and the machine keeps its own.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{}))
	if p := d.orgPolicy(); p == nil || p.Version != 2 {
		t.Fatalf("%+v", p)
	}
	// A forged one: signed by another key.
	d.Told(wire.NotifyHostPolicy.Name, newControlKeys(t).signed(t, 9, map[string]any{}))
	if p := d.orgPolicy(); p == nil || p.Version != 2 {
		t.Fatalf("%+v", p)
	}
	// none, while the machine holds a policy: kept.
	d.Told(wire.NotifyHostPolicy.Name, json.RawMessage(`{"none":true}`))
	if p := d.orgPolicy(); p == nil || p.Version != 2 {
		t.Fatalf("%+v", p)
	}
	d.Shutdown()

	// Offline, started again: the same ceiling (US6 scenario 1).
	d2, c2 := joined(t, root, k)
	refused(t, c2.callError(t, 1, "agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions"})), "policy", "modeCeiling")
	d2.Shutdown()

	// Edited by hand to loosen it: fails the signature check, and starts no work.
	path := filepath.Join(root, orgPolicyFile)
	b, _ := os.ReadFile(path)
	os.WriteFile(path, []byte(strings.Replace(string(b), "acceptEdits", "bypassPermissions", 1)), 0o600)
	d3, c3 := joined(t, root, k)
	refused(t, c3.callError(t, 1, "agents/start", startParams(dir, "claude", nil)), "noPolicy", "")
	d3.Shutdown()

	// Deleted: the same.
	os.Remove(path)
	d4, c4 := joined(t, root, k)
	e := c4.callError(t, 1, "agents/start", startParams(dir, "claude", nil))
	refused(t, e, "noPolicy", "")
	if !strings.Contains(e.Message, "Connect to the network") {
		t.Fatal(e.Message)
	}
	var st4 wire.PolicyState
	json.Unmarshal(c4.call(t, 2, "daemon/policyState", map[string]any{}), &st4)
	if !st4.NoPolicy || st4.Refusal == nil || st4.Refusal.Reason != "noPolicy" {
		t.Fatalf("%+v", st4)
	}
	// An older copy than the one applied here, put back: still no work.
	old := k.signed(t, 1, map[string]any{})
	os.WriteFile(path, old, 0o600)
	d4.orgMu.Lock()
	d4.orgRead = false
	d4.orgMu.Unlock()
	refused(t, c4.callError(t, 3, "agents/start", startParams(dir, "claude", nil)), "noPolicy", "")
	// The control plane sends the policy: work starts again.
	d4.Told(wire.NotifyHostPolicy.Name, k.signed(t, 3, map[string]any{}))
	c4.call(t, 4, "agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions"}))
}

// T015: after a rotation, a policy signed by the old key is trusted for 30 days.
func TestAPolicyOfTheOldKeyIsTrusted30Days(t *testing.T) {
	k := newControlKeys(t)
	root := t.TempDir()
	d, _ := joined(t, root, k)
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"modeCeiling": "auto"}))
	next := newControlKeys(t)
	d.ControlKeyRotated(next.public)
	d.orgMu.Lock()
	d.orgRead = false
	d.orgMu.Unlock()
	if p := d.orgPolicy(); p == nil || p.Version != 1 {
		t.Fatal("the old key's policy is not trusted after the rotation")
	}
	at := time.Now().Add(31 * 24 * time.Hour)
	old := setNowFunc(func() time.Time { return at })
	t.Cleanup(func() { setNowFunc(old) })
	d.orgMu.Lock()
	d.orgRead = false
	d.orgMu.Unlock()
	if d.orgPolicy() != nil || d.workRefusal() == nil {
		t.Fatal("the old key's policy is still trusted after 30 days")
	}
	// The control plane signs it again with the new key, at the same version: taken.
	d.Told(wire.NotifyHostPolicy.Name, next.signed(t, 1, map[string]any{"modeCeiling": "auto"}))
	if p := d.orgPolicy(); p == nil || d.workRefusal() != nil {
		t.Fatal("the policy signed again is not taken")
	}
}

// T014, SC-003: every rule at every path where its choice is made is refused, with the
// reason policy and the rule's name; a helper's and a workflow's mode falls to the
// ceiling. Then a looser policy gives back each choice, unchanged (FR-011).
func TestEveryRuleAtEveryPath(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	dir := t.TempDir()
	os.MkdirAll(d.SettingsDir, 0o700)
	// The person's own settings, looser than the policy: kept as they are.
	os.WriteFile(filepath.Join(d.SettingsDir, "sandbox.json"), []byte(`{"defaults":{"claude":"off"}}`), 0o600)
	os.WriteFile(filepath.Join(d.SettingsDir, passThroughFile), []byte(`{"names":["AWS_PROFILE","MY_*"],"runtimes":{"claude":["SECRET_TOKEN"]}}`), 0o600)
	rules := map[string]any{
		"modeCeiling":  "acceptEdits",
		"sandbox":      "required",
		"runtimes":     map[string]any{"claude": map[string]any{"models": []string{"claude-sonnet-*"}}, "codex": map[string]any{}},
		"marketplaces": map[string]any{"allowed": []string{"provided:github-mcp"}, "customServers": "refuse"},
		"helpers":      map[string]any{"mostRunning": 1, "mostNotArchived": 2},
		"environment":  map[string]any{"passThrough": []string{"AWS_*"}},
	}
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, rules))

	notAllowed := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "grok"; a.RuntimeSessionID = new("s") })
	opts := []wire.ConfigOption{
		{ID: "mode", Name: "Mode", Category: new("mode"), Type: "select", CurrentValue: json.RawMessage(`"default"`),
			Options: json.RawMessage(`[{"value":"default","name":"Default"},{"value":"acceptEdits","name":"Accept Edits"},{"value":"bypassPermissions","name":"Bypass"}]`)},
		{ID: "model", Name: "Model", Category: new("model"), Type: "select", CurrentValue: json.RawMessage(`"claude-sonnet-5"`),
			Options: json.RawMessage(`[{"value":"claude-sonnet-5","name":"Sonnet"},{"value":"claude-opus-5-5","name":"Opus"}]`)},
	}
	claude := seeded(t, d, dir, func(a *wire.Agent) { a.AdvertisedOptions = opts })
	failing := seeded(t, d, dir, func(a *wire.Agent) {
		a.PendingSandboxFailure = &wire.SandboxFailureRecord{RuntimeID: "claude", Detail: "x", RecoveryOffered: true}
	})
	entries, _, _ := d.Store.Transcript(claude.ID, 0)
	_ = entries

	n := 10
	call := func(method string, params any) *Error { n++; return c.callError(t, n, method, params) }
	rows := []struct {
		path, rule string
		err        func() *Error
	}{
		{"start: a runtime not allowed", "runtimes", func() *Error { return call("agents/start", startParams(dir, "grok", nil)) }},
		{"start: a model not allowed", "runtimes.claude.models", func() *Error {
			return call("agents/start", startParams(dir, "claude", map[string]any{"model": "claude-opus-5-5"}))
		}},
		{"start: a looser mode", "modeCeiling", func() *Error {
			return call("agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions"}))
		}},
		{"start: a mode this machine does not know", "modeCeiling", func() *Error {
			return call("agents/start", startParams(dir, "claude", map[string]any{"mode": "yolo"}))
		}},
		{"start: sandbox off", "sandbox", func() *Error {
			p := startParams(dir, "claude", nil)
			p["sandbox"] = "off"
			return call("agents/start", p)
		}},
		{"setOption: a looser mode", "modeCeiling", func() *Error {
			return call("agents/setOption", map[string]any{"agentID": claude.ID, "optionID": "mode", "value": "bypassPermissions"})
		}},
		{"setOption: a model not allowed", "runtimes.claude.models", func() *Error {
			return call("agents/setOption", map[string]any{"agentID": claude.ID, "optionID": "model", "value": "claude-opus-5-5"})
		}},
		{"setSandbox: off", "sandbox", func() *Error {
			return call("agents/setSandbox", map[string]any{"agentID": claude.ID, "choice": "off"})
		}},
		{"the failure card: carry on without the sandbox", "sandbox", func() *Error {
			return call("agents/answerSandbox", map[string]any{"agentID": failing.ID, "carryOn": true})
		}},
		{"prompt: a runtime not allowed", "runtimes", func() *Error {
			return call("agents/prompt", map[string]any{"agentID": notAllowed.ID, "text": "go on"})
		}},
		{"Continue in New: a runtime not allowed", "runtimes", func() *Error {
			return asError(func() error {
				_, err := d.continueInFolder(wire.ContinueInFolderRequest{AgentID: notAllowed.ID})
				return err
			}())
		}},
		{"Branch: a runtime not allowed", "runtimes", func() *Error {
			return asError(func() error { _, err := d.fork(d.ctx, notAllowed.ID); return err }())
		}},
		{"Branch from here: a runtime not allowed", "runtimes", func() *Error {
			return asError(func() error { _, err := d.branchFrom(wire.BranchFromRequest{AgentID: notAllowed.ID}); return err }())
		}},
		{"helper: a model not allowed", "runtimes.claude.models", func() *Error {
			_, err := d.startFor(helperRequest("claude", dir, "help", "claude-opus-5-5", nil, nil, nil), startedBy{agent: &claude.ID, owner: wire.SessionLabelOwnerAgent})
			return asError(err)
		}},
		{"workflow: a runtime not allowed", "runtimes", func() *Error {
			_, err := d.startFor(helperRequest("grok", dir, "run", "", nil, nil, nil), startedBy{owner: wire.SessionLabelOwnerAgent})
			return asError(err)
		}},
		{"marketplaces/add: not allowed", "marketplaces", func() *Error {
			return call("marketplaces/add", map[string]any{"name": "Mine", "format": "mcp-registry", "url": "https://example.com/registry"})
		}},
		{"marketplaces/set-enabled: not allowed", "marketplaces", func() *Error {
			return call("marketplaces/set-enabled", map[string]any{"id": "provided:official-mcp", "enabled": true})
		}},
		{"mcp/add-by-hand: custom servers refused", "marketplaces.customServers", func() *Error {
			return call("mcp/add-by-hand", map[string]any{"verifyID": store.NewUUID(), "destination": map[string]any{"kind": "personal"}})
		}},
		{"folders/setHelperLimits: above the cap", "helpers.mostRunning", func() *Error {
			return asError(d.helperLimitsRefusal(wire.HelperLimits{Running: new(int64(3))}))
		}},
	}
	for _, r := range rows {
		t.Run(r.path, func(t *testing.T) { refused(t, r.err(), "policy", r.rule) })
	}

	// A helper's or a workflow's looser mode falls to the ceiling, and its chat says so.
	id, err := d.startFor(helperRequest("claude", dir, "help", "", new("bypassPermissions"), nil, nil), startedBy{agent: &claude.ID, owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		t.Fatal(err)
	}
	if v := stringValue(d.Store.Agent(id).StartOptions.Values["mode"]); v == "bypassPermissions" {
		t.Fatal("the helper kept its looser mode")
	}
	if !slices.ContainsFunc(notes(d, id), func(s string) bool { return strings.Contains(s, "Set by your organisation") }) {
		t.Fatal(notes(d, id))
	}

	// The sandbox: the person's own default off is capped to on, and kept as written.
	if choice, why := d.resolveSandbox("claude", nil, nil); choice != wire.SandboxChoiceOn || why == nil {
		t.Fatalf("%s %v", choice, why)
	}
	if b, _ := os.ReadFile(filepath.Join(d.SettingsDir, "sandbox.json")); !strings.Contains(string(b), `"off"`) {
		t.Fatal("the person's setting was changed")
	}
	var sandbox wire.SandboxSettings
	json.Unmarshal(c.call(t, 90, "sandbox/state", map[string]any{}), &sandbox)
	if sandbox.SetBy == nil || sandbox.SetBy.Rule != "sandbox" {
		t.Fatalf("%+v", sandbox)
	}
	// The failure card offers no carrying on without it.
	d.recordSandboxFailure(claude.ID, "sandbox_apply: Operation not permitted", 0)
	if d.Store.Agent(claude.ID).PendingSandboxFailure.RecoveryOffered {
		t.Fatal("Continue without sandbox is offered")
	}

	// Marketplaces: only the allowed one is listed.
	var list wire.MarketplacesListAnswer
	json.Unmarshal(c.call(t, 91, "marketplaces/list", map[string]any{}), &list)
	if len(list.Marketplaces) != 1 || list.Marketplaces[0].ID != "provided:github-mcp" {
		t.Fatalf("%+v", list.Marketplaces)
	}
	if d.previewCatalog(wire.CatalogResult{}, wire.SkillDestination{Kind: wire.SkillDestinationKindPersonal}) != nil {
		t.Fatal("a skill can be previewed from skills.sh, which is not allowed")
	}

	// Helpers: the folder's limits are capped.
	if running, notArchived, _ := d.helperLimitsIn(dir); running != 1 || notArchived != 2 {
		t.Fatalf("%d %d", running, notArchived)
	}

	// The launch environment: only the names the policy allows of the person's own.
	env := environment(runtimeByID("claude"), []string{"AWS_PROFILE=dev", "MY_VAR=1", "SECRET_TOKEN=x", "PATH=/bin"}, d.passThrough("claude")...)
	if strings.Join(env, " ") != "AWS_PROFILE=dev PATH=/bin" {
		t.Fatal(env)
	}
	var pass wire.PassThroughState
	json.Unmarshal(c.call(t, 92, "settings/passThrough", map[string]any{}), &pass)
	marked := map[string]bool{}
	for _, p := range pass.Names {
		marked[p.Name] = p.SetBy != nil
	}
	if len(pass.Names) != 3 || marked["AWS_PROFILE"] || !marked["MY_*"] || !marked["SECRET_TOKEN"] {
		t.Fatalf("%+v", pass.Names)
	}

	// The lists the clients draw mark what is refused.
	var runtimes []wire.RuntimeStatus
	json.Unmarshal(c.call(t, 93, "runtimes/list", map[string]any{}), &runtimes)
	for _, r := range runtimes {
		if allowed := r.Runtime.ID == "claude" || r.Runtime.ID == "codex"; allowed == (r.SetBy != nil) {
			t.Errorf("%s marked %v", r.Runtime.ID, r.SetBy)
		}
	}
	marks := d.markOptions("claude", opts)
	if !strings.Contains(string(marks[0].Options), `"value":"bypassPermissions","setBy"`) && !strings.Contains(string(marks[0].Options), `"setBy":{"by":"organisation","rule":"modeCeiling"`) {
		t.Fatalf("%s", marks[0].Options)
	}
	if strings.Count(string(marks[0].Options), "setBy") != 1 || strings.Count(string(marks[1].Options), "setBy") != 1 {
		t.Fatalf("%s %s", marks[0].Options, marks[1].Options)
	}

	// A looser policy gives every choice back, the person's own settings unchanged.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{}))
	c.call(t, 100, "agents/setOption", map[string]any{"agentID": claude.ID, "optionID": "model", "value": "claude-opus-5-5"})
	if choice, _ := d.resolveSandbox("claude", nil, nil); choice != wire.SandboxChoiceOff {
		t.Fatalf("the person's sandbox default did not come back: %s", choice)
	}
	if running, _, _ := d.helperLimitsIn(dir); running != defaultHelpersRunning {
		t.Fatal(running)
	}
	env = environment(runtimeByID("claude"), []string{"MY_VAR=1", "SECRET_TOKEN=x"}, d.passThrough("claude")...)
	if strings.Join(env, " ") != "MY_VAR=1 SECRET_TOKEN=x" {
		t.Fatal(env)
	}
	if strings.Contains(string(d.markOptions("claude", opts)[0].Options), "setBy") {
		t.Fatal("still marked")
	}
	c.call(t, 101, "agents/start", startParams(dir, "claude", map[string]any{"mode": "bypassPermissions"}))
}

// T014, FR-012: a running agent meets a new policy at its next turn: its mode goes down
// to the ceiling, with a line in its chat; a runtime now refused waits, and says why.
func TestARunningAgentMeetsANewPolicyAtItsNextTurn(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	dir := t.TempDir()
	id := startAgent(t, c, 1, dir, "hi")
	c.until(t, "the first turn", ended(id, wire.AgentStateFinished))
	d.change(id, func(a *wire.Agent) {
		a.AdvertisedOptions = []wire.ConfigOption{{ID: "mode", Name: "Mode", Category: new("mode"), Type: "select",
			CurrentValue: json.RawMessage(`"bypassPermissions"`),
			Options:      json.RawMessage(`[{"value":"default"},{"value":"acceptEdits"},{"value":"bypassPermissions"}]`)}}
		a.StartOptions.Values = map[string]wire.JSONValue{"mode": json.RawMessage(`"bypassPermissions"`)}
	})
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"modeCeiling": "acceptEdits"}))
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "go on", "from": "person"})
	waitFor(t, "the second turn", func() bool { return len(userMessages(d, id)) == 2 })
	if v := stringValue(d.Store.Agent(id).StartOptions.Values["mode"]); v != "acceptEdits" {
		t.Fatalf("mode %s", v)
	}
	if !slices.ContainsFunc(notes(d, id), func(s string) bool {
		return strings.HasPrefix(s, "The mode is now acceptEdits, not bypassPermissions.")
	}) {
		t.Fatal(notes(d, id))
	}
	waitFor(t, "the end", func() bool { a := d.Store.Agent(id); return a.State == wire.AgentStateFinished })
	// Its runtime is now refused: what is sent waits, and the chat says why.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{"runtimes": map[string]any{"codex": map[string]any{}}}))
	d.change(id, func(a *wire.Agent) {
		a.QueuedPrompts = append(a.QueuedPrompts, wire.QueuedPrompt{ID: store.NewUUID(), Text: "more", QueuedAt: now(), From: wire.PromptOriginPerson})
	})
	d.live(id).kick()
	waitFor(t, "the hold said", func() bool {
		return slices.ContainsFunc(notes(d, id), func(s string) bool { return strings.Contains(s, "does not allow Claude") })
	})
	if len(userMessages(d, id)) != 2 || len(d.Store.Agent(id).QueuedPrompts) != 1 {
		t.Fatal("the turn went")
	}
}

// An option that approves every request without asking (Copilot's allow_all) is under
// the mode ceiling: refused to a person, dropped from a helper's or a workflow's start,
// marked in the lists, and turned off before a running agent's next turn.
func TestApprovingEveryRequestIsUnderTheModeCeiling(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	dir := t.TempDir()
	id := startAgent(t, c, 1, dir, "hi")
	c.until(t, "the first turn", ended(id, wire.AgentStateFinished))
	opts := []wire.ConfigOption{{ID: "allow_all", Name: "Allow all", Category: new("permissions"), Type: "select",
		CurrentValue: json.RawMessage(`"on"`),
		Options:      json.RawMessage(`[{"value":"off"},{"value":"on"}]`)}}
	d.change(id, func(a *wire.Agent) { a.AdvertisedOptions = opts })
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"modeCeiling": "acceptEdits"}))

	refused(t, c.callError(t, 2, "agents/start", startParams(dir, "claude", map[string]any{"allow_all": "on"})), "policy", "modeCeiling")
	refused(t, c.callError(t, 3, "agents/setOption", map[string]any{"agentID": id, "optionID": "allow_all", "value": "on"}), "policy", "modeCeiling")
	r := helperRequest("claude", dir, "help", "", nil, nil, nil)
	r.StartOptions.Values["allow_all"] = json.RawMessage(`"on"`)
	helper, err := d.startFor(r, startedBy{agent: &id, owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		t.Fatal(err)
	}
	if v := stringValue(d.Store.Agent(helper).StartOptions.Values["allow_all"]); v == "on" {
		t.Fatal("the helper approves every request")
	}
	var marked []struct {
		Value string            `json:"value"`
		SetBy *wire.PolicySetBy `json:"setBy"`
	}
	json.Unmarshal(d.markOptions("copilot", opts)[0].Options, &marked)
	if len(marked) != 2 || marked[0].SetBy != nil || marked[1].SetBy == nil || marked[1].SetBy.Rule != "modeCeiling" {
		t.Fatalf("%+v", marked)
	}

	c.call(t, 4, "agents/prompt", map[string]any{"agentID": id, "text": "go on", "from": "person"})
	waitFor(t, "the second turn", func() bool { return len(userMessages(d, id)) == 2 })
	if v := stringValue(d.Store.Agent(id).StartOptions.Values["allow_all"]); v != "off" {
		t.Fatalf("allow_all %q", v)
	}
	if !slices.ContainsFunc(notes(d, id), func(s string) bool { return strings.HasPrefix(s, "It no longer approves every request") }) {
		t.Fatal(notes(d, id))
	}

	// The loosest ceiling allows it.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{"modeCeiling": "bypassPermissions"}))
	if err := d.optionRefusal(d.Store.Agent(id), "allow_all", "on"); err != nil {
		t.Fatal(err)
	}
}

// An agent started with no model chosen runs on the runtime's own: once the runtime says
// it, a model the policy refuses holds the first turn, as at the start of any turn.
func TestTheRuntimesOwnModelIsCheckedBeforeTheFirstTurn(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	// The fake runtime's own model in a folder called offers is opus.
	dir := filepath.Join(t.TempDir(), "offers")
	os.Mkdir(dir, 0o755)
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"runtimes": map[string]any{"claude": map[string]any{"models": []string{"sonnet"}}}}))
	id := startAgent(t, c, 1, dir, "hi")
	waitFor(t, "the hold said", func() bool {
		return slices.ContainsFunc(notes(d, id), func(s string) bool { return strings.Contains(s, "does not allow the model opus") })
	})
	if len(userMessages(d, id)) != 0 || len(d.Store.Agent(id).QueuedPrompts) != 1 {
		t.Fatal("the first turn went on a refused model")
	}
}

// #2274: Claude's model values are aliases (sonnet, opus[1m], default), so a pattern is
// matched with the value, the value without its context suffix, the model id that the
// option's name says (Sonnet 5 is claude-sonnet-5) and the family (claude-sonnet).
func TestAModelPatternMatchesTheAliasAndTheModelItIs(t *testing.T) {
	// The Claude adapter's model option, as it says it (specs/052-quota-fallback/walk).
	claude := []wire.ConfigOption{{ID: "model", Name: "Model", Category: new("model"), Type: "select",
		CurrentValue: json.RawMessage(`"default"`), Options: json.RawMessage(`[
		{"value":"default","name":"Default (recommended)","description":"Opus (1M context)"},
		{"value":"opus[1m]","name":"Opus 5.5","description":"Opus 5.5 with 1M context"},
		{"value":"claude-fable-5-1[1m]","name":"Fable 5.1","description":"Fable 5.1"},
		{"value":"sonnet","name":"Sonnet 5","description":"Sonnet 5"},
		{"value":"haiku","name":"Haiku 4.5","description":"Haiku 4.5"}]`)}}
	d := &Daemon{}
	rows := []struct {
		runtime  string
		patterns []string
		options  []wire.ConfigOption
		allowed  []string
		refused  []string
	}{
		{"claude", []string{"claude-sonnet-*"}, claude, []string{"sonnet"}, []string{"default", "opus[1m]", "claude-fable-5-1[1m]", "haiku"}},
		{"claude", []string{"claude-opus-*"}, claude, []string{"default", "opus[1m]"}, []string{"sonnet", "haiku", "claude-fable-5-1[1m]"}},
		{"claude", []string{"claude-sonnet-5*", "claude-haiku-4-5*"}, claude, []string{"sonnet", "haiku"}, []string{"default", "opus[1m]"}},
		{"claude", []string{"claude-sonnet-4*"}, claude, nil, []string{"sonnet"}},
		{"claude", []string{"claude-fable-5-1"}, claude, []string{"claude-fable-5-1[1m]"}, []string{"opus[1m]"}},
		{"claude", []string{"claude-opus-5-5"}, claude, []string{"opus[1m]", "default"}, []string{"sonnet"}},
		{"claude", []string{"sonnet", "opus[1m]"}, claude, []string{"sonnet", "opus[1m]", "default"}, []string{"haiku"}},
		{"claude", []string{"claude-*"}, claude, []string{"default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"}, nil},
		// Before the runtime says its options: the family alone, and default waits for the turn.
		{"claude", []string{"claude-sonnet-*"}, nil, []string{"sonnet", "sonnet[1m]", "claude-sonnet-5", "default"}, []string{"opus", "claude-opus-5-5"}},
		{"claude", []string{"claude-sonnet-5*"}, nil, []string{"claude-sonnet-5"}, []string{"sonnet", "opus"}},
		// Another runtime's values are ids: exact names and prefixes only.
		{"codex", []string{"gpt-5*"}, nil, []string{"gpt-5", "gpt-5-codex"}, []string{"o3", "default"}},
		{"codex", []string{"gpt-5-codex"}, nil, []string{"gpt-5-codex"}, []string{"gpt-5", "gpt-5-codex-mini"}},
	}
	for _, r := range rows {
		p := &wire.OrgPolicy{Runtimes: map[string]wire.PolicyRuntimeRule{r.runtime: {Models: r.patterns}}}
		for _, m := range r.allowed {
			if err := d.modelRefusal(p, r.runtime, m, r.options); err != nil {
				t.Errorf("%s %v refused %s: %v", r.runtime, r.patterns, m, err)
			}
		}
		for _, m := range r.refused {
			if d.modelRefusal(p, r.runtime, m, r.options) == nil {
				t.Errorf("%s %v allowed %s", r.runtime, r.patterns, m)
			}
		}
	}
}

// #2426: marking a list of V models under a model rule decodes the list once, not once per
// model: the cost grows with V, not V². 300 models (OpenCode's size) against 30 costs about
// 10 times as much, where decoding per model cost about 100 times.
func TestMarkingTheModelsGrowsWithTheList(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	d, _ := joined(t, t.TempDir(), k)
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"runtimes": map[string]any{
		"claude":   map[string]any{"models": []string{"claude-sonnet-*"}},
		"opencode": map[string]any{"models": []string{"anthropic/*"}},
	}}))
	models := func(n int) []wire.ConfigOption {
		items := make([]map[string]string, n)
		for i := range items {
			items[i] = map[string]string{"value": fmt.Sprintf("vendor/model-%d", i), "name": fmt.Sprintf("Model %d", i), "description": "A model"}
		}
		raw, _ := json.Marshal(items)
		return []wire.ConfigOption{{ID: "model", Name: "Model", Category: new("model"), Type: "select",
			CurrentValue: json.RawMessage(`"vendor/model-0"`), Options: raw}}
	}
	small, large := models(30), models(300)
	for _, runtime := range []string{"claude", "opencode"} {
		if n := strings.Count(string(d.markOptions(runtime, large)[0].Options), "setBy"); n != 300 {
			t.Fatalf("%s: %d of 300 marked", runtime, n)
		}
		a := testing.AllocsPerRun(5, func() { d.markOptions(runtime, small) })
		b := testing.AllocsPerRun(5, func() { d.markOptions(runtime, large) })
		start := time.Now()
		d.markOptions(runtime, large)
		t.Logf("%s: %.0f allocs at 30 models, %.0f at 300 (×%.1f); 300 models in %v", runtime, a, b, b/a, time.Since(start))
		if b/a > 20 {
			t.Errorf("%s: marking 300 models costs %.0f times as much as 30", runtime, b/a)
		}
	}
}

// T016, US5, SC-004: the kill switch stops each running turn within 5 s, refuses new
// agents, prompts and workflow runs, keeps what is queued, and when it is turned off
// starts nothing by itself.
func TestTheKillSwitch(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	one, two := t.TempDir(), t.TempDir()
	a := startAgent(t, c, 1, one, "wait for me")
	b := startAgent(t, c, 2, two, "wait for me")
	waitFor(t, "both running", func() bool {
		return d.Store.Agent(a).State == wire.AgentStateRunning && d.Store.Agent(b).State == wire.AgentStateRunning
	})
	c.call(t, 3, "agents/prompt", map[string]any{"agentID": a, "text": "later", "from": "person"})
	at := time.Now()
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"stopAll": map[string]any{"on": true, "by": map[string]any{"user": "priya"}, "at": now()}}))
	waitFor(t, "both stopped", func() bool { return !inFlight(d.Store.Agent(a).State) && !inFlight(d.Store.Agent(b).State) })
	if s := time.Since(at); s > 5*time.Second {
		t.Fatalf("stopped after %s", s)
	}
	refused(t, c.callError(t, 4, "agents/start", startParams(one, "claude", nil)), "stopAll", "stopAll")
	refused(t, c.callError(t, 5, "agents/prompt", map[string]any{"agentID": b, "text": "again"}), "stopAll", "stopAll")
	// A workflow's run starts as a workflow's agent does.
	_, err := d.startFor(helperRequest("claude", one, "run", "", nil, nil, nil), startedBy{owner: wire.SessionLabelOwnerAgent})
	refused(t, asError(err), "stopAll", "stopAll")
	var st wire.PolicyState
	json.Unmarshal(c.call(t, 6, "daemon/policyState", map[string]any{}), &st)
	if !st.StopAll || st.Refusal == nil || st.Refusal.Reason != "stopAll" {
		t.Fatalf("%+v", st)
	}
	if q := d.Store.Agent(a).QueuedPrompts; len(q) != 1 || q[0].Text != "later" {
		t.Fatalf("the queued prompt went: %+v", q)
	}
	// Off: nothing starts by itself; the queued prompt stays until its person sends again.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{"stopAll": map[string]any{"on": false, "by": map[string]any{"user": "priya"}, "at": now()}}))
	time.Sleep(300 * time.Millisecond)
	if q := d.Store.Agent(a).QueuedPrompts; len(q) != 1 || inFlight(d.Store.Agent(a).State) {
		t.Fatal("something started by itself")
	}
	c.call(t, 7, "agents/start", startParams(one, "claude", nil))
}

// T017, US4, SC-006: budgets on the machine.
func TestMachineBudgets(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	dir := t.TempDir()
	d.toldHostUser(mustJSON(wire.MachineUser{User: "sam", Kind: "person", Name: "Sam", Labels: []string{}}))
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"budgets": map[string]any{"daily": 1, "dailyTokens": 50000,
		"allowUnmetered": []string{"grok"}, "raises": []any{}}}))
	// An unmetered runtime not allowed is refused; one allowed is not.
	_, _, err := d.policyStart(&wire.StartRequest{RuntimeID: "cursor"}, startedBy{owner: wire.SessionLabelOwnerPerson}, nil)
	refused(t, asError(err), "policy", "budgets.allowUnmetered")
	if _, _, err := d.policyStart(&wire.StartRequest{RuntimeID: "grok"}, startedBy{owner: wire.SessionLabelOwnerPerson}, nil); err != nil {
		t.Fatal(err)
	}
	var cost wire.CostState
	json.Unmarshal(c.call(t, 1, "cost/state", map[string]any{}), &cost)
	if cost.Organisation == nil || cost.Organisation.Daily.Amount != 1 || cost.SetBy == nil {
		t.Fatalf("%+v", cost)
	}
	// Tokens count for a runtime that reports no cost (a subscription).
	a := seeded(t, d, dir, nil)
	d.bankTurnUsage(a.ID, wire.TurnUsage{InputTokens: 40000, OutputTokens: 20000, TotalTokens: 60000})
	refused(t, c.callError(t, 2, "agents/start", startParams(dir, "claude", nil)), "budget", "budgets.dailyTokens")
	// A raise for today lets the work go on.
	today := time.Now().UTC().Format(time.DateOnly)
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 2, map[string]any{"budgets": map[string]any{"daily": 1, "dailyTokens": 50000,
		"allowUnmetered": []string{}, "raises": []any{map[string]any{"user": "sam", "day": today, "dailyTokens": 100000, "by": map[string]any{"user": "priya"}}}}}))
	c.call(t, 3, "agents/start", startParams(dir, "claude", nil))
	// The dollars: the machine refuses at its own count.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1.5, Currency: "USD"})
	e := c.callError(t, 4, "agents/start", startParams(dir, "claude", nil))
	refused(t, e, "budget", "budgets.daily")
	if !strings.Contains(e.Message, "$1.00 budget, set by your organisation. It starts again at 00:00 UTC.") {
		t.Fatal(e.Message)
	}
	// And at once for what is queued on an agent.
	d.change(a.ID, func(a *wire.Agent) {
		a.QueuedPrompts = []wire.QueuedPrompt{{ID: store.NewUUID(), Text: "more", QueuedAt: now(), From: wire.PromptOriginPerson}}
	})
	if !d.holdsForPolicy(d.live(a.ID)) {
		t.Fatal("the turn was not held at the budget")
	}
	// The control plane's count across machines wins (capReachedUntil).
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 3, map[string]any{"budgets": map[string]any{"daily": 100, "allowUnmetered": []string{}, "raises": []any{}}}))
	c.call(t, 5, "agents/start", startParams(dir, "claude", nil))
	until := wire.DateOf(endOfUTCDay(time.Now()))
	d.toldHostUser(mustJSON(wire.MachineUser{User: "sam", Kind: "person", Name: "Sam", Labels: []string{}, CapReachedUntil: &until}))
	refused(t, c.callError(t, 6, "agents/start", startParams(dir, "claude", nil)), "budget", "budgets")
}

// T018: a capability the policy requires that this machine lacks refuses every start.
func TestAMissingCapabilityRefusesEveryStart(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	d, c := joined(t, t.TempDir(), k)
	raw := k.signed(t, 1, map[string]any{})
	raw = json.RawMessage(strings.Replace(string(raw), `"requires":["host.policy/1"]`, `"requires":["host.policy/1","policy.reach/1"]`, 1))
	// Signed again over the changed document.
	var line struct {
		Policy json.RawMessage `json:"policy"`
	}
	json.Unmarshal(raw, &line)
	sig, _ := controllink.SignPolicy(k.private, line.Policy)
	b, _ := json.Marshal(map[string]any{"policy": line.Policy,
		"signature": wire.PolicySignature{Version: 1, KeyID: controllink.KeyID(k.public), Alg: controllink.PolicyAlg, Sig: sig}})
	d.Told(wire.NotifyHostPolicy.Name, b)
	e := c.callError(t, 1, "agents/start", startParams(t.TempDir(), "claude", nil))
	refused(t, e, "update", "requires")
	if !strings.Contains(e.Message, "Update Agents Host") {
		t.Fatal(e.Message)
	}
	if st := d.policyState(); len(st.Update) != 1 || st.Update[0] != "policy.reach/1" {
		t.Fatalf("%+v", st)
	}
}

// T025: each roll-up row carries the tokens a limit counts.
func TestARollupRowCarriesLimitTokens(t *testing.T) {
	var r wire.UsageRollupRow
	addRollupRow(&r, wire.UsageRollupRow{InputTokens: 5, LimitTokens: new(int64(4))})
	addRollupRow(&r, wire.UsageRollupRow{InputTokens: 5, LimitTokens: new(int64(6))})
	addRollupRow(&r, wire.UsageRollupRow{InputTokens: 5})
	if r.LimitTokens == nil || *r.LimitTokens != 10 {
		t.Fatalf("%+v", r.LimitTokens)
	}
}

// Always-approve for the runtimes the app answers for is under the mode ceiling too: a
// saved Yes answers nothing, setting one is refused, and the state says who set it. A
// helper or a workflow's agent never takes the person's from Settings.
func TestAlwaysApproveIsUnderTheModeCeiling(t *testing.T) {
	fakeRuntimes(t)
	k := newControlKeys(t)
	root := t.TempDir()
	d, c := joined(t, root, k)
	dir := t.TempDir()
	os.MkdirAll(d.SettingsDir, 0o700)
	os.WriteFile(filepath.Join(d.SettingsDir, "client-permissions.json"), []byte(`{"grok":"alwaysApprove"}`), 0o600)
	person := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "grok" })
	helper := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "grok"; a.StartedByAgent = &person.ID })
	workflow := seeded(t, d, dir, func(a *wire.Agent) { a.RuntimeID = "grok"; a.StartedByWorkflow = new("wf") })
	if !d.agentAlwaysApproves(&person) || d.agentAlwaysApproves(&helper) || d.agentAlwaysApproves(&workflow) {
		t.Fatal("Settings' Yes is for the person's own agents only")
	}
	yes := wire.ClientPermissionModeAlwaysApprove
	helper.ClientPermission = &yes
	if !d.agentAlwaysApproves(&helper) {
		t.Fatal("the helper's own Yes")
	}

	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 1, map[string]any{"modeCeiling": "acceptEdits"}))
	if d.agentAlwaysApproves(&person) || d.agentAlwaysApproves(&helper) {
		t.Fatal("Always-approve answers above the ceiling")
	}
	var cp wire.ClientPermissionSettings
	json.Unmarshal(c.call(t, 2, "clientPermissions/state", nil), &cp)
	if cp.SetBy == nil || cp.SetBy.Rule != "modeCeiling" {
		t.Fatalf("%+v", cp)
	}
	refused(t, c.callError(t, 3, "clientPermissions/set", map[string]any{"cursor": "alwaysApprove", "grok": "default", "opencode": "default"}), "policy", "modeCeiling")
	refused(t, c.callError(t, 4, "agents/setClientPermission", map[string]any{"agentID": person.ID, "mode": "alwaysApprove"}), "policy", "modeCeiling")
	refused(t, c.callError(t, 4, "agents/setLevels", map[string]any{"agentID": person.ID, "levels": map[string]any{"permissionRequests": "alwaysApprove"}}), "policy", "modeCeiling")
	// A start's own Yes to all: a person's is refused; a workflow's, and Auto's Approve for
	// me cell, start asking.
	yesToAll := map[string]any{"permissionRequests": "alwaysApprove"}
	refused(t, c.callError(t, 4, "agents/start", map[string]any{"runtimeID": "grok", "cwd": "file://" + dir, "prompt": "x", "levels": yesToAll}), "policy", "modeCeiling")
	asks := func(a *wire.Agent) bool {
		return a.ClientPermission != nil && *a.ClientPermission == wire.ClientPermissionModeDefault && !d.agentAlwaysApproves(a)
	}
	r := helperRequest("grok", dir, "x", "", nil, nil, nil)
	r.Levels = &wire.Levels{PermissionRequests: &yes}
	id, err := d.startFor(r, startedBy{owner: wire.SessionLabelOwnerAgent})
	if err != nil || !asks(d.Store.Agent(id)) {
		t.Fatal("a workflow's Yes to all above the ceiling", err)
	}
	c.call(t, 4, "auto/set", map[string]any{"order": []string{"grok"}, "excluded": []string{"claude", "codex", "cursor", "copilot", "gemini", "opencode", "antigravity"}, "overrides": []any{}})
	var auto wire.UUID
	json.Unmarshal(c.call(t, 4, "agents/start", map[string]any{"runtimeID": "auto", "cwd": "file://" + dir, "prompt": "x", "levels": map[string]any{"permission": "approveForMe"}}), &auto)
	if a := d.Store.Agent(auto); a == nil || a.RuntimeID != "grok" || !asks(a) {
		t.Fatalf("Auto's Yes to all above the ceiling: %+v", a)
	}
	c.call(t, 5, "clientPermissions/set", map[string]any{"cursor": "default", "grok": "default", "opencode": "default"})
	if fi, err := os.Stat(filepath.Join(d.SettingsDir, "client-permissions.json")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatal(fi.Mode(), err)
	}

	// The loosest ceiling allows it.
	d.Told(wire.NotifyHostPolicy.Name, k.signed(t, 6, map[string]any{"modeCeiling": "bypassPermissions"}))
	if !d.agentAlwaysApproves(&helper) {
		t.Fatal("bypassPermissions allows it")
	}
}

// policy/setYours (#2957, T013, FR-010, FR-011, SC-004): refused forbidden from the agent
// socket role, an MCP tool and a workflow (which, in this codebase, all reach a host method
// only over the agent socket role, since no app tool or workflow action calls policy/setYours);
// refused conflict when revision is not the current one; refused notKeeper with the
// keeper's name on a machine that is not the keeper; refused invalid when the rules fail
// policylayers.Validate.

// TestSetYoursRefusesTheAgentSocketRole covers the agent socket role directly, and
// documents that an MCP tool call and a workflow run both ride that same role here (there
// is no app tool or workflow action that reaches policy/setYours at all): the handler's own
// forbiddenCallerRefusal is the one gate for all three.
func TestSetYoursRefusesTheAgentSocketRole(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	for _, role := range []Role{RoleAgent, RolePairing, RoleHostApp, RoleStranger} {
		agent := &Client{Role: role, d: d}
		_, err := d.setYourPolicy(agent, wire.SetYourPolicyRequest{Rules: wire.PolicyRules{}, Revision: 0})
		e := asError(err)
		if e == nil || e.Code != CodeNotPermitted {
			t.Fatalf("%s: %+v, wanted notPermitted", role, err)
		}
	}
	// The dispatch table itself never lets the agent socket role reach the method (defence
	// in depth, SC-004): it is not in agentMethods, so Role.Allows refuses it first.
	if RoleAgent.Allows("policy/setYours") {
		t.Fatal("the agent socket role may call policy/setYours")
	}
}

// TestSetYoursRefusesAConflictingRevision: a revision that is not the one on this machine
// now is refused conflict, so the client reloads before it overwrites a change it has not
// seen (Edge Cases, "Two clients change your layer at once").
func TestSetYoursRefusesAConflictingRevision(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	// The first start makes revision 1 (no old files here, so empty rules).
	json.Unmarshal(c.call(t, 1, "policy/yours", nil), new(wire.YourPolicyState))
	e := c.callError(t, 2, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{}, Revision: 0})
	if e == nil || e.Code != wire.FailureChangedElsewhere {
		t.Fatalf("%+v, wanted changedElsewhere", e)
	}
	// The right revision goes through.
	var set wire.YourPolicy
	json.Unmarshal(c.call(t, 3, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{}, Revision: 1}), &set)
	if set.Revision != 2 {
		t.Fatalf("%+v", set)
	}
}

// TestSetYoursRefusesANonKeeperMachine: a machine that holds a copy of your layer with a
// different keeper (today only reachable by a copy from elsewhere; slice 3 wires the
// transport) refuses to change it itself, naming the keeper (research R4).
func TestSetYoursRefusesANonKeeperMachine(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	os.MkdirAll(d.SettingsDir, 0o700)

	// A copy signed by this machine's own person key (so it is trusted), but naming
	// another host as the keeper: as if it arrived from that other machine.
	other := wire.YourPolicy{Rules: wire.PolicyRules{}, Revision: 1, Changed: now(), Person: "local", Keeper: "another-host"}
	raw, _ := json.Marshal(other)
	private, err := controllink.PersonPrivateKey(d.PersonKey)
	if err != nil {
		t.Fatal(err)
	}
	public, err := controllink.PublicKey(private)
	if err != nil {
		t.Fatal(err)
	}
	sig, err := controllink.SignPolicy(private, raw)
	if err != nil {
		t.Fatal(err)
	}
	kept := map[string]any{"policy": json.RawMessage(raw), "signature": wire.PolicySignature{
		Version: 1, KeyID: controllink.KeyID(public), Alg: controllink.PolicyAlg, Sig: sig,
	}}
	b, _ := json.Marshal(kept)
	if err := os.WriteFile(filepath.Join(d.SettingsDir, yourPolicyFile), b, 0o600); err != nil {
		t.Fatal(err)
	}

	e := c.callError(t, 1, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{}, Revision: 1})
	if e == nil || e.Code != wire.FailureNotKeeper || !strings.Contains(e.Message, "another-host") {
		t.Fatalf("%+v, wanted notKeeper naming another-host", e)
	}
}

// TestSetYoursRefusesInvalidRules: a value out of policylayers.Validate's range is refused
// invalid, and nothing is saved.
func TestSetYoursRefusesInvalidRules(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	tooMany := int64(99)
	e := c.callError(t, 1, "policy/setYours", wire.SetYourPolicyRequest{
		Rules: wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &tooMany}}, Revision: 0,
	})
	if e == nil || e.Code != CodeInvalidParams {
		t.Fatalf("%+v, wanted invalidParams", e)
	}
	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 2, "policy/yours", nil), &state)
	if state.Policy.Rules.Helpers != nil {
		t.Fatalf("the invalid rules were saved anyway: %+v", state.Policy.Rules)
	}
}
