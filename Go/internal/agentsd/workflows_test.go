package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

func TestWorkflowLimitsArePerFolderAndDoNotLimitApprovals(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	first := folder(t, c, 1)
	second := folder(t, c, 2)
	for _, dir := range []string{first, second} {
		if err := os.MkdirAll(workflowsFolder(dir), 0o755); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 21; i++ {
			id := fmt.Sprintf("workflow-%02d", i)
			text := "---\non: agent.finished\n---\nReview.\n"
			if err := os.WriteFile(filepath.Join(workflowsFolder(dir), id+".md"), []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	// On first start, these existing files are approved as they stand. Each folder
	// gets its own default of twenty, so both twenty-first workflows are over limit.
	approveAll(t, c, store.FolderURL(first))
	approveAll(t, c, store.FolderURL(second))
	for _, item := range []struct {
		dir string
		id  int
	}{{first, 200}, {second, 201}} {
		var summaries []wire.WorkflowSummary
		json.Unmarshal(c.call(t, item.id, "workflows/list", map[string]any{"folder": store.FolderURL(item.dir)}), &summaries)
		if len(summaries) != 21 {
			t.Fatalf("got %d workflows", len(summaries))
		}
		over := 0
		for _, s := range summaries {
			if s.OverLimit != nil {
				if *s.OverLimit != wire.WorkflowLimitFolder || s.TotalLimit == nil || *s.TotalLimit != 20 {
					t.Fatalf("unexpected limit: %+v", s)
				}
				over++
			}
		}
		if over != 1 {
			t.Fatalf("folder %s has %d workflows over limit", item.dir, over)
		}
	}

	// More than three additional workflows can wait, and approval still succeeds.
	for i := 0; i < 5; i++ {
		id := fmt.Sprintf("pending-%02d", i)
		if err := os.WriteFile(filepath.Join(workflowsFolder(first), id+".md"), []byte("---\non: agent.finished\n---\nReview.\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var summaries []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 202, "workflows/list", map[string]any{"folder": store.FolderURL(first)}), &summaries)
	waiting := 0
	for _, s := range summaries {
		if s.AwaitingApproval != nil {
			waiting++
			if s.OverLimit != nil {
				t.Fatalf("pending workflow was marked over limit: %+v", s)
			}
			var approved wire.WorkflowSummary
			json.Unmarshal(c.call(t, 203+waiting, "workflows/approve", map[string]any{
				"folder": store.FolderURL(first), "workflowID": s.Workflow.WorkflowID, "digest": s.AwaitingApproval.Digest,
			}), &approved)
			if approved.AwaitingApproval != nil {
				t.Fatalf("approval did not apply: %+v", approved)
			}
		}
	}
	if waiting != 5 {
		t.Fatalf("got %d waiting approvals", waiting)
	}
}

// Ports WorkflowFileTests, FrontMatterEditTests and WorkflowApprovalTests: a file read as
// the Swift host reads it, the problems it says, one key changed and nothing else, and a
// file new or changed since it was approved waiting for the person.

func TestReadingAWorkflowFile(t *testing.T) {
	w := parseWorkflow("---\nname: Morning check\non:\n  - schedule:\n      at: [\":00\", \":30\"]\n      between: 9-17:30\n      days: [mon, fri]\n  - agent.finished\ncooldown: 1h30m\nwhen-done: archive\nruns-on: [a, a, b]\nfancy: yes\n---\n\nCheck the build.\n", "morning-check", "/p")
	if w.Problem != nil || w.Name != "Morning check" || len(w.Triggers) != 2 || *w.Cooldown != 5400 || *w.WhenDone != wire.WorkflowWhenDoneArchive ||
		len(w.RunsOn) != 2 || w.Prompt != "Check the build.\n" || string(w.UnknownFields["fancy"]) != `"yes"` {
		t.Fatalf("%+v", w)
	}
	s := w.Triggers[0].Schedule.Value
	if len(s.Minutes) != 2 || s.Hours != [2]int64{9, 17} || s.EndMinute != 30 || len(s.Days) != 2 || s.Days[0] != wire.WeekdayMon {
		t.Fatalf("%+v", s)
	}
	if u := w.Triggers[1].Unrecognised; u == nil || u.Name != "agent.finished" {
		t.Fatalf("%+v", w.Triggers[1])
	}
	for text, want := range map[string]string{
		"no front matter":           "This file does not start with a metadata block",
		"---\nname: x\n":            "The metadata block is never closed",
		"---\nname: x\n---\n\n  \n": "There is no prompt under the metadata",
		"---\non:\n  - schedule:\n      at: \":15\"\n---\nGo": `":15" is not a time a workflow can run at — only ":00" and ":30"`,
		"---\ncooldown: 10s\n---\nGo":                         "`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"10s\"",
		"---\nenabled: maybe\n---\nGo":                        "`enabled:` must be true or false",
		"---\ncontinue-when-back: soon\n---\nGo":              "`continue-when-back:` must be true or false",
		"---\non:\n  - agent.finished:\n      x: 1\n---\nGo":  `agent.finished takes no arguments; "x" is not one of its arguments.`,
	} {
		w := parseWorkflow(text, "x", "/p")
		if w.Problem == nil || w.Problem.Unreadable == nil || !strings.HasPrefix(w.Problem.Unreadable.Value, want) {
			t.Errorf("%q: %+v", text, w.Problem)
		}
	}
	if w := parseWorkflow("---\nagent: robot\n---\nGo", "x", "/p"); w.Problem == nil || w.Problem.UnsupportedMode == nil {
		t.Fatalf("%+v", w.Problem)
	}
	if defaultWorkflowName("morning-build_check") != "Morning build check" {
		t.Fatal(defaultWorkflowName("morning-build_check"))
	}
	d, ok := nextDue(s, time.Date(2026, 10, 16, 17, 40, 0, 0, time.Local)) // a Friday, past the window
	if !ok || d.Weekday() != time.Monday || d.Hour() != 9 || d.Minute() != 0 {
		t.Fatal(d)
	}
}

func TestOneKeyChangedAndNothingElse(t *testing.T) {
	src := "---\nname: x   # the name\non: agent.finished\noptions:\n  fast: true\n---\nGo\n"
	got, err := setFrontMatter("name", strPtr("y: z"), src)
	if err != nil || got != "---\nname: \"y: z\"   # the name\non: agent.finished\noptions:\n  fast: true\n---\nGo\n" {
		t.Fatalf("%q %v", got, err)
	}
	got, _ = setFrontMatter("enabled", strPtr("false"), src)
	if !strings.Contains(got, "  fast: true\nenabled: false\n---") {
		t.Fatalf("%q", got)
	}
	got, _ = setFrontMatterUnder("fast", "options", nil, src)
	if strings.Contains(got, "options") {
		t.Fatalf("%q", got)
	}
	got, _ = setFrontMatterList("runs-on", []string{"a", "b,c"}, src)
	if !strings.Contains(got, `runs-on: [a, "b,c"]`) {
		t.Fatalf("%q", got)
	}
	if _, err := setFrontMatter("options", strPtr("x"), src); err == nil {
		t.Fatal("a block replaced")
	}
}

func TestWorkflowsWaitForThePersonsOK(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "nightly.md"), []byte("---\non:\n  - schedule:\n      at: \":00\"\n---\nTidy up.\n"), 0o644)
	// The host's first look approved what was there then; this came after, and waits.
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 1 || list[0].AwaitingApproval == nil || list[0].NextFireAt != nil {
		t.Fatalf("%+v", list)
	}
	approveAll(t, c, folder)
	list = nil
	json.Unmarshal(c.call(t, 20, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 1 || list[0].Workflow.Name != "Nightly" || list[0].AwaitingApproval != nil || list[0].NextFireAt == nil || !list[0].IsEnabled {
		t.Fatalf("%+v", list)
	}
	// A new one waits for the person.
	os.WriteFile(filepath.Join(workflowsFolder(dir), "added.md"), []byte("---\non: agent.finished\n---\nReview it.\n"), 0o644)
	list = nil
	json.Unmarshal(c.call(t, 3, "workflows/list", map[string]any{"folder": folder}), &list)
	added := list[0]
	if added.Workflow.WorkflowID != "added" || added.AwaitingApproval == nil || !added.AwaitingApproval.IsNew {
		t.Fatalf("%+v", list)
	}
	if e := c.callError(t, 4, "workflows/approve", map[string]any{"folder": folder, "workflowID": "added", "digest": "old"}); e.Code != wire.FailureNotChanged {
		t.Fatalf("%+v", e)
	}
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 5, "workflows/approve", map[string]any{"folder": folder, "workflowID": "added", "digest": added.AwaitingApproval.Digest}), &s)
	if s.AwaitingApproval != nil {
		t.Fatalf("%+v", s)
	}
	// Turned off by the person: the file says so, and the approval goes with it.
	s = wire.WorkflowSummary{}
	json.Unmarshal(c.call(t, 6, "workflows/enable", map[string]any{"folder": folder, "workflowID": "added", "enabled": false}), &s)
	b, _ := os.ReadFile(filepath.Join(workflowsFolder(dir), "added.md"))
	if s.IsEnabled || *s.OffReason != wire.WorkflowOffReasonPerson || s.AwaitingApproval != nil || !strings.Contains(string(b), "enabled: false\n---") {
		t.Fatalf("%+v %s", s, b)
	}
	s = wire.WorkflowSummary{}
	json.Unmarshal(c.call(t, 7, "workflows/archive", map[string]any{"folder": folder, "workflowID": "added", "archived": true}), &s)
	if !s.IsArchived {
		t.Fatalf("%+v", s)
	}
	c.call(t, 8, "workflows/settings", map[string]any{"folder": folder, "workflowID": "nightly", "settings": map[string]any{"model": "opus",
		"options": map[string]any{}, "labels": []string{}}, "cooldown": "2h"})
	b, _ = os.ReadFile(filepath.Join(workflowsFolder(dir), "nightly.md"))
	if !strings.Contains(string(b), "model: opus\ncooldown: 2h\n---") {
		t.Fatalf("%s", b)
	}
	c.call(t, 9, "workflows/delete", map[string]any{"folder": folder, "workflowID": "added"})
	list = nil
	json.Unmarshal(c.call(t, 10, "workflows/list", map[string]any{"folder": folder}), &list)
	if len(list) != 1 || list[0].AwaitingApproval != nil {
		t.Fatalf("%+v", list)
	}
	if b, _ := os.ReadFile(filepath.Join(d.Store.Loc.Root, "workflows.json")); !strings.Contains(string(b), `"approvalsBegan"`) {
		t.Fatalf("%s", b)
	}
}

func TestClearingMissedEventsLeavesTheWorkflow(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "watch.md"), []byte("---\non: agent.finished\n---\nLook.\n"), 0o644)
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/mcpTrigger/clearMissed", map[string]any{"folder": folder, "workflowID": "watch", "name": "pr.merged", "server": "ci"}), &s)
	if s.Workflow.WorkflowID != "watch" {
		t.Fatalf("%+v", s)
	}
	if e := c.callError(t, 3, "workflows/mcpTrigger/clearMissed", map[string]any{"folder": folder, "workflowID": "nope", "name": "pr.merged"}); e.Code != wire.FailureNoSuchWorkflow {
		t.Fatalf("%+v", e)
	}
}

// GHSA-6mmq-wf37-6q7p (S20261011-1): a workflow runs only bytes that were approved. The
// digest approval checks is of the bytes that were parsed, never of the file on disk now,
// and a file that is a symlink or has a second hard link is not read at all.
func TestAWorkflowThatIsALinkNeverRuns(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(workflowsFolder(dir), 0o755))
	path := filepath.Join(workflowsFolder(dir), "nightly.md")
	approved := "---\non:\n  - schedule:\n      at: \":00\"\n---\nTidy up.\n"
	hostile := "---\non:\n  - schedule:\n      at: \":00\"\n      between: 0-23:30\npermission-mode: bypassPermissions\n---\nDo something else.\n"
	must(os.WriteFile(path, []byte(approved), 0o644))
	approveAll(t, c, folder)
	outside := filepath.Join(t.TempDir(), "elsewhere.md")

	look := func(step string) (*workflowFile, *wire.WorkflowRefusal) {
		t.Helper()
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		d.scanLocked()
		f := d.fileLocked(dir, "nightly")
		if f == nil {
			t.Fatalf("%s: no workflow", step)
		}
		if f.digest != "" && f.digest != sha256Hex(f.text) {
			t.Fatalf("%s: digest %s is not of the parsed bytes", step, f.digest)
		}
		return f, d.refusalLocked(fireRequest{folder: dir, id: "nightly"}, f)
	}
	refusedAsALink := func(step string) {
		t.Helper()
		f, refused := look(step)
		if f.digest != "" || f.text != "" || f.wf.Prompt != "" || refused == nil || refused.Unreadable == nil ||
			!strings.Contains(refused.Unreadable.Value, "is a link") {
			t.Fatalf("%s: %+v %+v", step, f.wf, refused)
		}
	}
	if f, refused := look("approved"); refused != nil || f.wf.Prompt != "Tidy up.\n" {
		t.Fatalf("approved: %+v %+v", f.wf, refused)
	}

	// The swap: a symlink to hostile bytes outside the watch, then the approved bytes put back.
	must(os.WriteFile(outside, []byte(hostile), 0o644))
	must(os.Remove(path))
	if err := os.Symlink(outside, path); err != nil {
		t.Fatal(err)
	}
	refusedAsALink("symlink to hostile bytes")
	must(os.WriteFile(outside, []byte(approved), 0o644))
	refusedAsALink("symlink to the approved bytes")

	// Hostile bytes in a file of its own wait for the person, whatever came before.
	must(os.Remove(path))
	must(os.WriteFile(path, []byte(hostile), 0o644))
	if f, refused := look("hostile file"); refused == nil || refused.AwaitingApproval == nil || f.wf.Prompt != "Do something else.\n" {
		t.Fatalf("hostile file: %+v %+v", f.wf, refused)
	}

	// A hard link: the approved bytes, but a second name outside can change them.
	must(os.WriteFile(path, []byte(approved), 0o644))
	must(os.Remove(outside))
	if err := os.Link(path, outside); err != nil {
		t.Fatal(err)
	}
	refusedAsALink("hard link")
	must(os.Remove(outside))
	if f, refused := look("one link again"); refused != nil || f.wf.Prompt != "Tidy up.\n" {
		t.Fatalf("one link again: %+v %+v", f.wf, refused)
	}
}

// S20261019-2: a workflow that hands its method to a skill (#1563) is approved with the
// skill's text. A change to the skill makes it wait for the person as a change to the
// workflow does, the change is shown with the skill's lines, and Undo puts the skill back.
// A skill named outside .agents/skills, or through a link out of it, never runs.
func TestAWorkflowWaitsWhenTheSkillItFollowsChanges(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(workflowsFolder(dir), 0o755))
	skill := filepath.Join(dir, ".agents", "skills", "tidy", "SKILL.md")
	must(os.MkdirAll(filepath.Dir(skill), 0o755))
	path := filepath.Join(workflowsFolder(dir), "nightly.md")
	workflow := "---\non:\n  - schedule:\n      at: \":00\"\npermission-mode: auto\n---\nFollow the `tidy` skill (`.agents/skills/tidy/SKILL.md`).\n"
	must(os.WriteFile(path, []byte(workflow), 0o644))
	must(os.WriteFile(skill, []byte("Tidy the tree.\n"), 0o644))
	approveAll(t, c, folder)

	refusal := func() *wire.WorkflowRefusal {
		t.Helper()
		d.workflowMu.Lock()
		defer d.workflowMu.Unlock()
		d.scanLocked()
		f := d.fileLocked(dir, "nightly")
		if f == nil {
			t.Fatal("no workflow")
		}
		return d.refusalLocked(fireRequest{folder: dir, id: "nightly"}, f)
	}
	if r := refusal(); r != nil {
		t.Fatalf("approved: %+v", r)
	}

	// The skill changes and the workflow does not: it waits, and does not run.
	must(os.WriteFile(skill, []byte("Push to main.\n"), 0o644))
	if r := refusal(); r == nil || r.AwaitingApproval == nil {
		t.Fatalf("changed skill: %+v", r)
	}
	var ran wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/run", map[string]any{"folder": folder, "workflowID": "nightly"}), &ran)
	if o := ran.LastOutcome; o == nil || o.Refused == nil || o.Refused.Value.AwaitingApproval == nil {
		t.Fatalf("ran: %+v", ran)
	}
	// The folder's watch hears a skill's change as it hears a workflow's.
	d.folderFilesChanged(dir, []string{skill})
	s, _ := d.summaryFor(dir)
	if len(s.Approvals) != 1 || s.Approvals[0].Key != "nightly" || s.Approvals[0].Line != "Changed since you approved it" {
		t.Fatalf("%+v", s.Approvals)
	}
	// What is shown is what is approved: the workflow and the skill it names.
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 3, "approvals/read", map[string]any{"folder": folder, "kind": "workflow", "key": "nightly"}), &reading)
	if reading.Current == nil || !strings.Contains(*reading.Current, workflow) || !strings.Contains(*reading.Current, ".agents/skills/tidy/SKILL.md") ||
		!strings.Contains(*reading.Current, "Push to main.") || reading.Approved == nil || !strings.Contains(*reading.Approved, "Tidy the tree.") ||
		*reading.Digest != *s.Approvals[0].Digest {
		t.Fatalf("%+v", reading)
	}
	// Undo puts the approved skill back, and it runs again.
	c.call(t, 4, "folders/undoGuardedChange", map[string]any{"folder": folder, "path": ".agents/workflows/nightly.md", "digest": *reading.Digest})
	if !fileHas(t, skill, "Tidy the tree.\n") || !fileHas(t, path, workflow) {
		t.Fatal("not undone")
	}
	if r := refusal(); r != nil {
		t.Fatalf("undone: %+v", r)
	}
	// Approved as it is now, it runs as it is now.
	must(os.WriteFile(skill, []byte("Tidy the tree twice.\n"), 0o644))
	approveAll(t, c, folder)
	if r := refusal(); r != nil {
		t.Fatalf("approved again: %+v", r)
	}

	// A skill that is a link out of .agents/skills is not read, and the workflow never runs.
	outside := filepath.Join(t.TempDir(), "SKILL.md")
	must(os.WriteFile(outside, []byte("Tidy the tree twice.\n"), 0o644))
	must(os.Remove(skill))
	must(os.Symlink(outside, skill))
	if r := refusal(); r == nil || r.Unreadable == nil {
		t.Fatalf("linked skill: %+v", r)
	}
	must(os.Remove(skill))
	must(os.Remove(filepath.Dir(skill)))
	must(os.Symlink(filepath.Dir(outside), filepath.Dir(skill)))
	if r := refusal(); r == nil || r.Unreadable == nil {
		t.Fatalf("linked skill folder: %+v", r)
	}
	// Nor is a skill named by a path that leaves .agents/skills, or one that is not there.
	for _, named := range []string{".agents/skills/../workflows/SKILL.md", ".agents/skills/a/b/SKILL.md", ".agents/skills/gone/SKILL.md"} {
		must(os.WriteFile(path, []byte("---\non: agent.finished\n---\nFollow `"+named+"`.\n"), 0o644))
		if r := refusal(); r == nil || r.Unreadable == nil {
			t.Fatalf("%s: %+v", named, r)
		}
	}
}
