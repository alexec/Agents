package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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
