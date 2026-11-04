package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The daily summary (#3192): its session collects every folder's facts, and saves a page
// of which the last 3 stay; no other session may.
func TestDailySummaryCollectsAndKeepsThree(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	wid := dailySummaryID
	me := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &wid })
	work := t.TempDir()
	title, died := "Fix the login test", wire.EndedReasonProcessDied
	done := seeded(t, d, work, func(a *wire.Agent) {
		a.Title = &title
		a.SuggestedPrompts = []wire.SuggestedPrompt{{ID: "s", Label: "Ship it", Prompt: "Run ship-app."}}
	})
	stopped := seeded(t, d, work, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateStopped, &died })
	seeded(t, d, work, func(a *wire.Agent) { a.LastActivityAt = now() - 30*24*3600 }) // before the reach

	other := seeded(t, d, work, nil)
	if _, err := d.dailySummary(other.ID, map[string]json.RawMessage{"action": jsonString("collect")}); err == nil {
		t.Fatal("a session that is not the daily summary's collected every folder's facts")
	}
	facts, err := d.dailySummary(me.ID, map[string]json.RawMessage{"action": jsonString("collect")})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`Session "Fix the login test" in ` + filepath.Base(work) + ` done at`, sessionLink(done.ID),
		"its runtime stopped. " + sessionLink(stopped.ID),
		`"Ship it", suggested by "Fix the login test"`,
		"Nothing waits on you.",
	} {
		if !strings.Contains(facts, want) {
			t.Fatalf("no %q in:\n%s", want, facts)
		}
	}
	if strings.Contains(facts, sessionLink(me.ID)) || strings.Count(facts, "done at") != 2 {
		t.Fatalf("its own session, or one from before the reach, is listed:\n%s", facts)
	}

	at := time.Date(2026, 11, 2, 8, 0, 0, 0, time.Local)
	for i := range 4 {
		if _, err := d.saveSummary(me.ID, "# Daily summary\n", "", at.AddDate(0, 0, i)); err != nil {
			t.Fatal(err)
		}
	}
	kept := summaryFiles(home)
	if len(kept) != summariesKept || filepath.Base(kept[0]) != "2026-11-05-0800.md" || filepath.Base(kept[2]) != "2026-11-03-0800.md" {
		t.Fatalf("kept %v", kept)
	}
	if st, err := os.Stat(filepath.Dir(kept[0])); err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("%v %v", st, err)
	}
	if _, err := d.saveSummary(me.ID, "  ", "", at); err == nil {
		t.Fatal("an empty page was saved")
	}
}

// Only the newest daily summary is in For Review (#3352): a new page takes its title, and
// the older runs' pages that nobody opened are marked read; another session's file stays.
func TestOnlyTheNewestSummaryIsForReview(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	wid := dailySummaryID
	unseen := func(a *wire.Agent) { a.FileToSee = &wire.ShownFile{Path: filepath.Join(home, "old.md")} }
	older := seeded(t, d, home, func(a *wire.Agent) { a.StartedByWorkflow = &wid; unseen(a) })
	work := seeded(t, d, t.TempDir(), unseen)
	me := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &wid })

	if _, err := d.saveSummary(me.ID, "Intro\n\n# Daily summary, Tue 3 Nov\n\n## Landed\n", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a := d.Store.Agent(me.ID); a.Title == nil || *a.Title != "Daily summary, Tue 3 Nov" {
		t.Fatalf("title %v", a.Title)
	}
	if d.Store.Agent(older.ID).FileToSee != nil {
		t.Fatal("an older summary stayed in For Review")
	}
	if d.Store.Agent(work.ID).FileToSee == nil {
		t.Fatal("another session's file to see was cleared")
	}
	if got := summaryTitle("no heading\n## Part\n"); got != "" {
		t.Fatalf("title %q from a page with no first heading", got)
	}
}

// Only a session in the home folder is offered write_daily_summary, and the workflow is never
// copied into a project.
func TestDailySummaryIsTheHomeFolders(t *testing.T) {
	has := func(summarizes bool) bool {
		for _, raw := range offeredTools(false, false, false, summarizes) {
			var tool struct{ Name string }
			json.Unmarshal(raw, &tool)
			if tool.Name == "write_daily_summary" {
				return true
			}
		}
		return false
	}
	if has(false) || !has(true) {
		t.Fatal("write_daily_summary offered to the wrong sessions")
	}
	text, skill := readyMadeText(dailySummaryID)
	w := parseWorkflow(text, dailySummaryID, "/p")
	if w.Settings.PermissionMode == nil || *w.Settings.PermissionMode != "plan" || len(w.Triggers) != 1 || w.Triggers[0].Schedule == nil {
		t.Fatalf("%+v", w)
	}
	if !strings.Contains(skill, "`write_daily_summary`") || !oneMachineWorkflows[dailySummaryID] {
		t.Fatal(skill)
	}
}

// The daily summary's control (#3351) is the home folder's Daily summary workflow: Summary turns
// it on at the time asked, Off turns it off and keeps the time.
func TestDailySummaryControlIsTheWorkflow(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	path := filepath.Join(home, ".agents", "workflows", dailySummaryID+".md")

	var s wire.DailySummarySettings
	json.Unmarshal(c.call(t, 1, "dailySummary/settings", map[string]any{}), &s)
	if s.Mode != wire.DailySummaryModeOff || s.At != "08:00" {
		t.Fatalf("%+v", s)
	}
	json.Unmarshal(c.call(t, 2, "dailySummary/setSettings", map[string]any{"mode": "summary", "at": "7:30"}), &s)
	if s.Mode != wire.DailySummaryModeSummary || s.At != "07:30" {
		t.Fatalf("%+v", s)
	}
	text, _ := os.ReadFile(path)
	for _, want := range []string{`at: ":30"`, `between: "07:30-07:30"`, "days: [mon, tue, wed, thu, fri]"} {
		if !strings.Contains(string(text), want) {
			t.Fatalf("no %q in:\n%s", want, text)
		}
	}
	if strings.Contains(string(text), "enabled: false") {
		t.Fatalf("still off:\n%s", text)
	}
	if sum, err := d.oneWorkflow(home, dailySummaryID); err != nil || !sum.IsEnabled || sum.AwaitingApproval != nil {
		t.Fatalf("%+v, %v", sum, err)
	}

	json.Unmarshal(c.call(t, 3, "dailySummary/setSettings", map[string]any{"mode": "off", "at": "07:30"}), &s)
	if s.Mode != wire.DailySummaryModeOff || s.At != "07:30" {
		t.Fatalf("%+v", s)
	}
	if _, err := d.setDailySummarySettings(wire.DailySummarySettings{Mode: wire.DailySummaryModeSummary, At: "07:15"}); err == nil {
		t.Fatal("a time off the half hour was taken")
	}
}

func TestSetScheduleLineRefusesTwo(t *testing.T) {
	two := "---\non:\n  - schedule:\n      at: \":00\"\n  - schedule:\n      at: \":30\"\n---\nbody\n"
	if _, err := setScheduleLine("at", ":30", two); err == nil {
		t.Fatal("changed one of two schedules")
	}
	one := "---\non:\n  - schedule:\n      at: \":00\" # the hour\n---\nat: body\n"
	got, err := setScheduleLine("at", ":30", one)
	if err != nil || !strings.Contains(got, "      at: \":30\"\n") || !strings.Contains(got, "at: body") {
		t.Fatalf("%q, %v", got, err)
	}
}
