package agentsd

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"time"

	// A server's image can have no zone files; a workflow's time-zone: must read the same
	// on every host (#4818).
	_ "time/tzdata"

	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// Workflow hours (#4818): `hours:` says when a workflow may start, for every trigger.
//
//	hours:
//	  between: "18:00-09:00"     # can go past midnight
//	  days: [mon, tue, wed, thu, fri]
//	  time-zone: Europe/London   # optional, an IANA name
//
// A fire outside it is held (one, as the cooldown holds one) and starts when it opens. Run
// now always runs. A schedule fires only when its own `between:`/`days:` and `hours:` both
// allow it. A window that goes past midnight belongs to the day it starts on: with
// `days: [fri]`, Friday 18:00 to Saturday 09:00 is open, and Friday 02:00 is not.

var allWeekdays = []wire.Weekday{wire.WeekdaySun, wire.WeekdayMon, wire.WeekdayTue, wire.WeekdayWed, wire.WeekdayThu, wire.WeekdayFri, wire.WeekdaySat}

// parseBetween is a `between:` range, "09:00-18:00", for a schedule and for `hours:`. The
// first time is after the second when it goes past midnight, "18:00-09:00".
func parseBetween(b string) (fh, fm, th, tm int64, err error) {
	bad := failure("\"" + b + "\" is not a range of times, like \"09:00-18:00\"")
	halves := strings.SplitN(b, "-", 2)
	if len(halves) != 2 {
		return 0, 0, 0, 0, bad
	}
	var ok1, ok2 bool
	fh, fm, ok1 = clockTime(strings.TrimSpace(halves[0]))
	th, tm, ok2 = clockTime(strings.TrimSpace(halves[1]))
	if !ok1 || !ok2 {
		return 0, 0, 0, 0, bad
	}
	return fh, fm, th, tm, nil
}

// parseDays is a `days:` list, in the week's order.
func parseDays(n yamlnode.Node) ([]wire.Weekday, error) {
	named, _ := n.Values()
	got := map[wire.Weekday]bool{}
	for _, d := range named {
		w := wire.Weekday(strings.ToLower(strings.TrimSpace(d)))
		valid := false
		for _, x := range allWeekdays {
			valid = valid || x == w
		}
		if !valid {
			return nil, failure("\"" + d + "\" is not a day of the week")
		}
		got[w] = true
	}
	if len(got) == 0 {
		return nil, failure("`days:` names no days")
	}
	var out []wire.Weekday
	for _, x := range allWeekdays {
		if got[x] {
			out = append(out, x)
		}
	}
	return out, nil
}

// parseHours is `hours:` as the file says it, checked.
func parseHours(n yamlnode.Node) (*wire.WorkflowHours, error) {
	if !n.IsMapping() {
		if t, ok := n.Text(); ok && t == "" {
			return nil, nil
		}
		return nil, failure("`hours:` must say `between:`, `days:` or `time-zone:`, like `between: \"09:00-18:00\"`")
	}
	keys := make([]string, 0, len(n.Mapping))
	for k := range n.Mapping {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var h wire.WorkflowHours
	for _, k := range keys {
		v := n.Mapping[k]
		switch k {
		case "between":
			t, ok := v.Text()
			if !ok {
				return nil, failure("`between:` under `hours:` must be one range of times, like \"09:00-18:00\"")
			}
			if t = strings.TrimSpace(t); t == "" {
				continue
			}
			fh, fm, th, tm, err := parseBetween(t)
			if err != nil {
				return nil, err
			}
			if fh*60+fm == th*60+tm {
				return nil, failure("\"" + t + "\" starts and ends at the same time")
			}
			h.Between = &t
		case "days":
			days, err := parseDays(v)
			if err != nil {
				return nil, err
			}
			if len(days) < len(allWeekdays) {
				h.Days = days
			}
		case "time-zone":
			t, ok := v.Text()
			if !ok {
				return nil, failure("`time-zone:` must be one name, like Europe/London")
			}
			if t = strings.TrimSpace(t); t == "" {
				continue
			}
			if _, err := zoneNamed(t); err != nil {
				return nil, failure("\"" + t + "\" is not a time zone — use a name like Europe/London or America/New_York")
			}
			h.TimeZone = &t
		default:
			return nil, failure("`hours:` has no `" + k + ":` — it takes `between:`, `days:` and `time-zone:`")
		}
	}
	if h.Between == nil && h.Days == nil && h.TimeZone == nil {
		return nil, nil
	}
	return &h, nil
}

// zoneNamed is an IANA zone; "Local" and "" are refused, so a file means the same zone on
// every host.
func zoneNamed(name string) (*time.Location, error) {
	if name == "" || name == "Local" {
		return nil, failure("no zone")
	}
	return time.LoadLocation(name)
}

// hoursWindow is `hours:` ready to ask: minutes of the day, from (inclusive) to (not),
// and the days its window starts on.
type hoursWindow struct {
	from, to int
	days     map[time.Weekday]bool
	loc      *time.Location
}

// windowOf is a workflow's hours in its zone: the file's, else the person's, else this
// host's. nil is no `hours:`, always open.
func windowOf(h *wire.WorkflowHours, personZone string) *hoursWindow {
	if h == nil || h.Between == nil && h.Days == nil {
		return nil
	}
	w := hoursWindow{from: 0, to: 24 * 60, days: map[time.Weekday]bool{}, loc: time.Local}
	if h.TimeZone != nil {
		if l, err := zoneNamed(*h.TimeZone); err == nil {
			w.loc = l
		}
	} else if l, err := zoneNamed(personZone); err == nil {
		w.loc = l
	}
	if h.Between != nil {
		if fh, fm, th, tm, err := parseBetween(*h.Between); err == nil {
			w.from, w.to = int(fh*60+fm), int(th*60+tm)
		}
	}
	days := h.Days
	if days == nil {
		days = allWeekdays
	}
	for _, d := range days {
		for i, x := range allWeekdays {
			if x == d {
				w.days[time.Weekday(i)] = true
			}
		}
	}
	return &w
}

// open is whether a fire at t may start.
func (w *hoursWindow) open(t time.Time) bool {
	if w == nil {
		return true
	}
	lt := t.In(w.loc)
	x := lt.Hour()*60 + lt.Minute()
	if w.from < w.to {
		return x >= w.from && x < w.to && w.days[lt.Weekday()]
	}
	// Past midnight: the part after midnight is the day before's.
	if x >= w.from {
		return w.days[lt.Weekday()]
	}
	return x < w.to && w.days[(lt.Weekday()+6)%7]
}

// opensAt is the first moment at or after t when the window is open: t itself when it is,
// else the next start of a day's window. ok is false only for a window with no days.
func (w *hoursWindow) opensAt(t time.Time) (time.Time, bool) {
	if w.open(t) {
		return t, true
	}
	lt := t.In(w.loc)
	for i := 0; i <= 8; i++ {
		day := time.Date(lt.Year(), lt.Month(), lt.Day()+i, 0, 0, 0, 0, w.loc)
		if !w.days[day.Weekday()] {
			continue
		}
		start := time.Date(day.Year(), day.Month(), day.Day(), w.from/60, w.from%60, 0, 0, w.loc)
		if start.After(t) {
			return start, true
		}
	}
	return time.Time{}, false
}

// personZone is the person's timeZone setting, as the control plane last sent it, or ""
// for none. Kept apart from userScopeMu: it is asked under workflowMu.
func (d *Daemon) personZone() string {
	if p := d.personTZ.Load(); p != nil {
		return *p
	}
	var m userSettingsSyncState
	if b, err := os.ReadFile(d.userSettingsSyncPath()); err == nil {
		json.Unmarshal(b, &m)
	}
	d.personTZ.CompareAndSwap(nil, &m.TimeZone)
	return *d.personTZ.Load()
}

// zoneOfPart is the timeZone part's identifier, or "" when it is not a zone.
func zoneOfPart(v wire.JSONValue) string {
	var z wire.UserTimeZone
	if json.Unmarshal(v, &z) != nil {
		return ""
	}
	if _, err := zoneNamed(z.Identifier); err != nil {
		return ""
	}
	return z.Identifier
}

// windowLocked is a workflow's hours, in its zone.
func (d *Daemon) windowLocked(w wire.Workflow) *hoursWindow {
	if w.Hours == nil {
		return nil
	}
	return windowOf(w.Hours, d.personZone())
}

// heldStartLocked is when a fire held now can start: the first moment its hours are open
// once its cooldown is over (#4818).
func (d *Daemon) heldStartLocked(w wire.Workflow, st *workflowState, win *hoursWindow, now time.Time) (time.Time, bool) {
	from := now
	if w.Cooldown != nil && st != nil && st.LastFiredAt != nil {
		if ends := st.LastFiredAt.Time().Add(time.Duration(*w.Cooldown * float64(time.Second))); ends.After(from) {
			from = ends
		}
	}
	return win.opensAt(from)
}

// scheduleAdmits is whether a schedule names the half hour c, in c's zone. A `between:`
// past midnight belongs to the day it starts on, as `hours:` does.
func scheduleAdmits(s wire.WorkflowSchedule, c time.Time) bool {
	h, m := int64(c.Hour()), int64(c.Minute())
	minuteOK := false
	for _, x := range s.Minutes {
		minuteOK = minuteOK || x == m
	}
	if !minuteOK {
		return false
	}
	days := map[wire.Weekday]bool{}
	for _, d := range s.Days {
		days[d] = true
	}
	x, lo, hi := h*60+m, s.Hours[0]*60+s.StartMinute, s.Hours[1]*60+s.EndMinute
	if lo <= hi {
		return x >= lo && x <= hi && days[allWeekdays[c.Weekday()]]
	}
	if x >= lo {
		return days[allWeekdays[c.Weekday()]]
	}
	return x <= hi && days[allWeekdays[(c.Weekday()+6)%7]]
}

// nextDueOpen is the first due of a schedule after t that its workflow's hours admit.
func nextDueOpen(s wire.WorkflowSchedule, win *hoursWindow, t time.Time) (time.Time, bool) {
	for range 8 * 48 {
		due, ok := nextDue(s, t)
		if !ok || win.open(due) {
			return due, ok
		}
		t = due
	}
	return time.Time{}, false
}

// hoursWords is `hours:` in words, for manage_workflows: "only 18:00-09:00 on Mon, Fri (Europe/London)".
func hoursWords(h *wire.WorkflowHours) string {
	if h == nil || h.Between == nil && h.Days == nil {
		return ""
	}
	out := "only"
	if h.Between != nil {
		out += " " + *h.Between
	}
	if h.Days != nil {
		var names []string
		for _, d := range h.Days {
			names = append(names, strings.ToUpper(string(d)[:1])+string(d)[1:])
		}
		out += " on " + strings.Join(names, ", ")
	}
	if h.TimeZone != nil {
		out += " (" + *h.TimeZone + ")"
	}
	return out
}

// hoursLines is `hours:` as the settings write puts it in a file (#4820): between:, days:
// and time-zone:, each checked as the file's own would be. nil is hours that limit nothing
// (no between: and no days:, or every day), which the write takes out.
func hoursLines(h wire.WorkflowHours) ([]string, error) {
	between, zone := "", ""
	if h.Between != nil {
		between = strings.TrimSpace(*h.Between)
	}
	if h.TimeZone != nil {
		zone = strings.TrimSpace(*h.TimeZone)
	}
	lines := []string{"hours:"}
	if between != "" {
		lines = append(lines, "  between: "+doubleQuoted(between))
	}
	if len(h.Days) > 0 {
		named := make([]string, len(h.Days))
		for i, d := range h.Days {
			named[i] = string(d)
		}
		lines = append(lines, "  days: ["+strings.Join(named, ", ")+"]")
	}
	if zone != "" {
		lines = append(lines, "  time-zone: "+quotedYAML(zone))
	}
	// The one reader checks it, so the page cannot write what the file would refuse.
	w := parseWorkflow("---\n"+strings.Join(lines, "\n")+"\n---\nGo\n", "x", "/p")
	if p := w.Problem; p != nil && p.Unreadable != nil {
		return nil, refuse(p.Unreadable.Value)
	}
	if w.Hours == nil || w.Hours.Between == nil && w.Hours.Days == nil {
		return nil, nil
	}
	if w.Hours.Days == nil && len(h.Days) > 0 {
		// Every day is the same as none: leave the line out.
		kept := lines[:0]
		for _, l := range lines {
			if !strings.HasPrefix(l, "  days:") {
				kept = append(kept, l)
			}
		}
		lines = kept
	}
	return lines, nil
}

// setHoursBlock puts `hours:` and the lines under it in place of the file's, or takes it
// out with nil lines.
func setHoursBlock(lines []string, source string) (string, error) {
	all, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	has := false
	for i := 1; i < closing; i++ {
		has = has || isKeyLine(all[i], "hours")
	}
	if !has {
		if lines == nil {
			return source, nil
		}
		return strings.Join(insertLines(all, closing, lines...), nl), nil
	}
	return setFrontMatterBlock("hours", lines, source)
}
