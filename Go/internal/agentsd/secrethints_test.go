package agentsd

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4158: the last 4 only for a value of 16 characters or more, and a card's is the last 4 of
// its number.
func TestSecretHint(t *testing.T) {
	t.Parallel()
	card := wire.UserSecretKindCard
	for _, c := range []struct {
		value string
		kind  *wire.UserSecretKind
		want  string
	}{
		{"1234", nil, ""},
		{"hunter2", nil, ""},
		{"fifteen-chars-x", nil, ""},
		{"sixteen-chars-xY", nil, "s-xY"},
		{"ghp_0123456789abcdefQ7zX", nil, "Q7zX"},
		{"ключ-из-шестнадцати", nil, "цати"},
		{`{"number":"4111 1111 1111 1234","expiry":"12/30","cvc":"123","name":"A","zip":"94110"}`, &card, "1234"},
		{`{"number":"123","cvc":"999"}`, &card, ""},
		{"not json", &card, ""},
	} {
		if got := secretHint(c.value, c.kind); got != c.want {
			t.Errorf("secretHint(%q) = %q, want %q", c.value, got, c.want)
		}
	}
}

// A session's secret has its hint, when it was first set, its last operation, and is never
// backed up (#4158); a new value keeps created and changes the hint.
func TestSessionSecretRowInfo(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	var list wire.SessionSecrets
	json.Unmarshal(c.call(t, 1, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "GITLAB_TOKEN", "value": "glpat-0123456789abWXYZ"}), &list)
	if len(list.Secrets) != 1 {
		t.Fatalf("%+v", list)
	}
	first := list.Secrets[0]
	if first.Hint == nil || *first.Hint != "WXYZ" || first.Created == nil || first.BackedUp == nil || *first.BackedUp ||
		first.LastOp == nil || first.LastOp.What != wire.SecretOperationWhatAdded {
		t.Fatalf("%+v", first)
	}
	list = wire.SessionSecrets{}
	json.Unmarshal(c.call(t, 2, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "GITLAB_TOKEN", "value": "short"}), &list)
	r := list.Secrets[0]
	if r.Hint != nil || r.Created == nil || *r.Created != *first.Created || r.LastOp == nil || r.LastOp.What != wire.SecretOperationWhatReplaced {
		t.Fatalf("%+v", r)
	}
}

// A machine works out the hint when it opens its copy, keeps it beside the copy for that
// version, and sends it with what it holds; an older version sent back keeps the hint (#4158).
func TestAMachineKeepsTheHintOfItsCopy(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	_, public := machineKeys(t, root)
	d, _ := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	sent := wire.MachineUserSettings{User: "sam", Secrets: []wire.SealedUserSecret{
		sealedSecret(t, public, "sam", "GITHUB_TOKEN", 2, "ghp_0123456789abcdefQ7zX"),
		sealedSecret(t, public, "sam", "PIN", 1, "1234")}}
	if err := d.ApplyUserSettings(sent); err != nil {
		t.Fatal(err)
	}
	held := func() map[string]wire.MachineSecretHeld {
		out := map[string]wire.MachineSecretHeld{}
		for _, h := range d.secretsHeld() {
			out[string(h.Name)] = h
		}
		return out
	}
	h := held()
	if g := h["GITHUB_TOKEN"]; g.Hint == nil || *g.Hint != "Q7zX" || g.Version == nil || *g.Version != 2 {
		t.Fatalf("%+v", g)
	}
	if p, ok := h["PIN"]; !ok || p.Hint != nil {
		t.Fatalf("%+v", p)
	}
	if info, err := os.Stat(secretHintsPath(home)); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal(info, err)
	}
	sent.Secrets = []wire.SealedUserSecret{sealedSecret(t, public, "sam", "GITHUB_TOKEN", 1, "an-old-value-that-is-long")}
	d.ApplyUserSettings(sent)
	if g := held()["GITHUB_TOKEN"]; g.Hint == nil || *g.Hint != "Q7zX" {
		t.Fatalf("%+v", g)
	}
	sent.Secrets = nil
	d.ApplyUserSettings(sent)
	if len(held()) != 0 {
		t.Fatal(held())
	}
	if _, err := os.Stat(secretHintsPath(home)); !os.IsNotExist(err) {
		t.Fatal("a removed secret's hint stayed", err)
	}
}
