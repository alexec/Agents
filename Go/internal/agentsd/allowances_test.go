package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Ports RuntimeAllowanceTests for a server: every runtime's own row, the Mac's shared
// sign-ins taken when newer, and marking one available.

func TestAllowancesOnAServer(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var accounts []wire.RuntimeAccount
	json.Unmarshal(c.call(t, 1, "runtimes/accounts", nil), &accounts)
	if len(accounts) != len(catalog) || accounts[0].State != wire.RuntimeAccountStateUnknown {
		t.Fatalf("%+v", accounts)
	}
	var al wire.RuntimeAllowances
	json.Unmarshal(c.call(t, 2, "runtimes/allowances", nil), &al)
	if len(al.Rows) != len(catalog) || al.Rows[0].State.Status.Available == nil {
		t.Fatalf("%+v", al)
	}
	out := availableState("claude:sign-in")
	until := wire.DateOf(time.Now().Add(time.Hour))
	out.Status = wire.AllowanceStateStatus{Out: &wire.AllowanceStateStatusOut{Until: &until, Why: "allowanceSpent"}}
	var changed bool
	json.Unmarshal(c.call(t, 3, "pool/applyAllowances", map[string]any{"states": []any{out}}), &changed)
	if !changed {
		t.Fatal("not taken")
	}
	b, _ := os.ReadFile(filepath.Join(root, "allowances.json"))
	if !strings.Contains(string(b), `"credentialKey":"claude:sign-in"`) {
		t.Fatalf("%s", b)
	}
	json.Unmarshal(c.call(t, 4, "pool/applyAllowances", map[string]any{"states": []any{out}}), &changed)
	if changed {
		t.Fatal("the same state taken twice")
	}
	al = wire.RuntimeAllowances{}
	json.Unmarshal(c.call(t, 5, "runtimes/markAvailable", map[string]any{"credentialKey": "claude:sign-in"}), &al)
	for _, r := range al.Rows {
		if r.CredentialKey == "claude:sign-in" && r.State.Status.Available == nil {
			t.Fatalf("%+v", r)
		}
	}
	if len(al.Shared) != 1 {
		t.Fatalf("%+v", al.Shared)
	}
}

// An allowance broadcast locates each runtime once, whatever the number of added accounts,
// starts one login shell a minute at most, and reads an account's sign-in file only when it
// changed (#2251).
func TestAllowancesLocateOnceAndReadSignInOnce(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	var shells, located atomic.Int64
	oldShell := loginShellPath
	loginShellPath = func(string) []string { shells.Add(1); return []string{"/nowhere"} }
	shellPath.Lock()
	shellPath.key = ""
	shellPath.Unlock()
	oldLocate := locateFor
	locateFor = func(r *runtimeDef) (string, []string, []string) { located.Add(1); return oldLocate(r) }
	t.Cleanup(func() { loginShellPath, locateFor = oldShell, oldLocate })

	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var folders []string
	for i, name := range []string{"One", "Two", "Three"} {
		var p wire.AccountProfile
		json.Unmarshal(c.call(t, i+1, "runtimes/addAccount", map[string]any{"runtimeID": "claude", "name": name}), &p)
		folders = append(folders, accountFolder(p))
		os.WriteFile(filepath.Join(accountFolder(p), ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"a@example.com"}}`), 0o600)
	}

	d.runtimeAllowances()
	shells.Store(0)
	located.Store(0)
	reads := d.signIns.reads.Load()
	out := d.runtimeAllowances()
	if n := located.Load(); n != int64(len(catalog)) {
		t.Fatalf("located %d times for %d runtimes and 3 accounts", n, len(catalog))
	}
	if n := shells.Load(); n != 0 {
		t.Fatalf("%d login shells within a minute of the last", n)
	}
	if n := d.signIns.reads.Load() - reads; n != 0 {
		t.Fatalf("read %d unchanged sign-in files", n)
	}
	accounts := 0
	for _, r := range out.Rows {
		if r.AccountID != nil {
			accounts++
		}
	}
	if accounts != 3 {
		t.Fatalf("%d account rows: %+v", accounts, out.Rows)
	}

	// A changed file is read again, and says what it says now.
	os.WriteFile(filepath.Join(folders[0], ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"someone.else@example.com"}}`), 0o600)
	reads = d.signIns.reads.Load()
	for _, p := range d.accountProfiles() {
		if accountFolder(p) == folders[0] && (p.SignedInAs == nil || *p.SignedInAs != "someone.else@example.com") {
			t.Fatalf("%+v", p)
		}
	}
	if n := d.signIns.reads.Load() - reads; n != 1 {
		t.Fatalf("read %d files for one change", n)
	}

	// After a minute, the login shell runs again, once.
	shellPath.Lock()
	shellPath.at = time.Now().Add(-shellPathTTL)
	shellPath.Unlock()
	searchPaths()
	searchPaths()
	if n := shells.Load(); n != 1 {
		t.Fatalf("%d login shells after a minute", n)
	}
}

// The sign-in cache is bounded: it never holds more than signInCacheSize files.
func TestSignInCacheBounded(t *testing.T) {
	dir := t.TempDir()
	var c signInCache
	for i := range signInCacheSize + 10 {
		path := filepath.Join(dir, strconv.Itoa(i))
		os.WriteFile(path, []byte("{}"), 0o600)
		c.read(path, func([]byte) signIn { return signIn{signedIn: true} })
		c.Lock()
		n := len(c.m)
		c.Unlock()
		if n > signInCacheSize {
			t.Fatalf("%d entries", n)
		}
	}
}
