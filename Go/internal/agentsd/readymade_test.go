package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The ready-made workflows (#1342): each reads, is off, refers to its skill, and starts on
// events that mcpcatalog counts for the Workflows level.
func TestReadyMadeWorkflowsRead(t *testing.T) {
	ids := readyMadeIDs()
	if !slices.Equal(ids, []string{"fix-failed-checks", "work-an-issue"}) {
		t.Fatal(ids)
	}
	var events []string
	for _, id := range ids {
		text, skill := readyMadeText(id)
		w := parseWorkflow(text, id, "/p")
		if w.Problem != nil || !isOff(w) || len(w.Triggers) == 0 || skill == "" {
			t.Fatalf("%s: %+v", id, w)
		}
		if !strings.Contains(skill, "\nname: "+id+"\n") {
			t.Fatalf("%s: the skill's name is not its id", id)
		}
		for _, tr := range w.Triggers {
			events = append(events, triggerName(tr))
		}
	}
	slices.Sort(events)
	want := slices.Clone(mcpcatalog.ReadyMadeEvents)
	slices.Sort(want)
	if !slices.Equal(slices.Compact(events), want) {
		t.Fatalf("triggers %v, ReadyMadeEvents %v", events, want)
	}
}

func TestReadyMadeWorkflowsTurnOnWithOneSwitch(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	plain := project(t, c, 1)
	dir := project(t, c, 2)
	os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[remote \"origin\"]\n\turl = git@github.com:o/n.git\n"), 0o644)
	folder := store.FolderURL(dir)

	// A folder that does not push to GitHub has none.
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 3, "workflows/list", map[string]any{"folder": store.FolderURL(plain)}), &list)
	if len(list) != 0 {
		t.Fatalf("%+v", list)
	}
	// One that does lists them, off, and nothing is written.
	json.Unmarshal(c.call(t, 4, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 2 || list[0].IsEnabled || list[0].AwaitingApproval != nil || list[1].Workflow.Name != "Work an issue" {
		t.Fatalf("%+v", list)
	}
	if _, err := os.Stat(filepath.Join(dir, ".agents")); !os.IsNotExist(err) {
		t.Fatal("written before it was turned on")
	}
	if e := c.callError(t, 5, "workflows/delete", map[string]any{"folder": folder, "workflowID": "work-an-issue"}); e.Code != wire.FailureDeleteRefused {
		t.Fatalf("%+v", e)
	}

	// The person's switch writes the workflow and its skill, on and approved.
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 6, "workflows/enable", map[string]any{"folder": folder, "workflowID": "work-an-issue", "enabled": true}), &s)
	if !s.IsEnabled || s.AwaitingApproval != nil || s.DeniedHere != nil {
		t.Fatalf("%+v", s)
	}
	b, _ := os.ReadFile(filepath.Join(workflowsFolder(dir), "work-an-issue.md"))
	if _, skill := readyMadeText("work-an-issue"); len(b) == 0 || !fileHas(t, filepath.Join(dir, ".agents", "skills", "work-an-issue", "SKILL.md"), skill) {
		t.Fatalf("%s", b)
	}
	if w := parseWorkflow(string(b), "work-an-issue", dir); isOff(w) {
		t.Fatalf("%s", b)
	}

	// A skill the project has already is kept; an agent's switch waits for the person.
	keep := filepath.Join(dir, ".agents", "skills", "fix-failed-checks", "SKILL.md")
	os.MkdirAll(filepath.Dir(keep), 0o755)
	os.WriteFile(keep, []byte("ours"), 0o644)
	d.enableWorkflow(wire.WorkflowEnableRequest{Folder: folder, WorkflowID: "fix-failed-checks", Enabled: true}, "agent")
	s, _ = d.oneWorkflow(dir, "fix-failed-checks")
	if s.AwaitingApproval == nil || !fileHas(t, keep, "ours") {
		t.Fatalf("%+v", s)
	}
}

func fileHas(t *testing.T, path, want string) bool {
	t.Helper()
	b, err := os.ReadFile(path)
	return err == nil && string(b) == want
}

func TestPushesToGitHubInAWorktree(t *testing.T) {
	main, wt := t.TempDir(), t.TempDir()
	os.MkdirAll(filepath.Join(main, ".git", "worktrees", "x"), 0o755)
	os.WriteFile(filepath.Join(main, ".git", "config"), []byte("[remote \"origin\"]\n\turl = https://github.com/o/n\n"), 0o644)
	os.WriteFile(filepath.Join(main, ".git", "worktrees", "x", "commondir"), []byte("../..\n"), 0o644)
	os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+filepath.Join(main, ".git", "worktrees", "x")+"\n"), 0o644)
	if !pushesToGitHub(main) || !pushesToGitHub(wt) || pushesToGitHub(t.TempDir()) {
		t.Fatal("pushesToGitHub")
	}
}
