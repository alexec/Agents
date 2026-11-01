package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A folder's own layer, .agents/policy.json (#2957, T023): written in a stable order; a
// change from outside the app that only tightens applies at once; one that loosens waits,
// with the guarded-file actions .agents/folder.json's guard already has; an invalid file is
// pending with the reason; an unknown rule is ignored; a folder value looser than the
// person's effective value is kept, not used.

func readPolicyJSON(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, folderPolicyFile))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestSetFolderPolicyWritesAStableOrder covers FR-014: only the rules the folder sets,
// sorted keys, two-space indents, a trailing newline.
func TestSetFolderPolicyWritesAStableOrder(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	running := int64(2)
	rules := wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &running}}
	var got wire.PolicyRules
	json.Unmarshal(c.call(t, 2, "policy/setFolder", map[string]any{"folder": store.FolderURL(dir), "rules": rules}), &got)
	if got.Helpers == nil || got.Helpers.MostRunning == nil || *got.Helpers.MostRunning != 2 {
		t.Fatalf("%+v", got)
	}
	text := readPolicyJSON(t, dir)
	if text != "{\n  \"helpers\": {\n    \"mostRunning\": 2\n  }\n}\n" {
		t.Fatalf("%q", text)
	}
	// Written again with a second rule: the keys stay sorted (archiveMyChats before helpers).
	off := false
	rules.ArchiveMyChats = &off
	c.call(t, 3, "policy/setFolder", map[string]any{"folder": store.FolderURL(dir), "rules": rules})
	text = readPolicyJSON(t, dir)
	if !strings.HasPrefix(text, "{\n  \"archiveMyChats\": false,\n  \"helpers\": {") {
		t.Fatalf("%q", text)
	}
}

// TestAFolderPolicyThatOnlyTightensAppliesAtOnce covers research R10's fast path.
func TestAFolderPolicyThatOnlyTightensAppliesAtOnce(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	running := int64(5)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": store.FolderURL(dir),
		"rules": wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &running}}})
	// From outside the app, tighter: 5 -> 2.
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`{"helpers":{"mostRunning":2}}`), 0o644)
	var state wire.PolicyFolderState
	json.Unmarshal(c.call(t, 3, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending != nil {
		t.Fatalf("a tighter change is pending: %+v", state.Pending)
	}
	if state.Rules.Helpers == nil || state.Rules.Helpers.MostRunning == nil || *state.Rules.Helpers.MostRunning != 2 {
		t.Fatalf("the tighter change was not applied: %+v", state.Rules)
	}
}

// TestAFolderPolicyThatLoosensWaits covers research R10: a looser change waits, the last
// approved copy applies, and the guarded-file actions (readGuardedChange, keepGuardedChange,
// undoGuardedChange) behave as .agents/folder.json's guard does (#502).
func TestAFolderPolicyThatLoosensWaits(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	running := int64(2)
	c.call(t, 2, "policy/setFolder", map[string]any{"folder": store.FolderURL(dir),
		"rules": wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &running}}})
	approved := readPolicyJSON(t, dir)
	// From outside the app, looser: 2 -> 5.
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`{"helpers":{"mostRunning":5}}`), 0o644)
	var state wire.PolicyFolderState
	json.Unmarshal(c.call(t, 3, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending == nil {
		t.Fatal("a looser change did not wait")
	}
	if state.Rules.Helpers == nil || *state.Rules.Helpers.MostRunning != 2 {
		t.Fatalf("the last approved copy did not apply: %+v", state.Rules)
	}
	// The guarded-file actions behave as any other guarded file's do.
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 4, "folders/readGuardedChange", map[string]any{"folder": store.FolderURL(dir), "path": folderPolicyFile}), &reading)
	if reading.Approved == nil || *reading.Approved != approved || reading.Current == nil {
		t.Fatalf("%+v", reading)
	}
	c.call(t, 5, "folders/keepGuardedChange", map[string]any{"folder": store.FolderURL(dir), "path": folderPolicyFile, "digest": reading.Digest})
	state = wire.PolicyFolderState{}
	json.Unmarshal(c.call(t, 6, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending != nil || state.Rules.Helpers == nil || *state.Rules.Helpers.MostRunning != 5 {
		t.Fatalf("Allow did not keep the looser change: %+v", state)
	}
}

// TestAnInvalidFolderPolicyIsPendingWithTheReason: not JSON, or a value out of range.
func TestAnInvalidFolderPolicyIsPendingWithTheReason(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`not json`), 0o644)
	var state wire.PolicyFolderState
	json.Unmarshal(c.call(t, 2, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending == nil || state.Invalid == nil || *state.Invalid == "" {
		t.Fatalf("%+v", state)
	}
	// Out of range: helpers.mostRunning is 1-10.
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`{"helpers":{"mostRunning":5000}}`), 0o644)
	// A fresh guarded state for this test's second file (the previous one is still pending
	// for digest reasons; approve it first, as the person would).
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 3, "folders/readGuardedChange", map[string]any{"folder": store.FolderURL(dir), "path": folderPolicyFile}), &reading)
	c.call(t, 4, "folders/undoGuardedChange", map[string]any{"folder": store.FolderURL(dir), "path": folderPolicyFile, "digest": reading.Digest})
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`{"helpers":{"mostRunning":5000}}`), 0o644)
	json.Unmarshal(c.call(t, 5, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending == nil || state.Invalid == nil || *state.Invalid == "" {
		t.Fatalf("%+v", state)
	}
}

// TestAnUnknownFolderRuleIsIgnored: a newer file's field still lets an older machine apply
// the rules it knows (policylayers.Validate's own behaviour, exercised through the folder
// layer).
func TestAnUnknownFolderRuleIsIgnored(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.WriteFile(filepath.Join(dir, folderPolicyFile), []byte(`{"helpers":{"mostRunning":2},"somethingNew":true}`), 0o644)
	var state wire.PolicyFolderState
	json.Unmarshal(c.call(t, 2, "policy/folder", map[string]any{"folder": store.FolderURL(dir)}), &state)
	if state.Pending != nil {
		t.Fatalf("an unknown field made it pending: %+v", state)
	}
	if state.Rules.Helpers == nil || *state.Rules.Helpers.MostRunning != 2 {
		t.Fatalf("the known rule was not read: %+v", state.Rules)
	}
}

// TestAFolderValueLooserThanYoursIsKept covers US3 scenario 6: the folder's own choice is
// kept in .agents/policy.json, but your tighter layer decides the effective value.
func TestAFolderValueLooserThanYoursIsKept(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	var yours wire.YourPolicyState
	json.Unmarshal(c.call(t, 2, "policy/yours", map[string]any{}), &yours)
	tight := int64(2)
	c.call(t, 3, "policy/setYours", map[string]any{"rules": wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &tight}}, "revision": yours.Policy.Revision})
	loose := int64(8)
	c.call(t, 4, "policy/setFolder", map[string]any{"folder": store.FolderURL(dir),
		"rules": wire.PolicyRules{Helpers: &wire.PolicyHelpers{MostRunning: &loose}}})
	// The folder's own file still says 8: nothing here rewrites what the person chose there.
	if text := readPolicyJSON(t, dir); !strings.Contains(text, "8") {
		t.Fatalf("the folder's own choice was not kept on disk: %q", text)
	}
	eff := d.effective(dir)
	r := effectiveRule(eff, wire.PolicyRuleNameHelpersMostRunning)
	if r == nil || r.Decides == nil || r.Decides.Kind != "you" {
		t.Fatalf("your tighter layer should decide: %+v", r)
	}
	for _, l := range r.Layers {
		if l.Layer.Kind == "folder" && !l.Kept {
			t.Fatalf("the folder's looser value should be kept, not used: %+v", l)
		}
	}
	// The effective helper limit in force is the tighter one.
	if running, _, _ := d.helperLimitsIn(dir); running != 2 {
		t.Fatalf("helperLimitsIn did not use the tighter effective value: %d", running)
	}
}
