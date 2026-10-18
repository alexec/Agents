package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ports WorkflowFileTests, FrontMatterEditTests and WorkflowApprovalTests: a file read as
// the Swift host reads it, the problems it says, one key changed and nothing else, and a
// file new or changed since it was approved waiting for the person.

func TestReadingAWorkflowFile(t *testing.T) {
	w := parseWorkflow("---\nname: Morning check\non:\n  - schedule:\n      at: [\":00\", \":30\"]\n      between: 9-17:30\n      days: [mon, fri]\n  - agent.finished\ncooldown: 1h30m\nwhen-done: archive\nhosts: [a, a, b]\nfancy: yes\n---\n\nCheck the build.\n", "morning-check", "/p")
	if w.Problem != nil || w.Name != "Morning check" || len(w.Triggers) != 2 || *w.Cooldown != 5400 || *w.WhenDone != wire.WorkflowWhenDoneArchive ||
		len(w.Hosts) != 2 || w.Prompt != "Check the build.\n" || string(w.UnknownFields["fancy"]) != `"yes"` {
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
	got, _ = setFrontMatterList("hosts", []string{"a", "b,c"}, src)
	if !strings.Contains(got, `hosts: [a, "b,c"]`) {
		t.Fatalf("%q", got)
	}
	if _, err := setFrontMatter("options", strPtr("x"), src); err == nil {
		t.Fatal("a block replaced")
	}
}

func TestWorkflowsWaitForThePersonsOK(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := project(t, c, 1)
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
	dir := project(t, c, 1)
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
	dir := project(t, c, 1)
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
