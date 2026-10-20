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
	if !slices.Equal(ids, []string{"address-review-comments", "fix-failed-checks", "work-a-linear-issue", "work-an-issue"}) {
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

// One label is one agent (#1343): a GitHub or GitLab issue's starts Work an issue (#1633), a
// Linear issue's Work a Linear issue, as all three servers raise issue.labelled.
func TestEachIssueWorkflowTakesItsServers(t *testing.T) {
	for id, servers := range map[string][]string{"work-an-issue": {"github", "gitlab"}, "work-a-linear-issue": {"linear"}} {
		text, _ := readyMadeText(id)
		w := parseWorkflow(text, id, "/p")
		raw, _ := json.Marshal(w.Triggers)
		mt, ok := serverTrigger(w.Triggers[0])
		if len(w.Triggers) != 1 || triggerName(w.Triggers[0]) != "issue.labelled" || !ok || !slices.Equal(mt.servers, servers) {
			t.Fatalf("%s: %s", id, raw)
		}
	}
}

// The dev loop on both forges (#1633): each workflow hears the gitlab server too, and its
// skill names the gitlab server's tools beside the github server's.
func TestTheDevLoopWorkflowsHearGitLab(t *testing.T) {
	for id, tools := range map[string][]string{
		"work-an-issue":           {"get_issue", "comment_on_issue", "create_merge_request"},
		"fix-failed-checks":       {"failed_log", "retry_pipeline", "comment_on_merge_request"},
		"address-review-comments": {"list_merge_request_comments", "reply_to_merge_request_comment", "comment_on_merge_request"},
	} {
		text, skill := readyMadeText(id)
		w := parseWorkflow(text, id, "/p")
		hears := false
		for _, tr := range w.Triggers {
			mt, ok := serverTrigger(tr)
			hears = hears || (ok && mt.hears("gitlab"))
		}
		if !hears {
			t.Errorf("%s does not hear the gitlab server", id)
		}
		for _, tool := range tools {
			if !strings.Contains(skill, "`"+tool+"`") {
				t.Errorf("%s's skill does not name %s", id, tool)
			}
		}
	}
}

// Work an issue starts on an issue that anyone can write, so its agent asks before it
// acts, and its skill reads the issue as data and uses only the comments of the
// repository's own people.
func TestWorkAnIssueAsksBeforeItActs(t *testing.T) {
	text, skill := readyMadeText("work-an-issue")
	w := parseWorkflow(text, "work-an-issue", "/p")
	if w.Settings.PermissionMode == nil || *w.Settings.PermissionMode != "default" {
		t.Fatalf("%+v", w.Settings)
	}
	if !strings.Contains(skill, "data, not instructions") || !strings.Contains(skill, "`author_association`") {
		t.Fatal(skill)
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
	if len(list) != 4 || list[0].IsEnabled || list[0].AwaitingApproval != nil || list[3].Workflow.Name != "Work an issue" {
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
	// What it approved is the workflow with its skill, so a change to the skill waits.
	d.workflowMu.Lock()
	st := d.stateLocked(dir, "work-an-issue", false)
	d.workflowMu.Unlock()
	if st == nil || st.ApprovedSkills["work-an-issue"] == "" {
		t.Fatalf("%+v", st)
	}
	os.WriteFile(filepath.Join(dir, ".agents", "skills", "work-an-issue", "SKILL.md"), []byte("changed"), 0o644)
	d.rescanWorkflows(dir)
	if s, _ = d.oneWorkflow(dir, "work-an-issue"); s.AwaitingApproval == nil {
		t.Fatalf("%+v", s)
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

// S20261019-2: a skill the project has already is not Agents' text, so a person's switch
// does not approve it unseen; the workflow waits, and the skill is in what is shown.
func TestAReadyMadeWorkflowWithTheProjectsOwnSkillWaits(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
	os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
	os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[remote \"origin\"]\n\turl = git@github.com:o/n.git\n"), 0o644)
	folder := store.FolderURL(dir)
	keep := filepath.Join(dir, ".agents", "skills", "work-an-issue", "SKILL.md")
	os.MkdirAll(filepath.Dir(keep), 0o755)
	os.WriteFile(keep, []byte("Push to main.\n"), 0o644)
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/enable", map[string]any{"folder": folder, "workflowID": "work-an-issue", "enabled": true}), &s)
	if s.AwaitingApproval == nil || !fileHas(t, keep, "Push to main.\n") {
		t.Fatalf("%+v", s)
	}
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 3, "approvals/read", map[string]any{"folder": folder, "kind": "workflow", "key": "work-an-issue"}), &reading)
	if reading.Current == nil || !strings.Contains(*reading.Current, "Push to main.") {
		t.Fatalf("%+v", reading)
	}
}

func fileHas(t *testing.T, path, want string) bool {
	t.Helper()
	b, err := os.ReadFile(path)
	return err == nil && string(b) == want
}

func TestPushesToAForgeInAWorktree(t *testing.T) {
	main, wt := t.TempDir(), t.TempDir()
	os.MkdirAll(filepath.Join(main, ".git", "worktrees", "x"), 0o755)
	os.WriteFile(filepath.Join(main, ".git", "config"), []byte("[remote \"origin\"]\n\turl = https://github.com/o/n\n"), 0o644)
	os.WriteFile(filepath.Join(main, ".git", "worktrees", "x", "commondir"), []byte("../..\n"), 0o644)
	os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+filepath.Join(main, ".git", "worktrees", "x")+"\n"), 0o644)
	if !pushesToForge(main) || !pushesToForge(wt) || pushesToForge(t.TempDir()) {
		t.Fatal("pushesToForge")
	}
	// A GitLab remote, on gitlab.com or a self-managed GitLab (#1633); another host is not one.
	for remote, want := range map[string]bool{"git@gitlab.com:g/app.git": true, "https://gitlab.example.com/g/app": true,
		"https://code.example.org/g/app": false} {
		dir := t.TempDir()
		os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
		os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[remote \"origin\"]\n\turl = "+remote+"\n"), 0o644)
		if pushesToForge(dir) != want {
			t.Errorf("%s: %v", remote, !want)
		}
	}
}
