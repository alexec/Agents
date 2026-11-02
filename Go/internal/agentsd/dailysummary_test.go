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
