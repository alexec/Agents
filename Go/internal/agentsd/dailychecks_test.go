package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
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

// The Daily checks workflow is the home folder's, runs on one machine, in plan mode, every 4
// hours but the summary's.
func TestDailyChecksIsTheHomeFolders(t *testing.T) {
	text, skill := readyMadeText(dailyChecksID)
	w := parseWorkflow(text, dailyChecksID, "/p")
	if w.Settings.PermissionMode == nil || *w.Settings.PermissionMode != "plan" || len(w.Triggers) != 5 {
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
