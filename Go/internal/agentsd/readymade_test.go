package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The ready-made workflows (#1342): each reads, is off, refers to its skill, and starts on
// events that mcpcatalog counts for the Workflows level.
func TestReadyMadeWorkflowsRead(t *testing.T) {
	ids := readyMadeIDs()
	if !slices.Equal(ids, []string{"address-review-comments", "answer-a-sign-up-code", "fix-failed-checks", "work-a-linear-issue", "work-an-issue"}) {
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

// Address review comments pushes in auto mode, so its skill acts only on the comments of
// the folder's own people, on both forges: GitLab's trusted notes, GitHub's by association.
func TestAddressReviewCommentsActsOnlyOnTheFoldersOwn(t *testing.T) {
	_, skill := readyMadeText("address-review-comments")
	for _, want := range []string{"`trusted: true`", "`author_association`", "`get_reviews`", "outside content"} {
		if !strings.Contains(skill, want) {
			t.Errorf("the skill does not say %s", want)
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

func TestReadyMadeWorkflowsLiveInUserFolderAndFoldersUseThem(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	first := folder(t, c, 1)
	second := folder(t, c, 2)
	for _, dir := range []string{first, second} {
		os.MkdirAll(filepath.Join(dir, ".git"), 0o755)
		os.WriteFile(filepath.Join(dir, ".git", "config"), []byte("[remote \"origin\"]\n\turl = git@github.com:o/n.git\n"), 0o644)
	}
	folderURL := store.FolderURL(first)
	userFolder := filepath.Join(home, ".agents", "workflows")

	// A normal folder has no workflows from the user's folder.
	plain := folder(t, c, 3)
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 3, "workflows/list", map[string]any{"folder": store.FolderURL(plain)}), &list)
	if len(list) != 0 {
		t.Fatalf("%+v", list)
	}
	// A forge folder lists all built-ins as user workflows, off by default.
	json.Unmarshal(c.call(t, 4, "workflows/list", map[string]any{"folder": folderURL}), &list)
	if len(list) != 5 || list[0].IsEnabled || list[0].AwaitingApproval != nil || list[4].Workflow.Name != "Work an issue" || list[0].Scope == nil || *list[0].Scope != "user" {
		t.Fatalf("%+v", list)
	}
	for _, id := range readyMadeIDs() {
		if _, err := os.Stat(filepath.Join(userFolder, id+".md")); err != nil {
			t.Fatalf("built-in %s was not installed in the user folder: %v", id, err)
		}
	}
	var userList []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 5, "workflows/list", map[string]any{"scope": "user"}), &userList)
	if len(userList) != 5 || userList[0].Content == nil || userList[0].Scope == nil || *userList[0].Scope != "user" {
		t.Fatalf("user workflows: %+v", userList)
	}

	// Enabling a folder copy changes only that folder's record.
	var s wire.WorkflowSummary
	original, _ := os.ReadFile(filepath.Join(userFolder, "work-an-issue.md"))
	json.Unmarshal(c.call(t, 6, "workflows/enable", map[string]any{"folder": folderURL, "workflowID": "work-an-issue", "enabled": true}), &s)
	if !s.IsEnabled || s.AwaitingApproval != nil || s.DeniedHere != nil {
		t.Fatalf("%+v", s)
	}
	after, _ := os.ReadFile(filepath.Join(userFolder, "work-an-issue.md"))
	if string(original) != string(after) {
		t.Fatal("enabling the folder copy changed the user's file")
	}
	other, err := d.oneWorkflow(second, "work-an-issue")
	if err != nil || other.IsEnabled {
		t.Fatalf("other folder state: %+v, %v", other, err)
	}

	// A folder file with the same ID takes precedence.
	folderCopy := "---\nname: Folder copy\non: manual\n---\nFolder-only prompt.\n"
	folderPath := filepath.Join(workflowsFolder(first), "work-an-issue.md")
	os.MkdirAll(filepath.Dir(folderPath), 0o755)
	os.WriteFile(folderPath, []byte(folderCopy), 0o644)
	d.rescanWorkflows(first)
	folderSummary, err := d.oneWorkflow(first, "work-an-issue")
	if err != nil || folderSummary.Scope == nil || *folderSummary.Scope != "folder" || folderSummary.Workflow.Name != "Folder copy" {
		t.Fatalf("folder precedence: %+v, %v", folderSummary, err)
	}

	// Deleting a built-in records its ID, so the next scan does not restore it.
	userURL := store.FolderURL(home)
	c.call(t, 7, "workflows/delete", map[string]any{"folder": userURL, "workflowID": "answer-a-sign-up-code"})
	d.workflowMu.Lock()
	d.scanLocked()
	_, found := d.workflowFiles[home]["answer-a-sign-up-code"]
	d.workflowMu.Unlock()
	if found {
		t.Fatal("deleted built-in returned")
	}
	content := "---\non: manual\n---\nA custom user workflow.\n"
	var custom wire.WorkflowSummary
	if err := json.Unmarshal(c.call(t, 8, "workflows/write", map[string]any{"workflowID": "custom-workflow", "content": content}), &custom); err != nil {
		t.Fatal(err)
	}
	if custom.Content == nil || *custom.Content != content || custom.Scope == nil || *custom.Scope != "user" {
		t.Fatalf("new user workflow: %+v", custom)
	}
	json.Unmarshal(c.call(t, 9, "workflows/list", map[string]any{"folder": folderURL}), &list)
	for _, summary := range list {
		if summary.Workflow.WorkflowID == "custom-workflow" {
			if summary.IsEnabled || summary.Scope == nil || *summary.Scope != "user" {
				t.Fatalf("new user workflow state: %+v", summary)
			}
			return
		}
	}
	t.Fatalf("new user workflow is not listed off in the forge folder: %+v", list)
}

func fileHas(t *testing.T, path, want string) bool {
	t.Helper()
	b, err := os.ReadFile(path)
	return err == nil && string(b) == want
}

func TestReadyMadeSkillIsInstalledWhenItsWorkflowAlreadyExists(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	id := "work-an-issue"
	path := filepath.Join(workflowsFolder(home), id+".md")
	original := []byte("---\non: manual\n---\nMy workflow.\n")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, original, 0o644); err != nil {
		t.Fatal(err)
	}
	c.call(t, 1, "workflows/list", map[string]any{"scope": "user"})
	if got, err := os.ReadFile(path); err != nil || string(got) != string(original) {
		t.Fatalf("existing workflow was changed: %q, %v", got, err)
	}
	_, skill := readyMadeText(id)
	if got, err := os.ReadFile(filepath.Join(home, ".agents", "skills", id, "SKILL.md")); err != nil || string(got) != skill {
		t.Fatalf("built-in skill was not installed: %q, %v", got, err)
	}
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

// Answer a sign-up code (#1780) hears only the email server, one trigger per allowlisted
// sender the receiving server authenticated, and its skill names the tools it uses, never
// one that sends mail, and passes on only a code.
func TestAnswerASignUpCodeHearsOnlyItsSenders(t *testing.T) {
	text, skill := readyMadeText("answer-a-sign-up-code")
	w := parseWorkflow(text, "answer-a-sign-up-code", "/p")
	if len(w.Triggers) < 2 {
		t.Fatalf("triggers: %+v", w.Triggers)
	}
	for _, tr := range w.Triggers {
		mt, ok := serverTrigger(tr)
		raw, _ := json.Marshal(tr)
		if triggerName(tr) != "email.received" || !ok || !slices.Equal(mt.servers, []string{"email"}) || !strings.Contains(string(raw), `"from"`) {
			t.Fatalf("trigger: %s", raw)
		}
		// Every sender must be authenticated, and GitHub and GitLab only by their no-reply
		// address: their whole domains also send notifications that strangers write.
		args := string(mustRaw(mt.arguments))
		wholeForge := strings.Contains(args, "*") && (strings.Contains(args, "github.com") || strings.Contains(args, "gitlab.com"))
		if !strings.Contains(args, `"authenticated":"true"`) || wholeForge {
			t.Fatalf("trigger arguments: %s", args)
		}
	}
	if !strings.Contains(skill, "^[A-Za-z0-9-]{4,12}$") || strings.Contains(skill, "<subject>") {
		t.Error("the skill must send only a code of that shape, and never the subject")
	}
	for _, tool := range []string{"read_message", "mark_read", "list_sessions", "message_session"} {
		if !strings.Contains(skill, "`"+tool+"`") {
			t.Errorf("the skill does not name %s", tool)
		}
	}
	if strings.Contains(skill, "send_") {
		t.Error("the skill names a tool that sends")
	}
}

// Shutdown ends the workflow clock (#2823): on a context nobody cancels, a stopped host's
// tick scanned again and wrote the ready-made skills into the next test's personal home,
// which AGENTS_PERSONAL_HOME names, while its TempDir was being removed.
func TestShutdownEndsTheWorkflowClock(t *testing.T) {
	d, _ := start(t, t.TempDir())
	d.Shutdown()
	select {
	case <-d.clockStop:
	default:
		t.Fatal("the clock was not told to stop")
	}
	ended := make(chan struct{})
	go func() { d.clockRunning.Wait(); close(ended) }()
	select {
	case <-ended:
	case <-time.After(time.Second):
		t.Fatal("the clock still runs")
	}
}
