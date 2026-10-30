package agentsd

import (
	"log"
	"maps"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Where each turn's time went (#852, TimeLedger): the agent working, its tools, waiting on
// others and waiting for the person, by the hour and the day and by runtime, in
// <root>/time-history.json as the Swift host keeps it, with each day's recap (#985). A turn
// is banked when it ends; a long one every 2,000 marks.
//
// The Swift host seeds the file from every transcript when there is none. This host does
// not: it takes over a root the Swift host kept, and a new one starts from nothing (#1136).

const timeMarksKept = 2000

type timeBook struct {
	timeMu      sync.Mutex
	timeHeld    *wire.TimeHistory
	timeTurns   map[wire.UUID]*timeTurn
	timeWaiting map[wire.UUID]map[string]bool
	clearSince  *time.Time
	seenDay     string
	seenAgents  map[wire.UUID]bool
}

type timeTurn struct {
	marks   []timeMark
	carried int
}

type markKind int

const (
	markState markKind = iota
	markToolStarted
	markToolEnded
	markAskOpened
	markAskClosed
)

// timeMark is TimeMark: one moment that changes what a turn's time is going on.
type timeMark struct {
	kind  markKind
	state wire.AgentState
	id    string
	anyID bool // an askClosed for every ask
	name  string
	at    time.Time
}

type timeSegment struct {
	kind       string // agent, tools, others, person
	start, end time.Time
}

func timeMarkOf(e wire.TranscriptEntry) (timeMark, bool) {
	k, at := e.Kind, e.At.Time()
	switch {
	case k.StateChanged != nil:
		return timeMark{kind: markState, state: k.StateChanged.Value, at: at}, true
	case k.ToolCall != nil:
		c := k.ToolCall.Value
		if c.ToolCallID == nil {
			return timeMark{}, false
		}
		name := c.Title
		if c.Name != nil {
			name = *c.Name
		}
		return timeMark{kind: markToolStarted, id: *c.ToolCallID, name: name, at: at}, true
	case k.ToolCallUpdate != nil:
		c := k.ToolCallUpdate.Value
		if c.ToolCallID == nil || c.Status == nil || (*c.Status != "completed" && *c.Status != "failed") {
			return timeMark{}, false
		}
		return timeMark{kind: markToolEnded, id: *c.ToolCallID, at: at}, true
	case k.ElicitationAsked != nil:
		return timeMark{kind: markAskOpened, id: string(k.ElicitationAsked.Value.ID), at: at}, true
	case k.ElicitationAnswered != nil:
		return timeMark{kind: markAskClosed, id: string(k.ElicitationAnswered.ID), at: at}, true
	case k.PermissionAsked != nil:
		return timeMark{kind: markAskOpened, id: "permission", at: at}, true
	case k.PermissionAnswered != nil:
		return timeMark{kind: markAskClosed, id: "permission", at: at}, true
	}
	return timeMark{}, false
}

// toolTimeKind is TimeMark.kind(ofTool:).
func toolTimeKind(name string) string {
	n := strings.ToLower(name)
	switch {
	// The app's ask_question, any runtime's own (Antigravity's has the same name, and is the
	// person's time all the same), ask_form, its name before #2298, in older records, and
	// ask_secret (#2885).
	case strings.HasSuffix(n, "askuserquestion") || strings.HasSuffix(n, "ask_question") || strings.HasSuffix(n, "ask_form") ||
		strings.HasSuffix(n, "ask_secret"):
		return "person"
	case strings.HasSuffix(n, "release_resource"):
		// release_resource ends with lease_resource: a release is quick, and a tool.
		return "tools"
	case strings.HasSuffix(n, "wait_for_event") || strings.HasSuffix(n, "wait_for_agents") ||
		strings.HasSuffix(n, "check_again") || strings.HasSuffix(n, "lease_resource"):
		return "others"
	}
	return "tools"
}

func working(s wire.AgentState) bool {
	return s == wire.AgentStateRunning || s == wire.AgentStateWaitingOnUser
}

// splitMarks is TimeMark.split: the segments the marks make, and what is still open at the
// last of them, carried into the next stretch.
func splitMarks(marks []timeMark) ([]timeSegment, []timeMark) {
	marks = slices.Clone(marks)
	sort.SliceStable(marks, func(i, j int) bool { return marks[i].at.Before(marks[j].at) })
	if len(marks) == 0 {
		return nil, nil
	}
	var state *wire.AgentState
	open := map[string]map[string]bool{}
	toolKinds := map[string]string{}
	var segments []timeSegment
	since := marks[0].at
	current := func() string {
		if state == nil || !working(*state) {
			return ""
		}
		switch {
		case *state == wire.AgentStateWaitingOnUser || len(open["person"]) > 0:
			return "person"
		case len(open["others"]) > 0:
			return "others"
		case len(open["tools"]) > 0:
			return "tools"
		}
		return "agent"
	}
	add := func(kind, id string) {
		if open[kind] == nil {
			open[kind] = map[string]bool{}
		}
		open[kind][id] = true
	}
	for _, m := range marks {
		if kind := current(); kind != "" && m.at.After(since) {
			if n := len(segments); n > 0 && segments[n-1].kind == kind && segments[n-1].end.Equal(since) {
				segments[n-1].end = m.at
			} else {
				segments = append(segments, timeSegment{kind: kind, start: since, end: m.at})
			}
		}
		since = m.at
		switch m.kind {
		case markState:
			s := m.state
			state = &s
			// A turn's end closes whatever it left open.
			if !working(s) {
				open, toolKinds = map[string]map[string]bool{}, map[string]string{}
			}
		case markToolStarted:
			kind := toolTimeKind(m.name)
			toolKinds[m.id] = kind
			add(kind, m.id)
		case markToolEnded:
			if kind, ok := toolKinds[m.id]; ok {
				delete(toolKinds, m.id)
				delete(open[kind], m.id)
			}
		case markAskOpened:
			add("person", "ask:"+m.id)
		case markAskClosed:
			if m.anyID {
				open["person"] = map[string]bool{}
			} else {
				delete(open["person"], "ask:"+m.id)
			}
		}
	}
	var carry []timeMark
	if state != nil && working(*state) {
		carry = append(carry, timeMark{kind: markState, state: *state, at: since})
		ids := make([]string, 0, len(toolKinds))
		for id := range toolKinds {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for _, id := range ids {
			if kind := toolKinds[id]; open[kind][id] {
				name := "tool"
				switch kind {
				case "person":
					name = "ask_question"
				case "others":
					name = "wait_for_event"
				}
				carry = append(carry, timeMark{kind: markToolStarted, id: id, name: name, at: since})
			}
		}
		var asks []string
		for a := range open["person"] {
			if strings.HasPrefix(a, "ask:") {
				asks = append(asks, a)
			}
		}
		sort.Strings(asks)
		for _, a := range asks {
			carry = append(carry, timeMark{kind: markAskOpened, id: strings.TrimPrefix(a, "ask:"), at: since})
		}
	}
	return segments, carry
}

// MARK: TimeHistory

func bucketAdd(b *wire.TimeBucket, o wire.TimeBucket) {
	b.Agent += o.Agent
	b.Tools += o.Tools
	b.Others += o.Others
	b.Person += o.Person
	b.Turns += o.Turns
}

func addToHour(h *wire.TimeHistory, b wire.TimeBucket, runtime, hour string) {
	for _, at := range []struct {
		m   map[string]map[string]wire.TimeBucket
		key string
	}{{h.Hours, hour}, {h.Days, hour[:min(10, len(hour))]}} {
		if at.m[at.key] == nil {
			at.m[at.key] = map[string]wire.TimeBucket{}
		}
		cur := at.m[at.key][runtime]
		bucketAdd(&cur, b)
		at.m[at.key][runtime] = cur
	}
}

// addStretch is TimeHistory.add(_:from:to:): the seconds put into each hour they fell in.
func addStretch(h *wire.TimeHistory, kind string, from, to time.Time, runtime string) {
	for from.Before(to) {
		l := from.Local()
		hourStart := time.Date(l.Year(), l.Month(), l.Day(), l.Hour(), 0, 0, 0, l.Location())
		next := hourStart.Add(time.Hour)
		if next.After(to) {
			next = to
		}
		if !next.After(from) {
			break
		}
		var b wire.TimeBucket
		s := next.Sub(from).Seconds()
		switch kind {
		case "agent":
			b.Agent = s
		case "tools":
			b.Tools = s
		case "others":
			b.Others = s
		case "person":
			b.Person = s
		}
		addToHour(h, b, runtime, hourStamp(from))
		from = next
	}
}

func changeRecap(h *wire.TimeHistory, day string, change func(r *wire.DayRecap)) {
	r := h.Recap[day]
	change(&r)
	h.Recap[day] = r
	beat := func(rec **wire.TimeRecord, v float64) {
		if v > 0 && (*rec == nil || v > (*rec).Value) {
			*rec = &wire.TimeRecord{Value: v, Day: day}
		}
	}
	beat(&h.Records.MostAgents, float64(r.PeakAgents))
	prs := int64(0)
	if r.PrsMerged != nil {
		prs = *r.PrsMerged
	}
	beat(&h.Records.MostPRs, float64(prs))
	beat(&h.Records.LongestClear, r.LongestClear)
}

func pruneTime(h *wire.TimeHistory) {
	keep := func(keys []string, n int) map[string]bool {
		sort.Strings(keys)
		out := map[string]bool{}
		for _, k := range keys[max(0, len(keys)-n):] {
			out[k] = true
		}
		return out
	}
	hk := keep(slices.Collect(maps.Keys(h.Hours)), usageHoursKept)
	for k := range h.Hours {
		if !hk[k] {
			delete(h.Hours, k)
		}
	}
	dk := keep(slices.Collect(maps.Keys(h.Days)), usageDaysKept)
	for k := range h.Days {
		if !dk[k] {
			delete(h.Days, k)
		}
	}
	rk := keep(slices.Collect(maps.Keys(h.Recap)), usageDaysKept)
	for k := range h.Recap {
		if !rk[k] {
			delete(h.Recap, k)
		}
	}
}

// MARK: the ledger

func (d *Daemon) timePath() string { return filepath.Join(d.Store.Loc.Root, "time-history.json") }

// timeLocked is the history held, read from its file the first time.
func (d *Daemon) timeLocked() *wire.TimeHistory {
	if d.timeHeld == nil {
		var h wire.TimeHistory
		readStore(d.timePath(), &h, "the time charts start again")
		if h.Hours == nil {
			h.Hours = map[string]map[string]wire.TimeBucket{}
		}
		if h.Days == nil {
			h.Days = map[string]map[string]wire.TimeBucket{}
		}
		if h.Recap == nil {
			h.Recap = map[string]wire.DayRecap{}
		}
		d.timeHeld = &h
	}
	return d.timeHeld
}

// noteTime is TimeLedger.note, for each entry recorded: banked, and written, when a turn
// ends.
func (d *Daemon) noteTime(e wire.TranscriptEntry, agent wire.UUID, runtime string) {
	m, ok := timeMarkOf(e)
	if !ok {
		return
	}
	d.timeMu.Lock()
	defer d.timeMu.Unlock()
	if d.timeTurns == nil {
		d.timeTurns, d.timeWaiting, d.seenAgents = map[wire.UUID]*timeTurn{}, map[wire.UUID]map[string]bool{}, map[wire.UUID]bool{}
	}
	ended := d.noteTurnLocked(m, agent, runtime)
	d.noteRecapLocked(m, agent)
	if ended {
		h := d.timeLocked()
		pruneTime(h)
		if err := writeStore(d.timePath(), h); err != nil {
			log.Printf("time-history.json: could not save: %v", err)
		}
	}
}

func (d *Daemon) noteTurnLocked(m timeMark, agent wire.UUID, runtime string) bool {
	t := d.timeTurns[agent]
	if m.kind == markState && m.state == wire.AgentStateRunning && t == nil {
		d.timeTurns[agent] = &timeTurn{marks: []timeMark{m}}
		return false
	}
	// Nothing is counted outside a turn.
	if t == nil {
		return false
	}
	t.marks = append(t.marks, m)
	if m.kind == markState && !working(m.state) {
		segments, _ := splitMarks(t.marks)
		d.bankLocked(segments, runtime, true)
		d.reportTime(agent, runtime, segments)
		delete(d.timeTurns, agent)
		delete(d.timeWaiting, agent)
		return true
	}
	if len(t.marks)-t.carried >= timeMarksKept {
		segments, carry := splitMarks(t.marks)
		d.bankLocked(segments, runtime, false)
		d.reportTime(agent, runtime, segments)
		t.marks, t.carried = carry, len(carry)
	}
	return false
}

func (d *Daemon) bankLocked(segments []timeSegment, runtime string, endsTurn bool) {
	if len(segments) == 0 {
		return
	}
	h := d.timeLocked()
	for _, s := range segments {
		addStretch(h, s.kind, s.start, s.end, runtime)
	}
	if endsTurn {
		addToHour(h, wire.TimeBucket{Turns: 1}, runtime, hourStamp(segments[len(segments)-1].end))
	}
}

// noteRecapLocked is the day's recap: how many agents worked, most at once, and the
// longest stretch with work going and nothing waiting for the person.
func (d *Daemon) noteRecapLocked(m timeMark, agent wire.UUID) {
	day := dayStamp(m.at)
	if t := d.timeTurns[agent]; t != nil {
		open := d.timeWaiting[agent]
		if open == nil {
			open = map[string]bool{}
		}
		switch m.kind {
		case markState:
			if m.state == wire.AgentStateWaitingOnUser {
				open["state"] = true
			} else {
				delete(open, "state")
			}
		case markToolStarted:
			if toolTimeKind(m.name) == "person" {
				open["tool:"+m.id] = true
			}
		case markToolEnded:
			delete(open, "tool:"+m.id)
		case markAskOpened:
			open["ask:"+m.id] = true
		case markAskClosed:
			if m.anyID {
				for k := range open {
					if strings.HasPrefix(k, "ask:") {
						delete(open, k)
					}
				}
			} else {
				delete(open, "ask:"+m.id)
			}
		}
		if len(open) == 0 {
			delete(d.timeWaiting, agent)
		} else {
			d.timeWaiting[agent] = open
		}
		if m.kind == markState && m.state == wire.AgentStateRunning && len(t.marks) == 1 {
			if d.seenDay != day {
				d.seenDay, d.seenAgents = day, map[wire.UUID]bool{}
			}
			d.seenAgents[agent] = true
			count, atOnce := int64(len(d.seenAgents)), int64(len(d.timeTurns))
			changeRecap(d.timeLocked(), day, func(r *wire.DayRecap) {
				r.Agents = max(r.Agents, count)
				r.PeakAgents = max(r.PeakAgents, atOnce)
			})
		}
	}
	quiet := len(d.timeTurns) > 0 && len(d.timeWaiting) == 0
	switch {
	case quiet && d.clearSince == nil:
		at := m.at
		d.clearSince = &at
	case !quiet && d.clearSince != nil:
		since := *d.clearSince
		d.clearSince = nil
		if s := m.at.Sub(since).Seconds(); s > 0 {
			changeRecap(d.timeLocked(), dayStamp(m.at), func(r *wire.DayRecap) { r.LongestClear = max(r.LongestClear, s) })
		}
	}
}

// timeHistory is time/history: what is kept, the hour it is now, and a clear stretch still
// going counted to now.
func (d *Daemon) timeHistory() wire.TimeHistory {
	d.timeMu.Lock()
	defer d.timeMu.Unlock()
	h := cloneTime(*d.timeLocked())
	pruneTime(&h)
	at := time.Now()
	h.Now, h.TimeZone = hourStamp(at), zoneName()
	if d.clearSince != nil && at.After(*d.clearSince) {
		s := at.Sub(*d.clearSince).Seconds()
		changeRecap(&h, dayStamp(at), func(r *wire.DayRecap) { r.LongestClear = max(r.LongestClear, s) })
	}
	return h
}

func cloneTime(h wire.TimeHistory) wire.TimeHistory {
	out := wire.TimeHistory{Hours: map[string]map[string]wire.TimeBucket{}, Days: map[string]map[string]wire.TimeBucket{},
		Now: h.Now, Recap: map[string]wire.DayRecap{}, Records: h.Records}
	for k, v := range h.Hours {
		out.Hours[k] = maps.Clone(v)
	}
	for k, v := range h.Days {
		out.Days[k] = maps.Clone(v)
	}
	for k, v := range h.Recap {
		out.Recap[k] = v
	}
	return out
}
