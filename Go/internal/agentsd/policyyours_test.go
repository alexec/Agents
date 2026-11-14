package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The first-start move (#2957, T012, research R9, FR-012): the old settings files are read
// once into your layer, then renamed so nothing reads them again (SC-001).

// TestFirstStartMovesEveryOldSetting writes every old file quickstart.md's slice 2 names,
// asks for policy/yours, and checks each value landed and the old files are gone.
func TestFirstStartMovesEveryOldSetting(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	os.MkdirAll(d.SettingsDir, 0o700)

	mustWrite(t, filepath.Join(d.SettingsDir, "limits.json"), `{"daily":{"amount":40,"currency":"USD"}}`)
	mustWrite(t, filepath.Join(d.SettingsDir, "workflow-limit.json"), `{"total":7}`)
	mustWrite(t, filepath.Join(d.SettingsDir, "display.json"), `{"noticeBurst":2,"agentsMayArchiveMyChats":false,"other":true}`)
	mustWrite(t, filepath.Join(d.SettingsDir, "runtime-environment.json"), `{"names":["FOO"],"runtimes":{"claude":["BAR"]}}`)

	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 1, "policy/yours", nil), &state)
	r := state.Policy.Rules

	if r.Budgets == nil || r.Budgets.Daily == nil || r.Budgets.Daily.Amount != 40 {
		t.Fatalf("budgets: %+v", r.Budgets)
	}
	if r.Workflows == nil || r.Workflows.MostOn == nil || *r.Workflows.MostOn != 7 {
		t.Fatalf("workflows: %+v", r.Workflows)
	}
	if r.NoticeLimits == nil || r.NoticeLimits.Burst == nil || *r.NoticeLimits.Burst != 2 {
		t.Fatalf("noticeLimits: %+v", r.NoticeLimits)
	}
	if r.ArchiveMyChats == nil || *r.ArchiveMyChats {
		t.Fatalf("archiveMyChats: %+v", r.ArchiveMyChats)
	}
	if r.Environment == nil || len(r.Environment.PassThrough) != 1 || r.Environment.PassThrough[0] != "FOO" ||
		len(r.Environment.Runtimes["claude"]) != 1 || r.Environment.Runtimes["claude"][0] != "BAR" {
		t.Fatalf("environment: %+v", r.Environment)
	}
	if state.Policy.Revision != 1 || state.Policy.Person == "" || state.Policy.Keeper == "" {
		t.Fatalf("%+v", state.Policy)
	}

	// The whole files are moved aside, so nothing reads them again (SC-001).
	for _, name := range []string{"limits.json", "workflow-limit.json", "runtime-environment.json"} {
		assertMoved(t, filepath.Join(d.SettingsDir, name))
	}
	// display.json stays (it holds other preferences too), with only its three moved keys
	// taken out.
	b, err := os.ReadFile(filepath.Join(d.SettingsDir, "display.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	json.Unmarshal(b, &fields)
	for _, key := range []string{noticeBurstKey, noticeCooldownKey, agentsMayArchiveMyChatsKey} {
		if _, ok := fields[key]; ok {
			t.Fatalf("display.json still has %s: %s", key, b)
		}
	}
	if _, ok := fields["other"]; !ok {
		t.Fatalf("display.json lost an unrelated key: %s", b)
	}
}

// TestFirstStartMoveOnlyWhenTheOldFileExists: workflow-limit.json's total only moves when
// the file is there at all (research R9).
func TestFirstStartMoveOnlyWhenTheOldFileExists(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()

	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 1, "policy/yours", nil), &state)
	if state.Policy.Rules.Workflows != nil {
		t.Fatalf("no file, but workflows moved: %+v", state.Policy.Rules.Workflows)
	}
	if state.Policy.Rules.Budgets != nil || state.Policy.Rules.NoticeLimits != nil || state.Policy.Rules.ArchiveMyChats != nil ||
		state.Policy.Rules.Environment != nil {
		t.Fatalf("nothing to move, but something moved: %+v", state.Policy.Rules)
	}
	// Permission mode, permission requests and sandbox are never moved: "unset" is already
	// no limit for them (R5, R7).
	if state.Policy.Rules.PermissionMode != nil || state.Policy.Rules.PermissionRequests != nil || state.Policy.Rules.Sandbox != nil {
		t.Fatalf("a rule that was never a personal setting got one: %+v", state.Policy.Rules)
	}
}

// TestFirstStartMoveRunsOnce: a second read does not move already-moved files again, and
// a value the person changes afterwards is not clobbered by a second move attempt.
func TestFirstStartMoveRunsOnce(t *testing.T) {
	d, c := start(t, t.TempDir())
	d.SettingsDir = t.TempDir()
	os.MkdirAll(d.SettingsDir, 0o700)
	mustWrite(t, filepath.Join(d.SettingsDir, "limits.json"), `{"daily":{"amount":40,"currency":"USD"}}`)

	var first wire.YourPolicyState
	json.Unmarshal(c.call(t, 1, "policy/yours", nil), &first)
	if first.Policy.Revision != 1 {
		t.Fatalf("%+v", first)
	}

	// The person changes it.
	var set wire.YourPolicy
	json.Unmarshal(c.call(t, 2, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{
		Budgets: &wire.PolicyRuleBudgets{Daily: &wire.Cost{Amount: 60, Currency: "USD"}},
	}, Revision: 1}), &set)
	if set.Revision != 2 || set.Rules.Budgets.Daily.Amount != 60 {
		t.Fatalf("%+v", set)
	}

	// Writing a new limits.json back (as if an old client still wrote it) does not move it
	// again and clobber what the person just set: policy-yours.json already exists.
	mustWrite(t, filepath.Join(d.SettingsDir, "limits.json"), `{"daily":{"amount":5,"currency":"USD"}}`)
	d.yoursRead = false // force a re-read, as a fresh process would do
	var again wire.YourPolicyState
	json.Unmarshal(c.call(t, 3, "policy/yours", nil), &again)
	if again.Policy.Revision != 2 || again.Policy.Rules.Budgets.Daily.Amount != 60 {
		t.Fatalf("the move ran again and clobbered the person's own change: %+v", again)
	}
}

func mustWrite(t testing.TB, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertMoved(t testing.TB, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("%s is still there: %v", path, err)
	}
	if _, err := os.Stat(path + ".moved"); err != nil {
		t.Fatalf("%s.moved is not there: %v", path, err)
	}
}

// TestAnUntrustedLayerIsKeptAsideNotWrittenOver (#3122): a layer signed with key A, read by
// a daemon whose key store is empty (the root moved to another Mac), fails the check; the
// next edit (cost/setLimits) keeps the old file, byte for byte, as
// policy-yours.json.untrusted-<time> before it writes a new layer.
func TestAnUntrustedLayerIsKeptAsideNotWrittenOver(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	d.SettingsDir = t.TempDir()

	var set wire.YourPolicy
	json.Unmarshal(c.call(t, 1, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{
		Budgets: &wire.PolicyRuleBudgets{Daily: &wire.Cost{Amount: 40, Currency: "USD"}},
	}, Revision: 1}), &set)
	if set.Revision != 2 {
		t.Fatalf("%+v", set)
	}
	signedWithA, err := os.ReadFile(filepath.Join(d.SettingsDir, yourPolicyFile))
	if err != nil {
		t.Fatal(err)
	}

	// Another Mac: key store B is empty, so the next key it makes is not A.
	if err := os.Remove(filepath.Join(root, "person-key")); err != nil {
		t.Fatal(err)
	}
	d.yoursRead = false
	d.yoursRulesCache.Store(nil)

	c.call(t, 2, "cost/setLimits", map[string]any{"daily": map[string]any{"amount": 5, "currency": "USD"}})

	aside, _ := filepath.Glob(filepath.Join(d.SettingsDir, yourPolicyFile+".untrusted-*"))
	if len(aside) != 1 {
		t.Fatalf("the untrusted layer was not kept aside: %v", aside)
	}
	kept, err := os.ReadFile(aside[0])
	if err != nil {
		t.Fatal(err)
	}
	if string(kept) != string(signedWithA) {
		t.Fatalf("the kept copy changed:\n%s\nwas\n%s", kept, signedWithA)
	}
	// The new layer is this Mac's own and is trusted again.
	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 3, "policy/yours", nil), &state)
	if b := state.Policy.Rules.Budgets; b == nil || b.Daily == nil || b.Daily.Amount != 5 {
		t.Fatalf("%+v", state.Policy.Rules)
	}
}

// untrustedLayer saves your layer with daily 40 under key A, then makes the daemon read it
// as another Mac would (#3122, #3230): key store B is empty, so the file fails the check.
func untrustedLayer(t *testing.T) (*Daemon, *conn) {
	root := t.TempDir()
	d, c := start(t, root)
	d.SettingsDir = t.TempDir()
	c.call(t, 1, "policy/setYours", wire.SetYourPolicyRequest{Rules: wire.PolicyRules{
		Budgets: &wire.PolicyRuleBudgets{Daily: &wire.Cost{Amount: 40, Currency: "USD"}},
	}, Revision: 1})
	if err := os.Remove(filepath.Join(root, "person-key")); err != nil {
		t.Fatal(err)
	}
	d.yoursRead = false
	d.yoursRulesCache.Store(nil)
	return d, c
}

// TestAnUntrustedLayerIsShownAndSignedAgain (#3230): policy/yours says an untrusted copy is
// on disk, with its rules in words; nothing applies until the person signs it again, and
// then its rules are this Mac's own layer and the copy is not shown again.
func TestAnUntrustedLayerIsShownAndSignedAgain(t *testing.T) {
	d, c := untrustedLayer(t)

	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 2, "policy/yours", nil), &state)
	u := state.Untrusted
	if u == nil || u.File != yourPolicyFile || u.Revision != 2 || len(u.Lines) != 1 || u.Lines[0].Title != "Per day" {
		t.Fatalf("untrusted: %+v", u)
	}
	if state.Policy.Rules.Budgets != nil {
		t.Fatalf("the untrusted rules apply: %+v", state.Policy.Rules)
	}

	if e := c.callError(t, 3, "policy/settleUntrustedYours", wire.SettleUntrustedYourPolicyRequest{File: "policy-yours.json.untrusted-1", Revision: 0, Sign: true}); e == nil || e.Code != wire.FailureChangedElsewhere {
		t.Fatalf("another file: %+v", e)
	}

	state = wire.YourPolicyState{}
	json.Unmarshal(c.call(t, 4, "policy/settleUntrustedYours", wire.SettleUntrustedYourPolicyRequest{File: u.File, Revision: 0, Sign: true}), &state)
	if b := state.Policy.Rules.Budgets; b == nil || b.Daily == nil || b.Daily.Amount != 40 || state.Policy.Revision != 3 {
		t.Fatalf("signed: %+v", state.Policy)
	}
	if state.Untrusted != nil {
		t.Fatalf("still shown: %+v", state.Untrusted)
	}
	settled, _ := filepath.Glob(filepath.Join(d.SettingsDir, yourPolicyFile+".untrusted-*"+settledSuffix))
	if len(settled) != 1 {
		t.Fatalf("the copy was not kept: %v", settled)
	}
	// Trusted after a restart too.
	d.yoursRead = false
	state = wire.YourPolicyState{}
	json.Unmarshal(c.call(t, 5, "policy/yours", nil), &state)
	if b := state.Policy.Rules.Budgets; b == nil || b.Daily == nil || b.Daily.Amount != 40 || state.Untrusted != nil {
		t.Fatalf("after a restart: %+v %+v", state.Policy, state.Untrusted)
	}
}

// TestAnUntrustedLayerSetAsideChangesNothing (#3230): the person says no; the rules stay
// unsigned and the copy is not shown again.
func TestAnUntrustedLayerSetAsideChangesNothing(t *testing.T) {
	d, c := untrustedLayer(t)

	var state wire.YourPolicyState
	json.Unmarshal(c.call(t, 2, "policy/yours", nil), &state)
	file := state.Untrusted.File
	state = wire.YourPolicyState{}
	json.Unmarshal(c.call(t, 3, "policy/settleUntrustedYours", wire.SettleUntrustedYourPolicyRequest{File: file, Revision: 0, Sign: false}), &state)
	if state.Untrusted != nil || state.Policy.Rules.Budgets != nil {
		t.Fatalf("%+v %+v", state.Policy, state.Untrusted)
	}
	if _, err := os.Stat(filepath.Join(d.SettingsDir, yourPolicyFile)); !os.IsNotExist(err) {
		t.Fatalf("policy-yours.json is still there: %v", err)
	}
	settled, _ := filepath.Glob(filepath.Join(d.SettingsDir, yourPolicyFile+".untrusted-*"+settledSuffix))
	if len(settled) != 1 {
		t.Fatalf("the copy was not kept: %v", settled)
	}
}
