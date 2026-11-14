package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A secret for this session only (#3548): set on the ask_secret card, it is the asking
// session's alone, never in secrets.env, and gone when the session is archived; then its
// agent is told it expired.
func TestASecretForThisSessionOnly(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	title := "Sign up to the shop"
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason, a.Title = wire.AgentStateRunning, nil, &title })
	other := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(2, "ask_secret", map[string]any{"name": "SHOP_PASSWORD", "reason": "To sign in to the shop."})
		answered <- text
	}()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if s := pending[0].Secret; s == nil || s.CanBeSessionOnly == nil || !*s.CanBeSessionOnly || s.CanAskBeforeUse == nil || !*s.CanAskBeforeUse {
		t.Fatalf("%+v", pending[0].Secret)
	}
	const value = "hunter2-3548-not-real"
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept",
		"content": map[string]any{"value": value, "sessionOnly": true, "needsApproval": false}})
	text := <-answered
	if !strings.HasPrefix(text, "SHOP_PASSWORD is kept for this session only") || strings.Contains(text, value) {
		t.Fatal(text)
	}
	if skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).IsSet("SHOP_PASSWORD") {
		t.Fatal("a secret for this session only is in secrets.env")
	}
	waitFor(t, "the answer on the record", func() bool {
		entries, _, _ := d.Store.Transcript(a.ID, 0)
		for _, e := range entries {
			if ans := e.Kind.ElicitationAnswered; ans != nil && ans.ID == pending[0].ID {
				return slices.Equal(ans.Answers, []wire.ElicitationAnswer{{Question: "SHOP_PASSWORD", Answer: "Saved for this session only"}})
			}
		}
		return false
	})
	info, err := os.Stat(d.sessionSecretsPath(a.ID))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", info, err)
	}

	// Its own session's agent fills it, has it in its environment and its MCP servers; no other does.
	args := map[string]json.RawMessage{"secret": json.RawMessage(`"SHOP_PASSWORD"`), "target": json.RawMessage(`"e1"`)}
	if fill, refusal := d.fillSecretValue(a.ID, args); refusal != "" || fill.value != value {
		t.Fatalf("%q %q", fill.value, refusal)
	}
	if _, refusal := d.fillSecretValue(other.ID, args); !strings.HasPrefix(refusal, "SHOP_PASSWORD is not set.") {
		t.Fatal(refusal)
	}
	if env := d.sessionSecretEnv(a.ID); !slices.Equal(env, []string{"SHOP_PASSWORD=" + value}) {
		t.Fatal(env)
	}
	if env := d.sessionSecretEnv(other.ID); len(env) != 0 {
		t.Fatal(env)
	}
	os.MkdirAll(filepath.Join(home, ".agents"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"),
		[]byte(`{"mcpServers":{"shop":{"command":"shop-mcp","env":{"SHOP_PASSWORD":"${SHOP_PASSWORD}"}}}}`), 0o600)
	servers := func(e []sessionEntry) string {
		var out []any
		for _, each := range e {
			out = append(out, each.server)
		}
		b, _ := json.Marshal(out)
		return string(b)
	}
	if b := servers(d.sessionEntries(folderPath(&a), a.ID)); !strings.Contains(b, value) {
		t.Fatalf("its MCP server has no value: %s", b)
	}
	if b := servers(d.sessionEntries(folderPath(&other), other.ID)); strings.Contains(b, value) {
		t.Fatalf("another session's MCP server has it: %s", b)
	}

	// Settings ▸ Secrets lists it with its session, never its value.
	var list wire.SessionSecrets
	raw := c.call(t, 3, "secrets/sessionList", map[string]any{})
	json.Unmarshal(raw, &list)
	if len(list.Secrets) != 1 || list.Secrets[0].Name != "SHOP_PASSWORD" || list.Secrets[0].AgentID != a.ID ||
		list.Secrets[0].Title != title || strings.Contains(string(raw), value) {
		t.Fatalf("%s", raw)
	}

	// Archived: the value is gone from every file, and the agent is told it expired.
	if err := d.archive(a.ID); err != nil {
		t.Fatal(err)
	}
	if _, refusal := d.fillSecretValue(a.ID, args); !strings.Contains(refusal, "was for this session only and has expired") {
		t.Fatal(refusal)
	}
	if env := d.sessionSecretEnv(a.ID); len(env) != 0 {
		t.Fatal(env)
	}
	assertNotUnder(t, home, value)
	assertNotUnder(t, root, value)
	json.Unmarshal(c.call(t, 4, "secrets/sessionList", map[string]any{}), &list)
	if len(list.Secrets) != 0 {
		t.Fatalf("%+v", list)
	}
	// A secret in secrets.env of the same name is the person's own, and still fills.
	env := skillcatalog.Secrets{}
	env.Set("SHOP_PASSWORD", "the-persons-own")
	env.Save(skillcatalog.SecretsPath(home))
	if fill, refusal := d.fillSecretValue(a.ID, args); refusal != "" || fill.value != "the-persons-own" {
		t.Fatalf("%q %q", fill.value, refusal)
	}
}

// Settings ▸ Secrets sets one for a session, and takes it out again; deleting the session
// takes its file, names and all.
func TestSessionSecretsFromSettings(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	var list wire.SessionSecrets
	json.Unmarshal(c.call(t, 1, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "GITLAB_TOKEN", "value": " glpat-3548 "}), &list)
	if len(list.Secrets) != 1 || list.Secrets[0].Name != "GITLAB_TOKEN" || list.Secrets[0].Title != "Untitled session" {
		t.Fatalf("%+v", list)
	}
	if v, ok, _ := d.sessionSecret(a.ID, "GITLAB_TOKEN"); !ok || v != "glpat-3548" {
		t.Fatal(v)
	}
	if e := c.callError(t, 2, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "A B", "value": "x"}); e == nil {
		t.Fatal("a name with a space was taken")
	}
	if e := c.callError(t, 3, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "TWO", "value": "a\nb"}); e == nil {
		t.Fatal("two lines were taken")
	}
	json.Unmarshal(c.call(t, 4, "secrets/sessionRemove", map[string]any{"agentID": a.ID, "name": "GITLAB_TOKEN"}), &list)
	if len(list.Secrets) != 0 {
		t.Fatalf("%+v", list)
	}
	if _, _, expired := d.sessionSecret(a.ID, "GITLAB_TOKEN"); !expired {
		t.Fatal("a removed secret does not say it expired")
	}
	assertNotUnder(t, home, "glpat-3548")

	// An archived session takes none.
	c.call(t, 5, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "GITLAB_TOKEN", "value": "glpat-again"})
	d.archive(a.ID)
	if e := c.callError(t, 6, "secrets/sessionSet", map[string]any{"agentID": a.ID, "name": "X_TOKEN", "value": "x-value"}); e == nil ||
		!strings.Contains(e.Message, "is archived") {
		t.Fatalf("%+v", e)
	}
	assertNotUnder(t, home, "glpat-again")
	archived := d.Store.Agent(a.ID)
	if err := d.deleteArchived(archived, "person"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.sessionSecretsPath(a.ID)); !os.IsNotExist(err) {
		t.Fatalf("the file outlived its session: %v", err)
	}
}

// A session archived while the host was not running loses its secrets at the next start.
func TestSessionSecretsAreSweptAtStart(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) {
		by := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedReason = wire.AgentStateArchived, &by
	})
	gone := wire.UUID("0b0e5a1c-1111-4222-8333-944455556666")
	f := sessionSecretFile{Secrets: map[string]sessionSecretValue{"PIN_CODE": {Value: "swept-3548", SetAt: now()}}}
	d.writeSessionSecretsLocked(a.ID, f)
	d.writeSessionSecretsLocked(gone, f)
	d.sweepSessionSecrets()
	assertNotUnder(t, home, "swept-3548")
	if _, _, expired := d.sessionSecret(a.ID, "PIN_CODE"); !expired {
		t.Fatal("not expired")
	}
	if _, err := os.Stat(d.sessionSecretsPath(gone)); !os.IsNotExist(err) {
		t.Fatal(err)
	}
}
