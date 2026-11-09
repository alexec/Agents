package agentsd

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #4167: ask_secret carries the agent's description to the card, the person's changed one is
// kept, and list_secrets gives every secret's name and description, the session's own and the
// person's that are not here yet too, never a value.
func TestListSecretsGivesNamesAndDescriptionsNeverAValue(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, isErr := m.tool(2, "list_secrets", map[string]any{}); isErr || !strings.Contains(text, "There are no secrets") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "ask_secret", map[string]any{"name": "GITHUB_TOKEN", "reason": "To push.",
		"secret_description": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"}); !isErr || !strings.Contains(text, "looks like a secret") {
		t.Fatal(text)
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(4, "ask_secret", map[string]any{"name": "GITHUB_TOKEN", "reason": "To push.",
			"secret_description": "A token for alexec/Agents."})
		answered <- text
	}()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	if s := pending[0].Secret; s == nil || s.Description == nil || *s.Description != "A token for alexec/Agents." {
		t.Fatalf("%+v", pending[0].Secret)
	}
	const value = "not-a-real-token-4167"
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept",
		"content": map[string]any{"value": value, "needsApproval": false, "description": "The agents' token for alexec/Agents."}})
	<-answered
	if err := d.setSessionSecret(a.ID, "SHOP_PASSWORD", "hunter2-4167", "The shop's sign-in.", false); err != nil {
		t.Fatal(err)
	}
	d.userScopeMu.Lock()
	mark := d.userMarkLocked()
	mark.Waiting = []wire.UserSecretAbout{{Name: "OPENAI_API_KEY", Description: new("The person's OpenAI key.")}}
	d.userMark = &mark
	d.userScopeMu.Unlock()

	text, isErr := m.tool(5, "list_secrets", map[string]any{})
	if isErr || strings.Contains(text, value) || strings.Contains(text, "hunter2") {
		t.Fatal(text)
	}
	lines := strings.Split(text, "\n")[1:]
	want := []secretListLine{
		{Name: "SHOP_PASSWORD", Description: "The shop's sign-in.", HereToo: true, SessionOnly: true},
		{Name: "GITHUB_TOKEN", Description: "The agents' token for alexec/Agents.", HereToo: true},
		{Name: "OPENAI_API_KEY", Description: "The person's OpenAI key."},
	}
	if len(lines) != len(want) {
		t.Fatal(text)
	}
	for i, line := range lines {
		var got secretListLine
		if err := json.Unmarshal([]byte(line), &got); err != nil || got != want[i] {
			t.Errorf("%d: %s, want %+v", i, line, want[i])
		}
	}
	var listed wire.SessionSecrets
	json.Unmarshal(c.call(t, 3, "secrets/sessionList", nil), &listed)
	if len(listed.Secrets) != 1 || listed.Secrets[0].Description == nil || *listed.Secrets[0].Description != "The shop's sign-in." {
		t.Fatalf("%+v", listed)
	}
}
