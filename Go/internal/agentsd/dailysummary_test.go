package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
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

// Facts from the person's other machines (#3354): the summary asks the control plane, which
// asks each of them; their lines say the machine, a pull request merged in a checkout on two
// machines is one, and a machine that is off is named, not left out.
func TestDailySummaryHasTheOtherMachines(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	wid := dailySummaryID
	me := seeded(t, d, home, func(a *wire.Agent) { a.State, a.StartedByWorkflow = wire.AgentStateRunning, &wid })
	pull := pullLine + "Mon 09:00: https://github.com/o/r/pull/1"
	var mu sync.Mutex
	var asked []string
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		call, _ := params.(wire.MachineWorkspaceCall)
		mu.Lock()
		asked = append(asked, call.Method)
		mu.Unlock()
		return json.Marshal(wire.MachinesSummaryFacts{Machines: []wire.MachineSummaryFacts{
			{Machine: "pc", MachineName: "pc", Facts: &wire.SummaryFacts{Folders: 3, Landed: []string{`Session "Port it" in app done at Mon 10:00.`, pull, pull},
				Failed: []string{}, Waiting: []string{"Question in app: which port?"}, Suggested: []string{}, Checked: []string{}}},
			{Machine: "box", MachineName: "box", Unreached: new("off")},
		}})
	})
	facts := d.summaryFacts(me.ID, time.Now())
	mu.Lock()
	if !slices.Contains(asked, wire.CallMachinesSummaryFacts.Name) {
		t.Fatalf("asked %v", asked)
	}
	mu.Unlock()
	for _, want := range []string{
		`On pc: Session "Port it" in app done at Mon 10:00.`,
		"On pc: Question in app: which port?",
		"Not in these facts: box, off.",
		", pc (",
	} {
		if !strings.Contains(facts, want) {
			t.Fatalf("no %q in:\n%s", want, facts)
		}
	}
	if strings.Count(facts, "pull/1") != 1 {
		t.Fatalf("a pull request from two checkouts is listed twice:\n%s", facts)
	}

	// What this machine answers another's summary: each list cut, with a count of the rest.
	work := t.TempDir()
	died := wire.EndedReasonProcessDied
	for range summaryLines + 5 {
		seeded(t, d, work, func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateStopped, &died })
	}
	sent := sentSummaryFacts(d.machineSummaryFacts("", time.Now().Add(-time.Hour)))
	if len(sent.Failed) != summaryLines+1 || sent.Failed[summaryLines] != "and 5 more" || sent.Waiting == nil || sent.Checked == nil {
		t.Fatalf("%d %v", len(sent.Failed), sent.Failed[len(sent.Failed)-1])
	}
}

// The facts are about the person (#3720): what waits on them on GitHub, the outcomes that
// landed with the sessions that made them under them, a workflow's runs as one line, and at
// most a few other sessions.
func TestDailySummaryIsAboutThePerson(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	home := t.TempDir()
	d.PersonalHome = home
	work := t.TempDir()
	if err := os.MkdirAll(filepath.Join(work, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(work, ".git", "config"), []byte("[remote \"origin\"]\n\turl = https://github.com/o/r.git\n"), 0o644)
	since := time.Now().Add(-time.Hour)
	stamp := func(d time.Duration) string { return since.Add(d).UTC().Format(time.RFC3339) }
	gh := filepath.Join(t.TempDir(), "gh")
	script := `#!/bin/sh
case "$*" in
"repo view"*) echo '{"nameWithOwner":"o/r","url":"https://github.com/o/r"}' ;;
"search prs --label needs-approval"*) echo '[{"number":5,"title":"New button","url":"https://github.com/o/r/pull/5","createdAt":"` + stamp(-48*time.Hour) + `","repository":{"nameWithOwner":"o/r"}}]' ;;
"search prs --review-requested"*) echo '[{"number":5,"title":"New button","url":"https://github.com/o/r/pull/5","createdAt":"` + stamp(-48*time.Hour) + `","repository":{"nameWithOwner":"o/r"}},
  {"number":6,"title":"Review me","url":"https://github.com/o/r/pull/6","createdAt":"` + stamp(-24*time.Hour) + `","repository":{"nameWithOwner":"o/r"}}]' ;;
"search issues"*) echo '[{"number":7,"title":"Sign up","url":"https://github.com/o/r/issues/7","createdAt":"` + stamp(-72*time.Hour) + `","repository":{"nameWithOwner":"o/r"}}]' ;;
"pr list"*) echo '[{"number":12,"title":"Fix login","url":"https://github.com/o/r/pull/12","mergedAt":"` + stamp(time.Minute) + `","headRefName":"agents/12-login"}]' ;;
"issue list"*) echo '[{"number":9,"title":"Projects","url":"https://github.com/o/r/issues/9","closedAt":"` + stamp(time.Minute) + `","stateReason":"COMPLETED","labels":[{"name":"epic"}]},
  {"number":10,"title":"Dup","url":"https://github.com/o/r/issues/10","closedAt":"` + stamp(time.Minute) + `","stateReason":"NOT_PLANNED","labels":[]}]' ;;
"release list"*) echo '[{"tagName":"v0.17.0","name":"v0.17.0","publishedAt":"` + stamp(time.Minute) + `"}]' ;;
esac
`
	if err := os.WriteFile(gh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	needs, branch := "Fix the login", "agents/12-login"
	maker := seeded(t, d, work, func(a *wire.Agent) {
		a.Title = &needs
		a.Worktree = &wire.AgentWorktree{Name: "12-login", Branch: &branch, Folder: store.FolderURL(work)}
	})
	ship := "ship-app"
	for range 5 {
		seeded(t, d, work, func(a *wire.Agent) { a.StartedByWorkflow = &ship })
	}
	for range otherSessionLines + 2 {
		seeded(t, d, work, nil)
	}

	f := d.machineSummaryFactsWith("", since, gh)
	if len(f.Waiting) != 3 || !strings.HasPrefix(f.Waiting[0], assignedLine+`#7 "Sign up"`) ||
		!strings.HasPrefix(f.Waiting[1], approvalLine+"#5") || !strings.HasPrefix(f.Waiting[2], reviewLine+"#6") {
		t.Fatalf("waits on you:\n%s", strings.Join(f.Waiting, "\n"))
	}
	landed := strings.Join(f.Landed, "\n")
	for _, want := range []string{
		epicLine, `#9 "Projects" in o/r. https://github.com/o/r/issues/9`,
		`#12 "Fix login" in o/r. https://github.com/o/r/pull/12` + "\n  - session \"Fix the login\": " + sessionLink(maker.ID),
		releaseLine, "https://github.com/o/r/releases/tag/v0.17.0",
		`Workflow "ship-app" in ` + filepath.Base(work) + " ran 5 times",
		"and 2 other sessions done",
	} {
		if !strings.Contains(landed, want) {
			t.Fatalf("no %q in:\n%s", want, landed)
		}
	}
	if strings.Contains(landed, "Dup") || strings.Contains(landed, `Session "Fix the login"`) || strings.Count(landed, "Workflow ") != 1 {
		t.Fatalf("landed:\n%s", landed)
	}
	if got := personLine(f.Waiting, f.Landed); got != "3 things wait on you. 1 pull request merged, 1 epic closed, 1 release published." {
		t.Fatal(got)
	}
}
