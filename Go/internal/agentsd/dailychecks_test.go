package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The read-only checks (#3355): only the Daily checks session reads the quiet folders and
// keeps suggestions, the newest of a folder and title in place of the old one, and the next
// summary lists them.
func TestDailyChecksKeepSuggestionsForTheSummary(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	checks, summary := dailyChecksID, dailySummaryID
	me := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &checks })
	writer := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &summary })
	busy, quiet := t.TempDir(), t.TempDir()
	seeded(t, d, busy, nil)
	seeded(t, d, quiet, func(a *wire.Agent) { a.LastActivityAt = now() - 3*24*3600 })

	if _, err := d.dailyChecks(writer.ID, map[string]json.RawMessage{"action": jsonString("collect")}); err == nil {
		t.Fatal("a session that is not the daily checks' read the quiet folders")
	}
	at := time.Now()
	facts, err := d.dailyChecks(me.ID, map[string]json.RawMessage{"action": jsonString("collect")})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(facts, "1 of ") || !strings.Contains(facts, "no gh") {
		t.Fatalf("%s", facts)
	}
	if got := d.quietFolders(at.Add(-time.Hour)); !slices.Equal(got, []string{quiet}) {
		t.Fatalf("quiet folders %v", got)
	}
	if r := readChecks(home); r.CheckedAt.Before(at.Add(-time.Second)) {
		t.Fatalf("the check did not start a new one: %+v", r)
	}

	suggest := func(folder, title string, urgent bool) (string, error) {
		args := map[string]json.RawMessage{"action": jsonString("suggest"), "folder": jsonString(folder),
			"title": jsonString(title), "prompt": jsonString("Find why CI fails on main and fix it on a branch.")}
		if urgent {
			args["urgent"] = json.RawMessage("true")
		}
		return d.dailyChecks(me.ID, args)
	}
	if _, err := suggest(t.TempDir(), "CI fails on main", false); err == nil {
		t.Fatal("a folder that is not on this machine was kept")
	}
	if _, err := suggest(quiet, " ", false); err == nil {
		t.Fatal("a suggestion with no title was kept")
	}
	if _, err := suggest(quiet, "CI fails on main", false); err != nil {
		t.Fatal(err)
	}
	said, err := suggest(quiet, "CI fails on main", true)
	if err != nil || strings.Contains(said, "No notice") {
		t.Fatalf("%q, %v", said, err)
	}
	if r := readChecks(home); len(r.Suggestions) != 1 || !r.Suggestions[0].Urgent {
		t.Fatalf("the newer suggestion did not replace the older one: %+v", r.Suggestions)
	}
	if st, err := os.Stat(filepath.Dir(checksPath(home))); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("%v %v", st, err)
	}

	page, err := d.dailySummary(writer.ID, map[string]json.RawMessage{"action": jsonString("collect")})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(page, "## Found by the checks") || !strings.Contains(page, `Urgent: "CI fails on main" in `+filepath.Base(quiet)) {
		t.Fatalf("%s", page)
	}
}

// What gh says is wrong in a quiet folder: the newest failed run of a workflow on the default
// branch, a pull request in conflict or a week old, and an issue that no session has.
func TestForgeChecksReadGH(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerAgent, AddedAt: now()}}
	})
	at := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	gh := filepath.Join(t.TempDir(), "gh")
	script := `#!/bin/sh
case "$1 $2" in
"repo view") echo '{"defaultBranchRef":{"name":"main"}}' ;;
"run list") echo '[{"workflowName":"CI","conclusion":"failure","url":"https://x/run/2","createdAt":"2026-11-03T10:00:00Z"},
  {"workflowName":"CI","conclusion":"success","url":"https://x/run/1","createdAt":"2026-11-03T09:00:00Z"},
  {"workflowName":"Docs","conclusion":"","url":"https://x/run/4","createdAt":"2026-11-03T11:00:00Z"},
  {"workflowName":"Docs","conclusion":"success","url":"https://x/run/3","createdAt":"2026-11-03T08:00:00Z"}]' ;;
"pr list") echo '[{"number":1,"title":"Fresh","url":"https://x/pull/1","updatedAt":"2026-11-03T00:00:00Z","mergeable":"MERGEABLE"},
  {"number":2,"title":"Old","url":"https://x/pull/2","updatedAt":"2026-10-20T00:00:00Z","mergeable":"MERGEABLE"},
  {"number":3,"title":"Clash","url":"https://x/pull/3","updatedAt":"2026-11-03T00:00:00Z","mergeable":"CONFLICTING"},
  {"number":4,"title":"Draft","url":"https://x/pull/4","updatedAt":"2026-10-01T00:00:00Z","mergeable":"MERGEABLE","isDraft":true}]' ;;
"issue list") echo '[{"number":7,"title":"Taken","url":"https://x/issues/7"},{"number":8,"title":"Nobody","url":"https://x/issues/8"}]' ;;
esac
`
	if err := os.WriteFile(gh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(d.forgeChecks(gh, folder, at), "\n")
	for _, want := range []string{`CI on main fails: the newest "CI" run`, "https://x/run/2",
		`#2 "Old" has not changed for 14 days`, `#3 "Clash" is in conflict`, `Issue #8 "Nobody"`} {
		if !strings.Contains(got, want) {
			t.Fatalf("no %q in:\n%s", want, got)
		}
	}
	for _, not := range []string{"Docs", "Fresh", "Draft", "Taken"} {
		if strings.Contains(got, not) {
			t.Fatalf("%q listed in:\n%s", not, got)
		}
	}
}

// Off turns the Daily checks off too: they report through the summary (#3355).
func TestDailySummaryOffTurnsChecksOff(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	if _, err := d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummary, At: "08:00"}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(home), WorkflowID: dailyChecksID, Enabled: true}, "person"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeOff, At: "08:00"}); err != nil {
		t.Fatal(err)
	}
	if w, err := d.oneWorkflow(home, dailyChecksID); err != nil || w.IsEnabled {
		t.Fatalf("%+v, %v", w, err)
	}
}

// #3395: Summary and checks turns the Daily checks on every few hours from the summary's time,
// never at it; a new time or interval moves them, and Summary only turns them off.
func TestSummaryAndChecksSchedulesTheChecks(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	hours := func() []string {
		t.Helper()
		w, err := d.oneWorkflow(home, dailyChecksID)
		if err != nil || !w.IsEnabled || w.AwaitingApproval != nil {
			t.Fatalf("%+v, %v", w, err)
		}
		var got []string
		for _, tr := range w.Workflow.Triggers {
			sc := tr.Schedule.Value
			got = append(got, fmt.Sprintf("%02d:%02d", sc.Hours[0], sc.StartMinute))
		}
		return got
	}
	s, err := d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummaryAndChecks, At: "08:00"})
	if err != nil || s.Mode != wire.DailySummaryModeSummaryAndChecks || s.ChecksEvery == nil || *s.ChecksEvery != 4 {
		t.Fatalf("%+v, %v", s, err)
	}
	if got := hours(); !slices.Equal(got, []string{"00:00", "04:00", "12:00", "16:00", "20:00"}) {
		t.Fatal(got)
	}
	six := int64(6)
	s, err = d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummaryAndChecks, At: "09:30", ChecksEvery: &six})
	if err != nil || *s.ChecksEvery != 6 || s.At != "09:30" {
		t.Fatalf("%+v, %v", s, err)
	}
	if got := hours(); !slices.Equal(got, []string{"03:30", "15:30", "21:30"}) {
		t.Fatal(got)
	}
	text, _ := os.ReadFile(filepath.Join(home, ".agents", "workflows", dailyChecksID+".md"))
	if !strings.Contains(string(text), "when-done: archive") || !strings.Contains(string(text), "permission-mode: ask") {
		t.Fatalf("the rest of the metadata went:\n%s", text)
	}
	five := int64(5)
	if _, err := d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummaryAndChecks, At: "09:30", ChecksEvery: &five}); err == nil {
		t.Fatal("every 5 hours was taken")
	}
	s, err = d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummary, At: "09:30"})
	if err != nil || s.Mode != wire.DailySummaryModeSummary || *s.ChecksEvery != 6 {
		t.Fatalf("%+v, %v", s, err)
	}
	if w, err := d.oneWorkflow(home, dailyChecksID); err != nil || w.IsEnabled {
		t.Fatalf("%+v, %v", w, err)
	}
}

// The Daily checks workflow is the home folder's, runs on one machine, in ask mode, every 4
// hours but the summary's.
func TestDailyChecksIsTheHomeFolders(t *testing.T) {
	text, skill := readyMadeText(dailyChecksID)
	w := parseWorkflow(text, dailyChecksID, "/p")
	if w.Settings.PermissionMode == nil || *w.Settings.PermissionMode != "ask" || len(w.Triggers) != 5 {
		t.Fatalf("%+v", w)
	}
	for _, tr := range w.Triggers {
		if tr.Schedule == nil || tr.Schedule.Value.Hours[0]%4 != 0 || tr.Schedule.Value.Hours[0] == 8 {
			t.Fatalf("%+v", tr)
		}
	}
	if !strings.Contains(skill, "`check_folders`") || !oneMachineWorkflows[dailyChecksID] {
		t.Fatal(skill)
	}
}

// suggestionsIn is pins/list's For Review suggestions of a folder (#3331).
func suggestionsIn(t *testing.T, c *conn, id int, folder string) []wire.CheckSuggestion {
	t.Helper()
	var listed []wire.FolderPins
	json.Unmarshal(c.call(t, id, "pins/list", wire.Empty{}), &listed)
	for _, pp := range listed {
		if filepath.Clean(store.FolderPath(pp.Folder)) == filepath.Clean(folder) {
			return pp.Suggestions
		}
	}
	return nil
}

// #3331: every client lists the checks' suggestions in For Review, with the folder's pins,
// newest first; Start opens a session with its prompt and takes it out; a dismissed one never
// comes back, not in For Review, the next summary or a later check.
func TestForReviewListsTheChecksSuggestionsWithStartAndDismiss(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	home := t.TempDir()
	d.PersonalHome = home
	checks, summary := dailyChecksID, dailySummaryID
	me := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &checks })
	writer := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &summary })
	quiet := t.TempDir()
	seeded(t, d, quiet, func(a *wire.Agent) { a.LastActivityAt = now() - 3*24*3600 })
	suggest := func(title, prompt string) string {
		said, err := d.dailyChecks(me.ID, map[string]json.RawMessage{"action": jsonString("suggest"), "folder": jsonString(quiet),
			"title": jsonString(title), "prompt": jsonString(prompt), "link": jsonString("https://github.com/alexec/agents/actions/runs/1")})
		if err != nil {
			t.Fatal(err)
		}
		return said
	}
	suggest("CI fails on main", "Find why CI fails on main and fix it on a branch.")
	suggest("PR #12 is in conflict", "Rebase PR #12 onto main.")

	got := suggestionsIn(t, c, 1, quiet)
	if len(got) != 2 || got[0].Title != "PR #12 is in conflict" || got[1].Title != "CI fails on main" ||
		got[0].ID == "" || got[0].ID == got[1].ID || got[1].Link == nil {
		t.Fatalf("For Review's suggestions: %+v", got)
	}
	if again := suggestionsIn(t, c, 2, quiet); again[0].ID != got[0].ID {
		t.Fatalf("an id changed between two reads: %s %s", again[0].ID, got[0].ID)
	}
	var snapshot wire.CatchUpSnapshot
	json.Unmarshal(c.call(t, 3, "client/catchUp", wire.CatchUpRequest{Parts: []string{"pins"}}), &snapshot)
	caught := 0
	for _, pp := range snapshot.Pins {
		caught += len(pp.Suggestions)
	}
	if caught != 2 {
		t.Fatalf("the catch-up's suggestions: %d", caught)
	}

	// Dismiss: gone, kept out of the summary, and not kept again by a later check.
	folder := store.FolderURL(quiet)
	c.call(t, 4, "suggestions/dismiss", wire.SuggestionRequest{Folder: folder, ID: got[1].ID})
	if left := suggestionsIn(t, c, 5, quiet); len(left) != 1 || left[0].ID != got[0].ID {
		t.Fatalf("after Dismiss: %+v", left)
	}
	if said := suggest("CI fails on main", "Fix CI."); !strings.Contains(said, "dismissed") {
		t.Fatalf("a dismissed suggestion was kept again: %q", said)
	}
	if left := suggestionsIn(t, c, 6, quiet); len(left) != 1 {
		t.Fatalf("a dismissed suggestion came back: %+v", left)
	}
	page, err := d.dailySummary(writer.ID, map[string]json.RawMessage{"action": jsonString("collect")})
	if err != nil || strings.Contains(page, "CI fails on main") || !strings.Contains(page, "PR #12 is in conflict") {
		t.Fatalf("the summary's facts: %v\n%s", err, page)
	}
	if e := c.callError(t, 7, "suggestions/dismiss", wire.SuggestionRequest{Folder: folder, ID: got[1].ID}); e == nil {
		t.Fatal("a suggestion dismissed twice")
	}

	// Start: a session in its folder with its prompt, and the suggestion goes.
	var id wire.UUID
	json.Unmarshal(c.call(t, 8, "suggestions/start", wire.SuggestionRequest{Folder: folder, ID: got[0].ID}), &id)
	a := d.Store.Agent(id)
	if a == nil || filepath.Clean(folderPath(a)) != filepath.Clean(quiet) {
		t.Fatalf("the started session: %+v", a)
	}
	waitFor(t, "its prompt", func() bool {
		prompts := userMessages(d, id)
		return len(prompts) > 0 && strings.Contains(prompts[0], "Rebase PR #12 onto main.")
	})
	if left := suggestionsIn(t, c, 9, quiet); len(left) != 0 {
		t.Fatalf("a started suggestion is still listed: %+v", left)
	}
	if e := c.callError(t, 10, "suggestions/start", wire.SuggestionRequest{Folder: folder, ID: got[0].ID}); e == nil {
		t.Fatal("a suggestion started twice")
	}
}
