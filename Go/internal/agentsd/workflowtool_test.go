package agentsd

import (
	"os"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports ManageWorkflowsTests: an agent writes a workflow, which starts off and waits for
// the person; it is listed in Workflow.summary's words; an agent cannot turn on what the
// person turned off.

func TestAnAgentWritesAWorkflow(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "manage_workflows", map[string]any{"action": "list"}); text != "This project has no workflows yet. They live in .agents/workflows, one Markdown file each." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "manage_workflows", map[string]any{"action": "write", "id": "../x", "content": "x"}); !isErr || !strings.HasPrefix(text, "Workflows can only be read and written inside this project's .agents/workflows") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(4, "manage_workflows", map[string]any{"action": "write", "id": "bad", "content": "no front matter"}); !isErr ||
		text != "That front matter could not be read: This file does not start with a metadata block. Nothing was written." {
		t.Fatal(text)
	}
	content := "---\non:\n  - schedule:\n      at: \":30\"\n      between: \"9:00-17:00\"\n      days: [mon, tue, wed, thu, fri]\ncooldown: 2h\n---\nCheck the build.\n"
	text, _ := m.tool(5, "manage_workflows", map[string]any{"action": "write", "id": "check", "content": content})
	if !strings.HasPrefix(text, "Created check. Every weekday on the half hour between 9am and 5pm, in a new agent, at most once every 2 hours. It will not run until they approve it") ||
		!strings.Contains(text, "It starts turned off (the app wrote `enabled: false` into it)") {
		t.Fatal(text)
	}
	b, _ := os.ReadFile(workflowsFolder(dir) + "/check.md")
	if !strings.Contains(string(b), "cooldown: 2h\nenabled: false\n---") {
		t.Fatalf("%s", b)
	}
	text, _ = m.tool(6, "manage_workflows", map[string]any{"action": "list"})
	if text != "1 workflow:\n- check: Every weekday on the half hour between 9am and 5pm, in a new agent, at most once every 2 hours [turned off: written by an agent, waiting for the person]" {
		t.Fatal(text)
	}
	if text, isErr := m.tool(7, "manage_workflows", map[string]any{"action": "enable", "id": "check"}); !isErr || !strings.HasPrefix(text, "Nothing was changed: check was written by an agent") {
		t.Fatal(text)
	}
	if text, _ := m.tool(8, "manage_workflows", map[string]any{"action": "read", "id": "check"}); text != string(b) {
		t.Fatal(text)
	}
	if text, _ := m.tool(9, "manage_workflows", map[string]any{"action": "remove", "id": "check"}); text != "check is gone. It will not run again." {
		t.Fatal(text)
	}
	_ = wire.WorkflowModeNew
}
