package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #4014: a secret an agent asks for is saved with Ask before use. Its value is in no file as
// plain text, not in the agent's environment or its MCP servers, and the agent is told no
// path to read; agentsd itself still opens it for fill_secret.
func TestAnAgentsSecretIsSealed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	const value = "sk-4014-sealed-not-real"
	for i, sessionOnly := range []bool{false, true} {
		name := []string{"SHOP_PASSWORD", "SHOP_PIN_CODE"}[i]
		answered := make(chan string, 1)
		go func() {
			text, _ := m.tool(10+i, "ask_secret", map[string]any{"name": name, "reason": "To sign in."})
			answered <- text
		}()
		var pending []wire.ElicitationRequest
		waitFor(t, "the card", func() bool {
			json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
			return len(pending) == 1
		})
		c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept",
			"content": map[string]any{"value": value, "sessionOnly": sessionOnly}})
		text := <-answered
		if !strings.HasPrefix(text, name+" is saved with Ask before use") || strings.Contains(text, value) ||
			strings.Contains(text, home) || strings.Contains(text, "sed ") {
			t.Fatal(text)
		}
		args := map[string]json.RawMessage{"secret": mustJSON(name), "target": json.RawMessage(`"e1"`)}
		if fill, refusal := d.fillSecretValue(a.ID, args); refusal != "" || fill.value != value {
			t.Fatalf("%s: %q %q", name, fill.value, refusal)
		}
	}
	if skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).IsSet("SHOP_PASSWORD") {
		t.Fatal("a flagged secret is in secrets.env")
	}
	if env := d.sessionSecretEnv(a.ID); len(env) != 0 {
		t.Fatalf("a flagged secret is in the environment: %v", env)
	}
	os.MkdirAll(filepath.Join(home, ".agents"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"),
		[]byte(`{"mcpServers":{"shop":{"command":"shop-mcp","env":{"A":"${SHOP_PASSWORD}","B":"${SHOP_PIN_CODE}"}}}}`), 0o600)
	for _, e := range d.sessionEntries(folderPath(&a), a.ID) {
		if b, _ := json.Marshal(e.server); strings.Contains(string(b), value) {
			t.Fatalf("a flagged secret is in a stdio MCP server: %s", b)
		}
	}
	var list wire.SessionSecrets
	json.Unmarshal(c.call(t, 3, "secrets/sessionList", map[string]any{}), &list)
	if len(list.Secrets) != 1 || list.Secrets[0].NeedsApproval == nil || !*list.Secrets[0].NeedsApproval {
		t.Fatalf("%+v", list)
	}
	if info, err := os.Stat(sealedSecretsPath(home)); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", info, err)
	}
	assertNotUnder(t, home, value)
	assertNotUnder(t, root, value)
}

// #4014: an agent's write turns the flag on, also over a plain value a person set, and no
// agent's connection reaches a way to turn it off.
func TestAnAgentCannotClearTheFlag(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	if err := d.saveSecret("GITLAB_PASSWORD", "the-persons", false); err != nil {
		t.Fatal(err)
	}
	// generate_secret's save, as an agent's.
	if err := d.saveSecret("GITLAB_PASSWORD", "an-agents", true); err != nil {
		t.Fatal(err)
	}
	if d.plainSecrets(home).IsSet("GITLAB_PASSWORD") || !isSealedSecret(home, "GITLAB_PASSWORD") {
		t.Fatal("an agent's write left the flag off")
	}
	for _, method := range []string{wire.CallSecretsSetNeedsApproval.Name, wire.CallMCPSetSecret.Name, wire.CallSecretsSessionSet.Name} {
		if RoleAgent.Allows(method) {
			t.Errorf("an agent's connection may call %s", method)
		}
	}
	if askBeforeUseAllowed(&Client{Role: RoleAgent}) || askBeforeUseAllowed(&Client{Role: RoleStranger}) ||
		!askBeforeUseAllowed(&Client{Role: RoleControl}) || !askBeforeUseAllowed(&Client{Role: RoleDevice}) {
		t.Fatal("the wrong roles choose the flag")
	}
	helper := &Client{Role: RoleAgent, conn: newConn(), d: d}
	d.dispatch(helper, message{JSONRPC: "2.0", Method: wire.CallSecretsSetNeedsApproval.Name, ID: json.RawMessage(`1`),
		Params: json.RawMessage(`{"name":"GITLAB_PASSWORD","needsApproval":false}`)})
	d.dispatch(helper, message{JSONRPC: "2.0", Method: wire.CallMCPSetSecret.Name, ID: json.RawMessage(`2`),
		Params: json.RawMessage(`{"name":"GITLAB_PASSWORD","value":"x","needsApproval":false}`)})
	if d.plainSecrets(home).IsSet("GITLAB_PASSWORD") || !isSealedSecret(home, "GITLAB_PASSWORD") {
		t.Fatal("an agent's connection turned the flag off")
	}
	// A person's client turns it off, which puts the plain line back, and on again.
	c.call(t, 1, wire.CallSecretsSetNeedsApproval.Name, map[string]any{"name": "GITLAB_PASSWORD", "needsApproval": false})
	if v, _ := d.plainSecrets(home).Value("GITLAB_PASSWORD"); v != "an-agents" || isSealedSecret(home, "GITLAB_PASSWORD") {
		t.Fatalf("off: %q", v)
	}
	c.call(t, 2, wire.CallSecretsSetNeedsApproval.Name, map[string]any{"name": "GITLAB_PASSWORD", "needsApproval": true})
	if d.plainSecrets(home).IsSet("GITLAB_PASSWORD") || !isSealedSecret(home, "GITLAB_PASSWORD") {
		t.Fatal("on: still plain")
	}
	assertNotUnder(t, home, "an-agents")
}

// #4014: a sealed record changed by hand, its grants or its name, does not open; nor does
// another machine's.
func TestAChangedSealedRecordDoesNotOpen(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	root := t.TempDir()
	d, _ := start(t, root)
	defer d.Shutdown()
	if err := d.saveSecret("GITLAB_PASSWORD", "sealed-value", true); err != nil {
		t.Fatal(err)
	}
	if v, ok := d.sealedLocalSecret(home, "GITLAB_PASSWORD"); !ok || v != "sealed-value" {
		t.Fatalf("%q", v)
	}
	f := readSealedSecrets(home)
	s := f.Secrets["GITLAB_PASSWORD"]
	s.Grants = []string{"github.com"}
	f.Secrets["GITLAB_PASSWORD"] = s
	f.Secrets["OTHER_NAME"] = s
	writeSealedSecrets(home, f)
	if _, ok := d.sealedLocalSecret(home, "GITLAB_PASSWORD"); ok {
		t.Fatal("a grant added by hand opened")
	}
	if _, ok := d.sealedLocalSecret(home, "OTHER_NAME"); ok {
		t.Fatal("a record moved to another name opened")
	}
	if err := d.saveSecret("GITLAB_PASSWORD", "sealed-value", true); err != nil {
		t.Fatal(err)
	}
	other, _ := start(t, t.TempDir())
	defer other.Shutdown()
	if _, ok := other.sealedLocalSecret(home, "GITLAB_PASSWORD"); ok {
		t.Fatal("another machine's key opened it")
	}
}

// #4014: the flag of a secret of the person's (Settings ▸ You ▸ Secrets) is bound into each envelope's associated data. Flagged, it is
// sealed here and not in secrets.env; a flag the control plane changed either way does not
// open; turned off by the person's client, it goes back to secrets.env.
func TestYourSetupsFlagIsSealed(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	_, public := machineKeys(t, root)
	d, c := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	send := func(secrets ...wire.SealedUserSecret) {
		d.Told(wire.NotifyMachineUserSettings.Name, mustJSON(wire.MachineUserSettings{User: "sam", Secrets: secrets}))
	}
	send(flaggedSecret(t, public, "sam", "GITHUB_TOKEN", 1, "ghp_flagged", true))
	if d.plainSecrets(home).IsSet("GITHUB_TOKEN") {
		t.Fatal("a flagged secret of the person's is read as plain")
	}
	if v, ok, _ := d.localSecret("", "GITHUB_TOKEN"); !ok || v != "ghp_flagged" {
		t.Fatalf("%q", v)
	}
	assertNotUnder(t, home, "ghp_flagged")
	assertNotUnder(t, root, "ghp_flagged")
	// Only the client turns it off: not secrets/setNeedsApproval.
	if e := c.callError(t, 1, wire.CallSecretsSetNeedsApproval.Name, map[string]any{"name": "GITHUB_TOKEN", "needsApproval": false}); e == nil ||
		!strings.Contains(e.Message, "Settings ▸ You ▸ Secrets") {
		t.Fatalf("%+v", e)
	}

	// The control plane turns the flag off, or on: neither opens, so neither is used.
	off := flaggedSecret(t, public, "sam", "GITHUB_TOKEN", 2, "ghp_unflagged_by_cp", true)
	off.NeedsApproval = nil
	send(off)
	on := flaggedSecret(t, public, "sam", "GITHUB_TOKEN", 3, "ghp_flagged_by_cp", false)
	on.NeedsApproval = new(true)
	send(on)
	if d.plainSecrets(home).IsSet("GITHUB_TOKEN") {
		t.Fatal("a flag the control plane turned off opened")
	}
	if v, _, _ := d.localSecret("", "GITHUB_TOKEN"); v == "ghp_flagged_by_cp" {
		t.Fatal("a flag the control plane turned on opened")
	}

	// The person's client seals it with the flag off: a plain record, no longer flagged.
	send(flaggedSecret(t, public, "sam", "GITHUB_TOKEN", 4, "ghp_plain", false))
	if v, _ := d.plainSecrets(home).Value("GITHUB_TOKEN"); v != "ghp_plain" || isSealedSecret(home, "GITHUB_TOKEN") {
		t.Fatalf("%q", v)
	}
	// Flagged again, then removed: gone from both.
	send(flaggedSecret(t, public, "sam", "GITHUB_TOKEN", 5, "ghp_flagged_again", true))
	if d.plainSecrets(home).IsSet("GITHUB_TOKEN") || !isSealedSecret(home, "GITHUB_TOKEN") {
		t.Fatal("flagged again")
	}
	send()
	if d.plainSecrets(home).IsSet("GITHUB_TOKEN") || isSealedSecret(home, "GITHUB_TOKEN") {
		t.Fatal("a removed secret stayed")
	}
}

// flaggedSecret is sealedSecret with Ask before use as the client seals it (#4014).
func flaggedSecret(t *testing.T, public []byte, user, name string, version int64, value string, ask bool) wire.SealedUserSecret {
	t.Helper()
	ad := controllink.UserSecretADAsk(user, controllink.MachineRecipient(orgTestHost), name, version, ask)
	e, err := controllink.Seal(public, controllink.UserSecretPurpose, ad, []byte(value))
	if err != nil {
		t.Fatal(err)
	}
	s := wire.SealedUserSecret{Name: wire.UserSecretName(name), Version: version, Sealed: e}
	if ask {
		s.NeedsApproval = new(true)
	}
	return s
}
