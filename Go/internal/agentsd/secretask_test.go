package agentsd

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// An agent asks for a secret (#2885): the person types it into the card, the host saves it
// to secrets.env, and the agent, the record and every other file under the root have only
// its name.
func TestAskingForASecret(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	ask := map[string]any{"name": "OPENAI_API_KEY", "reason": "To call the embeddings API.",
		"url": "https://platform.openai.com/api-keys"}
	if text, isErr := m.tool(2, "ask_secret", ask); !isErr || text != "A secret can only be asked for while this agent is working." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "ask_secret", map[string]any{"name": "openai key", "reason": "x"}); !isErr || !strings.Contains(text, "letters, digits and underscores") {
		t.Fatal(text)
	}
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	answered := make(chan string, 1)
	go func() { text, _ := m.tool(4, "ask_secret", ask); answered <- text }()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	s := pending[0].Secret
	if s == nil || s.Name != "OPENAI_API_KEY" || s.IsSet || s.URL == nil || *s.URL != "https://platform.openai.com/api-keys" {
		t.Fatalf("%+v", pending[0])
	}
	if got := formAnswers(pending[0]); got != nil {
		t.Fatalf("a notification would take the secret in clear: %+v", got)
	}
	// Nothing typed: the card stays, and says so.
	if e := c.callError(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept",
		"content": map[string]any{"value": "  "}}); e == nil || e.Message != "Type OPENAI_API_KEY, or choose No thanks." {
		t.Fatalf("%+v", e)
	}
	const value = "sk-test-2885-not-a-real-key"
	c.call(t, 3, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept",
		"content": map[string]any{"value": value + "\n"}})
	text := <-answered
	path := skillcatalog.SecretsPath(home)
	if !strings.HasPrefix(text, "OPENAI_API_KEY is saved in the person's secrets file, "+path) || strings.Contains(text, value) {
		t.Fatal(text)
	}
	if got, _ := skillcatalog.LoadSecrets(path).Value("OPENAI_API_KEY"); got != value {
		t.Fatalf("secrets.env has %q", got)
	}
	var said []wire.ElicitationAnswer
	waitFor(t, "the answer on the record", func() bool {
		entries, _, _ := d.Store.Transcript(a.ID, 0)
		for _, e := range entries {
			if ans := e.Kind.ElicitationAnswered; ans != nil && ans.ID == pending[0].ID {
				said = ans.Answers
				return true
			}
		}
		return false
	})
	if !slices.Equal(said, []wire.ElicitationAnswer{{Question: "OPENAI_API_KEY", Answer: "Saved to your secrets"}}) {
		t.Fatalf("%+v", said)
	}
	time.Sleep(100 * time.Millisecond) // the call's line in app-tools.jsonl
	filepath.WalkDir(root, func(p string, e fs.DirEntry, err error) error {
		if err == nil && !e.IsDir() {
			if b, _ := os.ReadFile(p); strings.Contains(string(b), value) {
				t.Errorf("the secret is in %s", p)
			}
		}
		return nil
	})
}

// A secret asked for again says one is saved already, and a card left open brings the
// answer as a prompt with only the name in it.
func TestASecretLeftOpenBringsOnlyItsName(t *testing.T) {
	fakeRuntimes(t)
	was := formHoldLimit
	formHoldLimit = 300 * time.Millisecond
	defer func() { formHoldLimit = was }()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	path := skillcatalog.SecretsPath(home)
	env := skillcatalog.Secrets{}
	env.Set("GITLAB_TOKEN", "old")
	if err := env.Save(path); err != nil {
		t.Fatal(err)
	}
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	l := d.live(a.ID)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
	if text, isErr := m.tool(2, "ask_secret", map[string]any{"name": "GITLAB_TOKEN", "reason": "The old one is refused."}); isErr || text != formStillOpen {
		t.Fatal(text)
	}
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 1 || pending[0].Secret == nil || !pending[0].Secret.IsSet {
		t.Fatalf("%+v", pending)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": pending[0].ID, "action": "accept", "content": map[string]any{"value": "new-token"}})
	waitFor(t, "the answer in its chat", func() bool {
		for _, said := range userMessages(d, a.ID) {
			if strings.HasPrefix(said, "The person replied to your ask_secret for GITLAB_TOKEN. GITLAB_TOKEN is saved") {
				if strings.Contains(said, "new-token") {
					t.Fatal(said)
				}
				return true
			}
		}
		return false
	})
	if got, _ := skillcatalog.LoadSecrets(path).Value("GITLAB_TOKEN"); got != "new-token" {
		t.Fatalf("secrets.env has %q", got)
	}
}
