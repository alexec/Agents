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

// Workflow hours (#4818): `hours:` read from the file, its window past midnight and across
// a zone, a schedule inside both windows, Run now, and cooldown with hours.

func hoursOf(t *testing.T, front string) *wire.WorkflowHours {
	t.Helper()
	w := parseWorkflow("---\n"+front+"---\nGo\n", "x", "/p")
	if w.Problem != nil {
		t.Fatalf("%q: %+v", front, w.Problem.Unreadable)
	}
	return w.Hours
}

func TestReadingHours(t *testing.T) {
	h := hoursOf(t, "hours:\n  between: \"18:00-09:00\"\n  days: [mon, tue, wed, thu, fri]\n  time-zone: Europe/London\n")
	if h == nil || *h.Between != "18:00-09:00" || len(h.Days) != 5 || h.Days[0] != wire.WeekdayMon || *h.TimeZone != "Europe/London" {
		t.Fatalf("%+v", h)
	}
	// Every day is no days at all; a key with nothing is no hours.
	if h := hoursOf(t, "hours:\n  between: 9-17\n  days: [sun, mon, tue, wed, thu, fri, sat]\n"); h.Days != nil || *h.Between != "9-17" {
		t.Fatalf("%+v", h)
	}
	if h := hoursOf(t, "hours:\n"); h != nil {
		t.Fatalf("%+v", h)
	}
	w := parseWorkflow("---\nhours:\n  between: 9-17\nfancy: yes\n---\nGo\n", "x", "/p")
	if _, unknown := w.UnknownFields["hours"]; unknown || w.Hours == nil {
		t.Fatalf("%+v", w)
	}
	for front, want := range map[string]string{
		"hours: 9-17\n":                         "`hours:` must say `between:`, `days:` or `time-zone:`",
		"hours:\n  between: 9-25\n":             `"9-25" is not a range of times, like "09:00-18:00"`,
		"hours:\n  between: \"09:00-09:00\"\n":  `"09:00-09:00" starts and ends at the same time`,
		"hours:\n  days: [mon, someday]\n":      `"someday" is not a day of the week`,
		"hours:\n  time-zone: Mars/Olympus\n":   `"Mars/Olympus" is not a time zone`,
		"hours:\n  time-zone: Local\n":          `"Local" is not a time zone`,
		"hours:\n  from: 9\n":                   "`hours:` has no `from:`",
		"hours:\n  between: [9-17]\n":           "`between:` under `hours:` must be one range of times",
		"hours:\n  between: \"18:00-09:15\"\n":  `"18:00-09:15" is not a range of times`,
		"hours:\n  days: []\n":                  "`days:` names no days",
		"hours:\n  time-zone:\n    x: y\n":      "`time-zone:` must be one name",
		"hours:\n  between: 9-17\n  days: 1\n":  `"1" is not a day of the week`,
		"hours:\n  between: 9-17\n  days: x\n":  `"x" is not a day of the week`,
		"hours:\n  between: 9-17\n  bogus: 1\n": "`hours:` has no `bogus:`",
	} {
		w := parseWorkflow("---\n"+front+"---\nGo\n", "x", "/p")
		if w.Problem == nil || w.Problem.Unreadable == nil || !strings.HasPrefix(w.Problem.Unreadable.Value, want) {
			t.Errorf("%q: %+v", front, w.Problem)
		}
	}
	// A file broken elsewhere still says its hours.
	if w := parseWorkflow("---\nhours:\n  between: 9-17\nenabled: maybe\n---\nGo\n", "x", "/p"); w.Problem == nil || w.Hours == nil {
		t.Fatalf("%+v", w)
	}
}

// A schedule's between: can go past midnight now; the hours after midnight are the day
// before's.
func TestAScheduleBetweenPastMidnight(t *testing.T) {
	w := parseWorkflow("---\non:\n  - schedule:\n      at: \":00\"\n      between: \"22:00-02:00\"\n      days: [fri]\n---\nGo\n", "x", "/p")
	if w.Problem != nil {
		t.Fatal(w.Problem.Unreadable)
	}
	s := w.Triggers[0].Schedule.Value
	if s.Hours != [2]int64{22, 2} {
		t.Fatalf("%+v", s)
	}
	at := func(day, h int) time.Time { return time.Date(2026, 11, day, h, 0, 0, 0, time.Local) } // the 13th is a Friday
	for _, c := range []struct {
		t    time.Time
		want bool
	}{{at(13, 22), true}, {at(13, 23), true}, {at(14, 0), true}, {at(14, 2), true}, {at(14, 3), false}, {at(13, 1), false}, {at(13, 21), false}, {at(14, 22), false}} {
		if got := scheduleAdmits(s, c.t); got != c.want {
			t.Errorf("%v: %v", c.t, got)
		}
	}
	d, ok := nextDue(s, at(13, 12))
	if !ok || !d.Equal(at(13, 22)) {
		t.Fatal(d)
	}
	d, ok = nextDue(s, at(14, 2))
	if !ok || !d.Equal(at(20, 22)) {
		t.Fatal(d)
	}
}

func TestTheHoursWindow(t *testing.T) {
	london, _ := time.LoadLocation("Europe/London")
	tokyo, _ := time.LoadLocation("Asia/Tokyo")
	between, weekdays := "18:00-09:00", []wire.Weekday{wire.WeekdayMon, wire.WeekdayTue, wire.WeekdayWed, wire.WeekdayThu, wire.WeekdayFri}
	zone := "Europe/London"
	win := windowOf(&wire.WorkflowHours{Between: &between, Days: weekdays, TimeZone: &zone}, "Asia/Tokyo")
	in := func(day, h, m int) time.Time { return time.Date(2026, 11, day, h, m, 0, 0, london) } // the 13th is a Friday
	for _, c := range []struct {
		t    time.Time
		want bool
	}{
		{in(13, 17, 59), false}, {in(13, 18, 0), true}, {in(13, 23, 30), true},
		{in(14, 8, 59), true}, // Saturday morning is Friday's night
		{in(14, 9, 0), false}, {in(14, 18, 0), false}, {in(15, 20, 0), false},
		{in(16, 3, 0), false}, // Monday 03:00 is Sunday's night
		{in(16, 18, 30), true},
	} {
		if got := win.open(c.t); got != c.want {
			t.Errorf("%v: %v", c.t, got)
		}
		// The same moment, told in another zone, is the same answer.
		if got := win.open(c.t.In(tokyo)); got != c.want {
			t.Errorf("%v in Tokyo: %v", c.t, got)
		}
	}
	// Closed on Saturday at 10:00: it opens on Monday at 18:00, London time.
	if at, ok := win.opensAt(in(14, 10, 0)); !ok || !at.Equal(in(16, 18, 0)) {
		t.Fatal(at)
	}
	if at, ok := win.opensAt(in(13, 20, 0)); !ok || !at.Equal(in(13, 20, 0)) {
		t.Fatal(at)
	}
	// No time-zone: is the person's; no person's is the host's.
	day := "09:00-17:00"
	if w := windowOf(&wire.WorkflowHours{Between: &day}, "Asia/Tokyo"); w.loc.String() != "Asia/Tokyo" {
		t.Fatal(w.loc)
	}
	if w := windowOf(&wire.WorkflowHours{Between: &day}, ""); w.loc != time.Local {
		t.Fatal(w.loc)
	}
	// A day change across the zone: 23:00 in London on a Friday is Saturday in Tokyo.
	fri := windowOf(&wire.WorkflowHours{Days: []wire.Weekday{wire.WeekdayFri}}, "Europe/London")
	if !fri.open(in(13, 23, 0)) || fri.open(in(14, 0, 30)) {
		t.Fatal("Friday in London")
	}
	tokyoFri := windowOf(&wire.WorkflowHours{Days: []wire.Weekday{wire.WeekdayFri}}, "Asia/Tokyo")
	if tokyoFri.open(in(13, 23, 0)) || !tokyoFri.open(in(13, 10, 0)) {
		t.Fatal("Friday in Tokyo")
	}
	// No hours is always open.
	var none *hoursWindow
	if !none.open(in(13, 3, 0)) {
		t.Fatal("no hours")
	}
}

// A schedule fires only when its own window and hours: both allow it.
func TestAScheduleInsideBothWindows(t *testing.T) {
	s := wire.WorkflowSchedule{Minutes: []int64{0}, Hours: [2]int64{0, 23}, StartMinute: 0, EndMinute: 30, Days: allWeekdays}
	between := "09:00-12:00"
	win := windowOf(&wire.WorkflowHours{Between: &between}, "")
	due, ok := nextDueOpen(s, win, time.Date(2026, 11, 13, 12, 10, 0, 0, time.Local))
	if !ok || !due.Equal(time.Date(2026, 11, 14, 9, 0, 0, 0, time.Local)) {
		t.Fatal(due)
	}
	// Windows that never meet: no due at all.
	night := "01:00-02:00"
	s.Hours, s.EndMinute = [2]int64{9, 17}, 0
	if due, ok := nextDueOpen(s, windowOf(&wire.WorkflowHours{Between: &night}, ""), time.Now()); ok {
		t.Fatal(due)
	}
}

// When cooldown and hours both hold a fire, it starts when both allow it.
func TestCooldownWithHours(t *testing.T) {
	between := "09:00-17:00"
	win := windowOf(&wire.WorkflowHours{Between: &between}, "")
	cool := 3 * 3600.0
	w := wire.Workflow{Cooldown: &cool, Hours: &wire.WorkflowHours{Between: &between}}
	at := func(h, m int) time.Time { return time.Date(2026, 11, 13, h, m, 0, 0, time.Local) }
	fired := wire.DateOf(at(15, 0))
	st := &workflowState{LastFiredAt: &fired}
	d := &Daemon{}
	// At 16:00 the window is open, but the cooldown ends at 18:00, after it closes: the
	// next morning.
	if got, ok := d.heldStartLocked(w, st, win, at(16, 0)); !ok || !got.Equal(time.Date(2026, 11, 14, 9, 0, 0, 0, time.Local)) {
		t.Fatal(got)
	}
	// At 07:00 the cooldown is over: the window's opening.
	early := wire.DateOf(at(3, 0))
	if got, _ := d.heldStartLocked(w, &workflowState{LastFiredAt: &early}, win, at(7, 0)); !got.Equal(at(9, 0)) {
		t.Fatal(got)
	}
	// A cooldown that ends inside the window: its end.
	morning := wire.DateOf(at(8, 0))
	if got, _ := d.heldStartLocked(w, &workflowState{LastFiredAt: &morning}, win, at(9, 30)); !got.Equal(at(11, 0)) {
		t.Fatal(got)
	}
}

// An event outside the hours is held and said quietly; Run now runs; the held fire starts
// once the hours open.
func TestAFireOutsideHoursIsHeld(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	today := allWeekdays[time.Now().UTC().Weekday()]
	var others []string
	for _, x := range allWeekdays {
		if x != today {
			others = append(others, string(x))
		}
	}
	write := func(days string) {
		os.MkdirAll(workflowsFolder(dir), 0o755)
		os.WriteFile(filepath.Join(workflowsFolder(dir), "night.md"),
			[]byte("---\non: server.online\nhours:\n  days: ["+days+"]\n  time-zone: UTC\n---\nLook.\n"), 0o644)
	}
	write(strings.Join(others, ", "))
	approveAll(t, c, folder)
	e := d.raise(wire.EventDraft{Name: "server.online", At: now(), Scope: macScope(), Sentence: "ci came back.", Details: map[string]string{"server": "ci"}})
	waitFor(t, "the fire held", func() bool {
		got := d.event(e.Position)
		return got != nil && len(got.Consequences) == 1 && got.Consequences[0].Refused != nil && got.Consequences[0].Refused.Reason.OutsideHours != nil
	})
	var list []wire.WorkflowSummary
	json.Unmarshal(c.call(t, 2, "workflows/list", map[string]any{"folder": folder}), &list)
	midnight := time.Now().UTC().Truncate(24 * time.Hour).Add(24 * time.Hour)
	if len(list) != 1 || !list[0].HoldsAFire || list[0].HoursOpenAt == nil || !list[0].HoursOpenAt.Time().Equal(midnight) ||
		list[0].Workflow.Hours == nil || len(list[0].Workflow.Hours.Days) != 6 {
		t.Fatalf("%+v", list)
	}
	r := list[0].LastOutcome.Refused
	if r == nil || r.Value.OutsideHours == nil || !r.Value.OutsideHours.Until.Time().Equal(midnight) {
		t.Fatalf("%+v", list[0].LastOutcome)
	}
	for _, n := range names(d) {
		if n == "workflow.refused" {
			t.Fatal("a held fire is not a refusal to tell")
		}
	}
	// Run now always runs.
	var s wire.WorkflowSummary
	json.Unmarshal(c.call(t, 3, "workflows/run", map[string]any{"folder": folder, "workflowID": "night"}), &s)
	if s.LastOutcome == nil || s.LastOutcome.Ran == nil {
		t.Fatalf("%+v", s)
	}
	c.call(t, 4, "agents/stop", map[string]any{"agentID": s.LastOutcome.Ran.AgentID})
	waitFor(t, "the run over", func() bool { return !d.runningOf(dir, "night") })
	// Open today: the next ticks start the held fire.
	write(string(today))
	approveAll(t, c, folder)
	waitFor(t, "the held fire ran", func() bool {
		d.workflowTickOnce(time.Now())
		got := d.event(e.Position)
		return got != nil && len(got.Consequences) == 1 && got.Consequences[0].Fired != nil
	})
	waitFor(t, "no run left", func() bool {
		d.workflowMu.Lock()
		var agent *wire.UUID
		if runs := d.recordsLocked().Runs; len(runs) > 0 {
			agent = runs[0].AgentID
		}
		n := len(d.workflowRecs.Runs)
		d.workflowMu.Unlock()
		if agent != nil {
			c.call(t, 5, "agents/stop", map[string]any{"agentID": *agent})
		}
		return n == 0
	})
}

// The person's time zone comes from the control plane's timeZone part, and is kept.
func TestThePersonsTimeZone(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	if z := d.personZone(); z != "" {
		t.Fatal(z)
	}
	if err := d.ApplyUserSettings(wire.MachineUserSettings{User: "alex", Settings: wire.UserSettings{TimeZone: wire.JSONValue(`{"identifier":"Asia/Tokyo"}`)}}); err != nil {
		t.Fatal(err)
	}
	if z := d.personZone(); z != "Asia/Tokyo" {
		t.Fatal(z)
	}
	d.personTZ.Store(nil)
	if z := d.personZone(); z != "Asia/Tokyo" {
		t.Fatal("not kept:", z)
	}
	if zoneOfPart(wire.JSONValue(`{"identifier":"Nowhere/Else"}`)) != "" || zoneOfPart(wire.JSONValue(`"Asia/Tokyo"`)) != "" {
		t.Fatal("a bad zone was taken")
	}
}
