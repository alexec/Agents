package agentsd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports ManageWorkflowsTests: an agent writes a workflow, which starts off and waits for
// the person; it is listed in Workflow.summary's words; an agent cannot turn on what the
// person turned off.

func TestAnAgentWritesAWorkflow(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if text, _ := m.tool(2, "manage_workflows", map[string]any{"action": "list"}); text != "This folder has no workflows yet. They live in .agents/workflows, one Markdown file each." {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "manage_workflows", map[string]any{"action": "write", "id": "../x", "content": "x"}); !isErr || !strings.HasPrefix(text, "Workflows can only be read and written inside this folder's .agents/workflows") {
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

// An agent runs a workflow as Run now does (#1524), but never one waiting for the person's
// OK or turned off, never one that runs in its triggering agent, and never past the chain limit.
func TestAnAgentRunsAWorkflow(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	write := func(id, text string) {
		os.WriteFile(filepath.Join(workflowsFolder(dir), id+".md"), []byte(text), 0o644)
	}
	write("review", "---\nname: Review\non: manual\n---\nReview what changed.\n")
	write("off", "---\non: manual\nenabled: false\n---\nx\n")
	write("mine", "---\non: agent.finished\nagent: triggering\n---\nx\n")
	approveAll(t, c, folder)
	write("new", "---\non: manual\n---\nx\n")
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	run := func(n int, id string) (string, bool) {
		return m.tool(n, "manage_workflows", map[string]any{"action": "run", "id": id})
	}
	text, isErr := run(2, "review")
	if isErr || !strings.HasPrefix(text, "Ran review: it started agent ") {
		t.Fatal(text)
	}
	ran := d.Store.Agent(wire.UUID(strings.Fields(strings.TrimPrefix(text, "Ran review: it started agent "))[0][:36]))
	if ran == nil || ran.StartedByWorkflow == nil || *ran.StartedByWorkflow != "review" || *ran.ChainDepth != 1 {
		t.Fatalf("%+v", ran)
	}
	if text, isErr := run(3, "new"); !isErr || !strings.HasPrefix(text, "Nothing was run: new is waiting for the person's OK") {
		t.Fatal(text)
	}
	if text, isErr := run(4, "off"); !isErr || !strings.HasPrefix(text, "Nothing was run: off is turned off") {
		t.Fatal(text)
	}
	if text, isErr := run(5, "mine"); !isErr || !strings.HasPrefix(text, "Nothing was run: mine runs in the agent that triggered it") {
		t.Fatal(text)
	}
	if text, isErr := run(6, "../x"); !isErr || !strings.HasPrefix(text, "Workflows can only be read and written inside") {
		t.Fatal(text)
	}
	deep := seeded(t, d, dir, func(a *wire.Agent) { n := int64(workflowChainLimit + 1); a.ChainDepth = &n })
	dm := appClient(t, d, deep.ID)
	dm.post("initialize", map[string]any{}, 1)
	waitFor(t, "the first run over", func() bool { return !d.runningOf(dir, "review") })
	if text, isErr := dm.tool(2, "manage_workflows", map[string]any{"action": "run", "id": "review"}); !isErr ||
		text != "Nothing was run: review did not run, as this chain is already 3 deep." {
		t.Fatal(text)
	}
}

// The session that ran a workflow may archive its session, as one it started; another may
// not (#1730). No workflow here answers agent.finished, which would prompt the run's
// session again and take it out of the archive.
func TestTheSessionThatRanAWorkflowArchivesIt(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non: manual\n---\nReview what changed.\n"), 0o644)
	approveAll(t, c, store.FolderURL(dir))
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	text, isErr := m.tool(2, "manage_workflows", map[string]any{"action": "run", "id": "review"})
	if isErr || !strings.HasPrefix(text, "Ran review: it started agent ") {
		t.Fatal(text)
	}
	ran := wire.UUID(strings.Fields(strings.TrimPrefix(text, "Ran review: it started agent "))[0][:36])
	waitFor(t, "the run over", func() bool {
		r := d.Store.Agent(ran)
		return !d.runningOf(dir, "review") && r != nil && !helperRunning(r)
	})
	other := seeded(t, d, dir, nil)
	om := appClient(t, d, other.ID)
	om.post("initialize", map[string]any{}, 1)
	if text, isErr := om.tool(2, "archive_session", map[string]any{"id": string(ran)}); !isErr ||
		!strings.HasPrefix(text, "Nothing changed: a workflow started that one, and you did not run it.") {
		t.Fatal(text)
	}
	if text, isErr := m.tool(3, "archive_session", map[string]any{"id": string(ran)}); isErr || !strings.HasPrefix(text, "Archived “Review”") {
		t.Fatal(text)
	}
	if r := d.Store.Agent(ran); r.State != wire.AgentStateArchived {
		t.Fatalf("%+v", r)
	}
}
