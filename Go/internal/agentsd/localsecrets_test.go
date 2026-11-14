package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #5122: a secret an agent saved on this machine (here capture_secret's save) is in
// secrets/localList with Ask before use on, a person turns it off there, and the person's
// own secrets and every value stay out of the list.
func TestLocalSecretsListsWhatAnAgentSaved(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	const value = "ghp_0123456789abcdefghijklmnop"
	if err := d.saveSecret("GITHUB_SAM_TOKEN", value, true); err != nil {
		t.Fatal(err)
	}
	if err := setSecretDescription(home, "GITHUB_SAM_TOKEN", "The demo account's classic token."); err != nil {
		t.Fatal(err)
	}
	// A secret of the person's (Settings ▸ You ▸ Secrets), as the sync keeps it.
	if err := d.saveSealedSecret(home, "PERSONS_TOKEN", "the-persons-value", sealedFromUser, true); err != nil {
		t.Fatal(err)
	}

	list := func(id int) wire.LocalSecrets {
		t.Helper()
		raw := c.call(t, id, wire.CallSecretsLocalList.Name, map[string]any{})
		if strings.Contains(string(raw), value) || strings.Contains(string(raw), "the-persons-value") {
			t.Fatalf("a value is in the list: %s", raw)
		}
		var out wire.LocalSecrets
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	got := list(1)
	if len(got.Secrets) != 1 {
		t.Fatalf("%+v", got)
	}
	row := got.Secrets[0]
	if row.Name != "GITHUB_SAM_TOKEN" || row.NeedsApproval == nil || !*row.NeedsApproval ||
		row.Description == nil || *row.Description != "The demo account's classic token." ||
		row.BackedUp == nil || *row.BackedUp || row.SetAt == 0 {
		t.Fatalf("%+v", row)
	}

	c.call(t, 2, wire.CallSecretsSetNeedsApproval.Name, map[string]any{"name": "GITHUB_SAM_TOKEN", "needsApproval": false})
	if after := list(3); len(after.Secrets) != 1 || after.Secrets[0].NeedsApproval != nil {
		t.Fatalf("Ask before use is still on: %+v", after)
	}
	if v, ok := d.plainSecrets(home).Value("GITHUB_SAM_TOKEN"); !ok || v != value {
		t.Fatal("the secret does not read without Ask before use")
	}
	if RoleAgent.Allows(wire.CallSecretsLocalList.Name) || RoleStranger.Allows(wire.CallSecretsLocalList.Name) {
		t.Fatal("an agent's or a stranger's connection may list this machine's secrets")
	}
}
