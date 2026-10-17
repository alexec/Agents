package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports RuntimeAssessmentTests' start and RuntimeAssessmentVerifierTests' reading: an
// assessment starts an agent labelled for it with the brief, every app tool call is kept
// as answered, and the score is taken from that record, not the agent's word.

func TestARuntimeAssessedFromTheRecord(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	project := t.TempDir()
	c.call(t, 1, "projects/add", map[string]any{"folder": "file://" + project})

	var started wire.AssessRuntimeResult
	json.Unmarshal(c.call(t, 2, "runtimes/assess", map[string]any{"runtimeID": "claude", "folder": "file://" + project, "model": "default"}), &started)
	a := d.Store.Agent(started.AgentID)
	if a == nil || started.Model != nil || !strings.Contains(started.ReportPath, filepath.Join(project, ".agents", "reviews", "runtimes", "claude-")) {
		t.Fatalf("%+v %+v", started, a)
	}
	if len(a.Labels) != 1 || a.Labels[0].Value != assessLabel {
		t.Fatalf("%+v", a.Labels)
	}
	waitFor(t, "the brief in the chat", func() bool { return len(userMessages(d, a.ID)) > 0 })
	if u := userMessages(d, a.ID); len(u) == 0 || !strings.HasPrefix(u[0], "Assess the Claude runtime (#47).") ||
		!strings.Contains(u[0], "`AskUserQuestion`") || !strings.Contains(u[0], started.ReportPath) {
		t.Fatalf("%q", u)
	}
	if _, err := os.Stat(filepath.Join(d.assessmentsPath(), string(a.ID)+".start.json")); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Dir(started.ReportPath)); err != nil || !info.IsDir() {
		t.Fatal(err)
	}

	// The report shown before it is written, then written naming every step.
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	m.tool(2, "show_file", map[string]any{"path": started.ReportPath})
	m.tool(3, "lease_resource", map[string]any{"name": "assess-x", "minutes": 5})
	m.tool(4, "list_resources", map[string]any{})
	m.tool(5, "release_resource", map[string]any{"name": "assess-x"})
	var steps []string
	for _, s := range assessSteps {
		steps = append(steps, "| "+s.id+" | passed |")
	}
	os.WriteFile(started.ReportPath, []byte(strings.Join(steps, "\n")), 0o644)

	calls := d.appToolCalls(a.ID)
	if len(calls) != 4 || calls[0].Method != "agents/showFile" || !calls[0].Ok || !strings.Contains(*calls[0].Answer, "open, empty") ||
		calls[1].Method != "leases/lease" {
		t.Fatalf("%+v", calls)
	}

	var score wire.RuntimeAssessmentScore
	json.Unmarshal(c.call(t, 3, "runtimes/assessment", map[string]any{"agentID": a.ID}), &score)
	verdicts := map[string]wire.RuntimeAssessmentCheck{}
	for _, ch := range score.Checks {
		verdicts[ch.ID] = ch
	}
	if len(score.Checks) != 15 || verdicts["show_file"].Verdict != passed || verdicts["report"].Verdict != passed ||
		verdicts["leases"].Verdict != passed || verdicts["ask_form"].Verdict != failedStep ||
		verdicts["ask_form"].Evidence != "`ask_form` never called" {
		t.Fatalf("%+v", score.Checks)
	}
	if _, err := os.Stat(filepath.Join(d.assessmentsPath(), string(a.ID)+".json")); err != nil {
		t.Fatal(err)
	}
	if note := assessNote(score); !strings.HasPrefix(note, "The app scored this assessment of claude (model ") &&
		!strings.HasPrefix(note, "The app scored this assessment of claude (on ") {
		t.Fatal(note)
	}
}
