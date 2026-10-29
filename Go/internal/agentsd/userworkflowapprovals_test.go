package agentsd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A user workflow, and the skill it names, is approved once in the user's folder: the
// person's own saves in Settings keep it approved, and any other change makes it wait
// in every folder it is on, until the person approves it.
func TestAUserWorkflowWaitsAfterAChangeOutsideSettings(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	dir := folder(t, c, 1)
	os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[remote \"origin\"]\n\turl = git@github.com:o/n.git\n"), 0o644)
	url := store.FolderURL(dir)
	id := "work-an-issue"
	workflowFile := filepath.Join(workflowsFolder(home), id+".md")
	skillFile := filepath.Join(home, ".agents", "skills", id, "SKILL.md")
	awaiting := func(folder string) *wire.WorkflowApproval {
		t.Helper()
		s, err := d.oneWorkflow(folder, id)
		if err != nil {
			t.Fatal(err)
		}
		return s.AwaitingApproval
	}

	// The ready-made one, as the app wrote it, is approved and turned on here.
	c.call(t, 2, "workflows/list", map[string]any{"scope": "user"})
	if a := awaiting(dir); a != nil {
		t.Fatalf("ready-made: %+v", a)
	}
	c.call(t, 3, "workflows/enable", map[string]any{"folder": url, "workflowID": id, "enabled": true})

	// Its skill changed outside Settings: it waits here and in the user's folder, and asks.
	os.WriteFile(skillFile, []byte("---\nname: work-an-issue\ndescription: x\n---\nOther steps.\n"), 0o644)
	d.rescanWorkflows(dir)
	a := awaiting(dir)
	if a == nil || a.IsNew || awaiting(home) == nil {
		t.Fatalf("after a skill change: %+v", a)
	}
	if s, _ := d.summaryFor(dir); len(s.Approvals) != 1 || s.Approvals[0].Key != id || s.Approvals[0].Line != "Changed since you approved it" {
		t.Fatalf("%+v", s.Approvals)
	}
	d.workflowMu.Lock()
	o := d.refusalLocked(fireRequest{folder: dir, id: id, trigger: wire.WorkflowTrigger{}}, d.fileLocked(dir, id))
	d.workflowMu.Unlock()
	if o == nil || o.AwaitingApproval == nil {
		t.Fatalf("it would run: %+v", o)
	}

	// A save of the workflow in Settings does not approve a change it did not make.
	text, _ := os.ReadFile(workflowFile)
	c.call(t, 4, "workflows/write", map[string]any{"workflowID": id, "content": string(text) + "\nMore.\n"})
	if awaiting(dir) == nil {
		t.Fatal("a save in Settings approved a skill it did not change")
	}

	// Approved in the folder: approved for the user's folder too.
	a = awaiting(dir)
	c.call(t, 5, "approvals/answer", map[string]any{"folder": url, "kind": "workflow", "key": id, "digest": a.Digest, "action": "approve"})
	if awaiting(dir) != nil || awaiting(home) != nil {
		t.Fatal("still waits after approval")
	}

	// The person's own saves in Settings, of the workflow and of its skill, keep it approved.
	c.call(t, 6, "workflows/write", map[string]any{"workflowID": id, "content": string(text) + "\nOther.\n"})
	c.call(t, 7, "agentConfig/editorSave", map[string]any{"kind": "skills", "path": id + "/SKILL.md",
		"content": "---\nname: work-an-issue\ndescription: y\n---\nMy steps.\n"})
	if a := awaiting(dir); a != nil {
		t.Fatalf("after the person's saves: %+v", a)
	}

	// The workflow's own file changed outside Settings: it waits.
	os.WriteFile(workflowFile, []byte(string(text)+"\nChanged.\n"), 0o644)
	d.rescanWorkflows(dir)
	if awaiting(dir) == nil {
		t.Fatal("a changed workflow file did not wait")
	}

	// A new one saved in Settings is approved; one written another way is not.
	c.call(t, 8, "workflows/write", map[string]any{"workflowID": "mine", "content": "---\non: manual\n---\nMine.\n"})
	os.WriteFile(filepath.Join(workflowsFolder(home), "theirs.md"), []byte("---\non: manual\n---\nTheirs.\n"), 0o644)
	d.rescanWorkflows(dir)
	if s, _ := d.oneWorkflow(home, "mine"); s.AwaitingApproval != nil {
		t.Fatalf("mine: %+v", s.AwaitingApproval)
	}
	if s, _ := d.oneWorkflow(home, "theirs"); s.AwaitingApproval == nil || !s.AwaitingApproval.IsNew {
		t.Fatalf("theirs: %+v", s.AwaitingApproval)
	}
}

// A ready-made workflow written next to a skill that is not the app's own waits.
func TestAReadyMadeWorkflowWaitsWhenItsSkillIsNotTheAppsOwn(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	// Approval began for user workflows before this one was written.
	d.workflowMu.Lock()
	d.scanLocked()
	d.workflowMu.Unlock()
	id := "fix-failed-checks"
	os.Remove(filepath.Join(workflowsFolder(home), id+".md"))
	os.WriteFile(filepath.Join(home, ".agents", "skills", id, "SKILL.md"), []byte("---\nname: x\ndescription: x\n---\nOther.\n"), 0o644)
	c.call(t, 1, "workflows/list", map[string]any{"scope": "user"})
	if s, _ := d.oneWorkflow(home, id); s.AwaitingApproval == nil {
		t.Fatal("approved with a skill that is not the app's own")
	}
	if s, _ := d.oneWorkflow(home, "work-an-issue"); s.AwaitingApproval != nil {
		t.Fatalf("%+v", s.AwaitingApproval)
	}
}
