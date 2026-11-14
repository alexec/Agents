package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/agentsd/yamlnode"
	"github.com/agentloops-dev/agents/Go/wire"
)

// An alarm (#4966): a one-time workflow trigger, `on: - once: {at: 2026-11-13T09:15}`.
// It fires once, at its time, and the workflow then archives itself. When the time came
// while the Mac was off or asleep or Agents was stopped, it fires on wake or restart
// while it is still inside its grace (an hour unless `grace:` says); past the grace it is
// archived as missed (workflow.refused, missed_while_closed).
//
// It goes on the wire as a trigger this version does not know, named "once", with the
// file's own keys (at, time-zone, grace), as an event trigger does (042 FR-025): an older
// Mac or phone lists it as inert. The time is read in the file's time-zone:, else the
// person's, else this machine's, each time the clock looks, as hours: are.

const (
	onceTrigger  = "once"
	onceGrace    = time.Hour
	onceGraceMin = time.Minute
	onceGraceMax = 7 * 24 * time.Hour
)

// onceLayouts are the times `at:` takes: a wall-clock time in the zone, or an instant.
var onceLayouts = []string{"2006-01-02T15:04", "2006-01-02T15:04:05", "2006-01-02 15:04", "2006-01-02 15:04:05"}

// alarm is a once trigger as the clock reads it.
type alarm struct {
	at    string // as the file wrote it
	zone  string // the file's time-zone:, or ""
	grace time.Duration
}

// parseOnce is `once:` with its keys: checked, and kept as the file wrote them.
func parseOnce(keys map[string]yamlnode.Node) (wire.WorkflowTrigger, error) {
	raw := map[string]any{}
	for k, v := range keys {
		switch k {
		case "at", "time-zone", "grace":
		default:
			return wire.WorkflowTrigger{}, failure("`once:` has no `" + k + ":` — it takes `at:`, `time-zone:` and `grace:`")
		}
		t, ok := v.Text()
		if !ok {
			return wire.WorkflowTrigger{}, failure("`" + k + ":` under `once:` must be one value")
		}
		raw[k] = strings.TrimSpace(t)
	}
	at, _ := raw["at"].(string)
	if at == "" {
		return wire.WorkflowTrigger{}, failure("`once:` must say when with `at:`, like `at: 2026-11-13T09:15`")
	}
	if _, _, ok := wallOrInstant(at, time.UTC); !ok {
		return wire.WorkflowTrigger{}, failure("\"" + at + "\" is not a time `once:` can run at — write a date and a time, like 2026-11-13T09:15")
	}
	if z, ok := raw["time-zone"].(string); ok {
		if _, err := zoneNamed(z); err != nil {
			return wire.WorkflowTrigger{}, failure("\"" + z + "\" is not a time zone — use a name like Europe/London or America/New_York")
		}
	}
	if g, ok := raw["grace"].(string); ok {
		if _, err := parseGrace(g); err != nil {
			return wire.WorkflowTrigger{}, err
		}
	}
	return unrecognisedTrigger(onceTrigger, raw), nil
}

// parseGrace is `grace:`: a length of time as cooldown: takes, from a minute to a week.
func parseGrace(text string) (time.Duration, error) {
	words := "`grace:` must be a length of time from 1m to 7d, like 30m, 2h or 1d, not \"" + text + "\""
	t := strings.TrimSpace(text)
	if t == "" {
		return 0, failure(words)
	}
	var total time.Duration
	for t != "" {
		m := cooldownPart.FindStringSubmatch(t)
		if m == nil {
			return 0, failure(words)
		}
		n, err := strconv.Atoi(m[1])
		if err != nil {
			return 0, failure(words)
		}
		unit := map[string]time.Duration{"m": time.Minute, "h": time.Hour, "d": 24 * time.Hour}[m[2]]
		total += time.Duration(n) * unit
		t = strings.TrimSpace(t[len(m[0]):])
	}
	if total < onceGraceMin || total > onceGraceMax {
		return 0, failure(words)
	}
	return total, nil
}

// wallOrInstant is `at:` as an instant: with an offset or Z it is that instant, else the
// wall-clock time in loc. The second is whether it named its own offset.
func wallOrInstant(at string, loc *time.Location) (time.Time, bool, bool) {
	if t, err := time.Parse(time.RFC3339, at); err == nil {
		return t, true, true
	}
	if t, err := time.Parse("2006-01-02T15:04Z07:00", at); err == nil {
		return t, true, true
	}
	for _, l := range onceLayouts {
		if t, err := time.ParseInLocation(l, at, loc); err == nil {
			return t, false, true
		}
	}
	return time.Time{}, false, false
}

// alarmOf is the once trigger t, when it is one.
func alarmOf(t wire.WorkflowTrigger) (alarm, bool) {
	u := t.Unrecognised
	if u == nil || u.Name != onceTrigger {
		return alarm{}, false
	}
	text := func(k string) string {
		var s string
		if raw, ok := u.Keys[k]; ok {
			_ = json.Unmarshal(raw, &s)
		}
		return s
	}
	a := alarm{at: text("at"), zone: text("time-zone"), grace: onceGrace}
	if a.at == "" {
		return alarm{}, false
	}
	if g := text("grace"); g != "" {
		if d, err := parseGrace(g); err == nil {
			a.grace = d
		}
	}
	return a, true
}

// due is the alarm's instant: in its own zone, else personZone, else this machine's.
func (a alarm) due(personZone string) (time.Time, bool) {
	loc := time.Local
	if l, err := zoneNamed(a.zone); err == nil {
		loc = l
	} else if l, err := zoneNamed(personZone); err == nil {
		loc = l
	}
	t, _, ok := wallOrInstant(a.at, loc)
	return t, ok
}

// summary is the alarm in the folder page's words: "Once, at 2026-11-13 09:15 in your
// time zone, or up to 1 hour late".
func (a alarm) summary() string {
	where := " in your time zone"
	if a.zone != "" {
		where = " (" + a.zone + ")"
	}
	if _, named, _ := wallOrInstant(a.at, time.UTC); named {
		where = ""
	}
	return "Once, at " + strings.Replace(a.at, "T", " ", 1) + where + ", or up to " + lateWords(a.grace) + " late"
}

// onceOnly says every trigger the workflow has is an alarm: it runs once, and so is on
// as soon as the person approves it (Alex, 2026-11-12, #4966).
func onceOnly(w wire.Workflow) bool {
	if len(w.Triggers) == 0 {
		return false
	}
	for _, t := range w.Triggers {
		if _, ok := alarmOf(t); !ok {
			return false
		}
	}
	return true
}

// lateWords is how late, in words: "12 minutes", "2 hours 5 minutes", "3 days".
func lateWords(late time.Duration) string {
	m := int(math.Round(late.Minutes()))
	if m < 1 {
		return "less than a minute"
	}
	unit := func(n int, one string) string {
		if n == 1 {
			return "1 " + one
		}
		return fmt.Sprintf("%d %ss", n, one)
	}
	if m < 60 {
		return unit(m, "minute")
	}
	if m < 48*60 {
		h, rest := m/60, m%60
		if rest == 0 {
			return unit(h, "hour")
		}
		return unit(h, "hour") + " " + unit(rest, "minute")
	}
	return unit(int(math.Round(float64(m)/(24*60))), "day")
}

// alarmTimeWords is when an alarm is set for, as the prompt and the tool say it: "Fri 13
// Nov 09:15 (Europe/London)".
func alarmTimeWords(at time.Time, a alarm, personZone string) string {
	zone := a.zone
	if zone == "" {
		zone = personZone
	}
	if _, err := zoneNamed(zone); err != nil {
		zone = at.Location().String()
	}
	if l, err := zoneNamed(zone); err == nil {
		at = at.In(l)
	}
	return at.Format("Mon 2 Jan 15:04") + " (" + zone + ")"
}

// onceFire is one alarm the clock found due: to fire, or missed past its grace.
type onceFire struct {
	fr     fireRequest
	missed bool
}

// alarmsDueLocked is every alarm due by at that has not been handled: one inside its
// grace fires when the workflow is approved and on; past its grace it is missed. Each is
// marked handled at once, so the next tick does not take it again.
func (d *Daemon) alarmsDueLocked(at time.Time) []onceFire {
	var out []onceFire
	zone := d.personZone()
	for folder, ws := range d.workflowFiles {
		for id, f := range ws {
			w := f.wf
			if w.Problem != nil || isArchived(w) || !d.runsHere(w) {
				continue
			}
			for _, t := range w.Triggers {
				a, ok := alarmOf(t)
				if !ok {
					continue
				}
				due, ok := a.due(zone)
				if !ok || due.After(at) {
					continue
				}
				st := d.stateLocked(folder, id, false)
				if st != nil && st.AlarmHandled != nil && st.AlarmHandled.Time().Equal(due) {
					continue
				}
				dueAt := due
				// The run's cause carries the instant it was set for, so a page can say how
				// late it fired.
				fired := t
				keys := map[string]wire.JSONValue{}
				for k, v := range t.Unrecognised.Keys {
					keys[k] = v
				}
				keys["due"], _ = json.Marshal(due.UTC().Format(time.RFC3339))
				fired.Unrecognised = &wire.WorkflowTriggerStoredUnrecognised{Name: onceTrigger, Keys: keys}
				fr := fireRequest{folder: folder, id: id, trigger: fired, dueAt: &dueAt}
				if at.Sub(due) > a.grace {
					out = append(out, onceFire{fr: fr, missed: true})
				} else {
					// Inside its grace it waits for the person's approval, or for them to
					// turn it back on, and fires then.
					if awaiting, denied := d.approvalOf(folder, id, f); awaiting != nil || denied != nil || isOff(w) {
						continue
					}
					out = append(out, onceFire{fr: fr})
				}
				h := wire.DateOf(due)
				d.stateLocked(folder, id, true).AlarmHandled = &h
				d.saveRecordsLocked(false)
				break
			}
		}
	}
	return out
}

// runAlarm fires an alarm, or records it missed, and archives its workflow: it never runs
// again, and the archived workflow keeps the record of when it ran and what it started.
func (d *Daemon) runAlarm(of onceFire) {
	fr := of.fr
	if of.missed {
		d.workflowMu.Lock()
		name := ""
		if f := d.fileLocked(fr.folder, fr.id); f != nil {
			name = f.wf.Name
		}
		d.workflowMu.Unlock()
		d.recordOutcome(fr, name, wire.WorkflowOutcome{Refused: &wire.WorkflowOutcomeRefused{
			Value: wire.WorkflowRefusal{MissedWhileClosed: &struct{}{}}, At: now()}}, nil)
	} else {
		d.fire(fr)
	}
	if _, err := d.archiveAlarm(fr.folder, fr.id); err != nil {
		log.Printf("could not archive the one-time workflow %s after it came due: %v", fr.id, err)
	}
}

// archiveAlarm archives the workflow as workflows/archive does, keeping the last outcome
// (the run, or that it was missed) that archiving otherwise clears.
func (d *Daemon) archiveAlarm(folder, id string) (wire.WorkflowSummary, error) {
	d.workflowMu.Lock()
	var kept *wire.WorkflowOutcome
	if st := d.stateLocked(folder, id, false); st != nil {
		kept = st.LastOutcome
	}
	d.workflowMu.Unlock()
	// The app's own `archived: true` keeps the approval, as the person's Archive does: an
	// approved file is not "changed since you approved it" for that line alone. A file not
	// approved as it stood stays waiting.
	s, err := d.archiveWorkflow(wire.WorkflowArchiveRequest{Folder: store.FolderURL(folder), WorkflowID: id, Archived: true}, true)
	if err != nil {
		return s, err
	}
	d.workflowMu.Lock()
	if st := d.stateLocked(folder, id, false); st != nil && kept != nil {
		st.LastOutcome = kept
		d.saveRecordsLocked(false)
	}
	d.workflowMu.Unlock()
	d.tellWorkflow(folder, id)
	return d.oneWorkflow(folder, id)
}

// alarmWriteWords is why writing a workflow with an alarm is refused: its time is past
// its grace already. "" when it is not.
func alarmWriteWords(w wire.Workflow, personZone string, at time.Time) string {
	for _, t := range w.Triggers {
		a, ok := alarmOf(t)
		if !ok {
			continue
		}
		due, ok := a.due(personZone)
		if ok && at.Sub(due) > a.grace {
			return "`once:` is set for " + alarmTimeWords(due, a, personZone) + ", which was " + lateWords(at.Sub(due)) +
				" ago, past its grace of " + lateWords(a.grace) + ", so it would never run. Set a time to come. Nothing was written."
		}
	}
	return ""
}

// alarmPromptWords is the note at the top of an alarm's prompt.
func alarmPromptWords(fr fireRequest, personZone string, at time.Time) string {
	a, ok := alarmOf(fr.trigger)
	if !ok || fr.dueAt == nil {
		return "of its one-time alarm.)"
	}
	words := "of its one-time alarm, set for " + alarmTimeWords(*fr.dueAt, a, personZone)
	if late := at.Sub(*fr.dueAt); late >= time.Minute {
		words += ". It fired " + lateWords(late) + " late, as Agents was off or asleep at that time"
	}
	return words + ". It runs once: the workflow is now archived.)"
}
