package agentsd

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The three endings name the runtime's own question tool where the app knows it, and
// ask_form always.
func TestTheEndingBriefNamesTheThreeEndings(t *testing.T) {
	for runtimeID, ask := range map[string]string{"claude": "AskUserQuestion (or ask_form if you lack it)", "grok": "ask_form,"} {
		got := endingBrief(runtimeID)
		for _, want := range []string{ask, "show_file on it once", "do not archive", "archive_session with no id"} {
			if !strings.Contains(got, want) {
				t.Fatalf("%s: %q has no %q", runtimeID, got, want)
			}
		}
	}
}

// What the person declared is said inside the lease paragraph, once.
func TestTheLeaseBriefSaysWhatWasDeclared(t *testing.T) {
	if got := leasesWithDeclared(nil); got != leasesBrief {
		t.Fatalf("%q", got)
	}
	got := leasesWithDeclared([]wire.DeclaredResource{{Name: "gpu", DisplayName: "GPU", Description: "For training.", Holders: 2}})
	if !strings.HasSuffix(got, " Also declared, each to lease whenever its description applies:\n- GPU (2 at once): For training.") {
		t.Fatalf("%q", got)
	}
}

// Claude's is _meta.systemPrompt.append, Grok's goes before its rules, and a runtime with
// no system prompt has its _meta as it was.
func TestTheBriefGoesWhereTheRuntimeTakesASystemPrompt(t *testing.T) {
	claude := withSystemPrompt(sessionMeta("claude"), "claude", "words")
	if systemPromptOf(claude) != "words" || claude["claudeCode"] == nil {
		t.Fatalf("%v", claude)
	}
	grok := withSystemPrompt(map[string]any{"rules": "cards"}, "grok", "words")
	if systemPromptOf(grok) != "words\n\ncards" {
		t.Fatalf("%v", grok)
	}
	if m := withSystemPrompt(nil, "cursor", "words"); m != nil {
		t.Fatalf("%v", m)
	}
}

func agentMessages(d *Daemon, id wire.UUID) string {
	entries, _, _ := d.Store.Transcript(id, 0)
	var out []string
	for _, e := range entries {
		if e.Kind.AgentMessage != nil {
			out = append(out, e.Kind.AgentMessage.Text)
		}
	}
	return strings.Join(out, "")
}

// A Claude agent has the brief as its system prompt, with the declared resources, and its
// first prompt is the person's words alone; the transcript records only those.
func TestClaudeHasTheBriefAsItsSystemPrompt(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	os.WriteFile(d.resourcesFile(), []byte(`[{"name":"gpu","displayName":"GPU","description":"For training.","holders":1}]`), 0o644)
	id := startAgent(t, c, 1, t.TempDir(), "say your brief")
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	said := agentMessages(d, id)
	system, before, _ := strings.Cut(strings.TrimPrefix(said, "System: "), "\nBefore: ")
	if system != d.brief("claude") || !strings.Contains(system, "- GPU (one at a time): For training.") || before != "" {
		t.Fatalf("said %q", said)
	}
	if u := userMessages(d, id); len(u) != 1 || u[0] != "say your brief" {
		t.Fatalf("%v", u)
	}
}

// A runtime with no system prompt has the brief before the words of its first prompt, and
// not again.
func TestCursorHasTheBriefInItsFirstPromptOnly(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "cursor", "cwd": "file://" + t.TempDir(), "prompt": "say your brief"}), &id)
	c.until(t, "the first end", ended(id, wire.AgentStateFinished))
	if said := agentMessages(d, id); said != "System: \nBefore: "+d.brief("cursor") {
		t.Fatalf("said %q", said)
	}
	c.call(t, 2, "agents/prompt", map[string]any{"agentID": id, "text": "say your brief again", "from": "person"})
	waitFor(t, "the second answer", func() bool { return strings.Count(agentMessages(d, id), "System: ") == 2 })
	if said := agentMessages(d, id); !strings.HasSuffix(said, "System: \nBefore: ") {
		t.Fatalf("said %q", said)
	}
}
