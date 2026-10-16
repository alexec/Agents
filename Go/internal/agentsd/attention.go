package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// What wants the person ("Needs you"), as DaemonCore+Attention derives and routes it on a
// server: a card, a form, or a finished agent whose report says it cannot get further
// alone. A server has no devices of its own, so a need goes to the window (the "mac"
// surface every connection is) once it has been there long enough to look, or nowhere.
// When each need was first seen, and where it went, survive in <root>/attention.json.

// AttentionThresholds.standard; variables so a test can wait less.
var (
	macIdle         = 120 * time.Second
	settlingPause   = 20 * time.Second
	reAlertInterval = 300 * time.Second
)

const (
	headlineBudget  = 100
	answerBudget    = 40
	mostQuickAnswer = 4
)

type presence struct {
	watching *wire.UUID
	active   bool
	heardAt  time.Time
}

type delivery struct {
	NeedID      wire.NeedID   `json:"needID"`
	To          *wire.Surface `json:"to,omitempty"`
	AlertedAt   wire.Date     `json:"alertedAt"`
	AlertCount  int64         `json:"alertCount"`
	UnsentAlert *bool         `json:"unsentAlert,omitempty"`
}

type raisedNote struct {
	Need wire.NeedID `json:"need"`
	At   wire.Date   `json:"at"`
}

// attentionRecords is AttentionRecords, as attention.json holds them.
type attentionRecords struct {
	Raised      []raisedNote      `json:"raised"`
	Deliveries  []delivery        `json:"deliveries"`
	Withdrawing []json.RawMessage `json:"withdrawing"`
	Forwarded   []json.RawMessage `json:"forwarded"`
}

type attentionState struct {
	attentionMu sync.Mutex
	presences   map[int64]presence
	raisedAt    map[string]wire.Date
	raisedNeed  map[string]wire.NeedID
	deliveries  map[string]delivery
	settling    map[string]*time.Timer
	// kept is what attention.json holds of another build's (withdrawals, forwarded needs),
	// written back as it was; lastWritten is nil until the file has been read.
	kept        attentionRecords
	lastWritten *attentionRecords
}

// token is Need.token: one string per need, for keys and the file's order.
func token(id wire.NeedID) string {
	switch {
	case id.Permission != nil:
		return "permission:" + string(*id.Permission)
	case id.Elicitation != nil:
		return "elicitation:" + string(*id.Elicitation)
	case id.Report != nil:
		return fmt.Sprintf("report:%s:%v", id.Report.AgentID, float64(id.Report.At))
	case id.GuardedChange != nil:
		return "guarded:" + store.FolderPath(id.GuardedChange.Folder) + ":" + id.GuardedChange.Path
	}
	return ""
}

func (d *Daemon) attentionFile() string { return filepath.Join(d.Store.Loc.Root, "attention.json") }

// loadAttention reads the notes back: when each need was first seen, and where it went.
// A delivery to anywhere but the window names a device this host does not have.
func (d *Daemon) loadAttention() {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	d.presences, d.raisedAt, d.raisedNeed = map[int64]presence{}, map[string]wire.Date{}, map[string]wire.NeedID{}
	d.deliveries, d.settling = map[string]delivery{}, map[string]*time.Timer{}
	var r attentionRecords
	if b, err := os.ReadFile(d.attentionFile()); err == nil {
		var raw struct {
			Raised      []json.RawMessage `json:"raised"`
			Deliveries  []json.RawMessage `json:"deliveries"`
			Withdrawing []json.RawMessage `json:"withdrawing"`
			Forwarded   []json.RawMessage `json:"forwarded"`
		}
		if json.Unmarshal(b, &raw) == nil {
			// Each entry read on its own: one that will not read is dropped, not the file.
			for _, e := range raw.Raised {
				var n raisedNote
				if diskjson.Unmarshal(e, &n) == nil && token(n.Need) != "" {
					r.Raised = append(r.Raised, n)
				}
			}
			for _, e := range raw.Deliveries {
				var dv delivery
				if diskjson.Unmarshal(e, &dv) == nil && token(dv.NeedID) != "" && (dv.To == nil || dv.To.Mac != nil) {
					r.Deliveries = append(r.Deliveries, dv)
				}
			}
			r.Withdrawing, r.Forwarded = raw.Withdrawing, raw.Forwarded
		}
	}
	for _, n := range r.Raised {
		d.raisedAt[token(n.Need)], d.raisedNeed[token(n.Need)] = n.At, n.Need
	}
	for _, dv := range r.Deliveries {
		if _, ok := d.deliveries[token(dv.NeedID)]; !ok {
			d.deliveries[token(dv.NeedID)] = dv
		}
	}
	d.kept = attentionRecords{Withdrawing: r.Withdrawing, Forwarded: r.Forwarded}
	written := d.records()
	d.lastWritten = &written
}

func (d *Daemon) records() attentionRecords {
	r := attentionRecords{Raised: []raisedNote{}, Deliveries: []delivery{}, Withdrawing: d.kept.Withdrawing, Forwarded: d.kept.Forwarded}
	for t, at := range d.raisedAt {
		r.Raised = append(r.Raised, raisedNote{Need: d.raisedNeed[t], At: at})
	}
	for _, dv := range d.deliveries {
		r.Deliveries = append(r.Deliveries, dv)
	}
	sort.Slice(r.Raised, func(i, j int) bool { return token(r.Raised[i].Need) < token(r.Raised[j].Need) })
	sort.Slice(r.Deliveries, func(i, j int) bool { return token(r.Deliveries[i].NeedID) < token(r.Deliveries[j].NeedID) })
	if r.Withdrawing == nil {
		r.Withdrawing = []json.RawMessage{}
	}
	if r.Forwarded == nil {
		r.Forwarded = []json.RawMessage{}
	}
	return r
}

// writeAttentionIfMoved writes the notes only when they have changed, and never before
// they have been read.
func (d *Daemon) writeAttentionIfMoved() {
	if d.lastWritten == nil {
		return
	}
	r := d.records()
	if reflect.DeepEqual(r, *d.lastWritten) {
		return
	}
	b, err := diskjson.Marshal(r)
	if err == nil {
		err = store.WriteAtomically(d.attentionFile(), b, 0o644)
	}
	if err != nil {
		log.Printf("attention: could not save: %v", err)
		return
	}
	d.lastWritten = &r
}

// line is ToolCall.line: its own description where it gives one, else its title.
func line(tc wire.ToolCall) string {
	var in struct {
		Description *string `json:"description"`
	}
	if json.Unmarshal(tc.RawInput, &in) == nil && in.Description != nil && strings.TrimSpace(*in.Description) != "" {
		return *in.Description
	}
	return tc.Title
}

var headings = map[wire.WorkOutcome]string{wire.WorkOutcomeDone: "Complete", wire.WorkOutcomeNothingToDo: "Nothing to do",
	wire.WorkOutcomeNeedsAnswer: "Waiting on your answer", wire.WorkOutcomePartlyDone: "Partly done",
	wire.WorkOutcomeStuck: "Stuck", wire.WorkOutcomeBlocked: "Blocked"}

func cut(s string, budget int) string {
	if utf8.RuneCountInString(s) > budget {
		return string([]rune(s)[:budget-1]) + "…"
	}
	return s
}

// truncating is Headline.truncating: each line trimmed, a placeholder for an empty one,
// and none past its budget.
func truncating(h wire.Headline) wire.Headline {
	field := func(s, placeholder string) string {
		s = strings.TrimSpace(s)
		if s == "" {
			s = placeholder
		}
		return cut(s, headlineBudget)
	}
	h.H1, h.H2, h.H3 = field(h.H1, "Agents"), field(h.H2, "An agent"), field(h.H3, "needs you")
	for i, a := range h.Answers {
		title := strings.TrimSpace(a.Title)
		if title == "" {
			if a.Kind == wire.QuickAnswerKindReply {
				title = "Reply"
			} else {
				title = a.ID
			}
		}
		h.Answers[i].Title = cut(title, answerBudget)
	}
	return h
}

// permissionAnswers is QuickAnswer.answers(for:) for a card: its options, when there are
// at most four.
func permissionAnswers(r wire.PermissionRequest) []wire.QuickAnswer {
	if len(r.Options) == 0 || len(r.Options) > mostQuickAnswer {
		return nil
	}
	var out []wire.QuickAnswer
	for _, o := range r.Options {
		out = append(out, wire.QuickAnswer{Kind: wire.QuickAnswerKindChoice, ID: o.OptionID, Title: o.Name,
			IsDestructive: o.Kind == "reject_once" || o.Kind == "reject_always"})
	}
	return out
}

// formAnswers is QuickAnswer.answers(for:) for a form of one page whose question is a
// string: its two to four choices, or one free reply.
func formAnswers(r wire.ElicitationRequest) []wire.QuickAnswer {
	if r.Mode.Form == nil {
		return nil
	}
	ps := pages(r.Mode.Form.Value)
	if len(ps) != 1 || ps[0][0].Kind.String == nil {
		return nil
	}
	p, k := ps[0][0], ps[0][0].Kind.String
	field := p.Name
	if len(k.Choices) > 0 {
		if len(k.Choices) < 2 || len(k.Choices) > mostQuickAnswer {
			return nil
		}
		var out []wire.QuickAnswer
		for _, c := range k.Choices {
			out = append(out, wire.QuickAnswer{Kind: wire.QuickAnswerKindChoice, ID: c.Value, Title: c.Title, Field: &field})
		}
		return out
	}
	if len(ps[0]) != 1 || k.Format != nil {
		return nil
	}
	return []wire.QuickAnswer{{Kind: wire.QuickAnswerKindReply, ID: "", Title: "Reply", Field: &field}}
}

// needs is DaemonCore.needs: derived, never stored, but for when each was first seen.
// Called with attentionMu held.
func (d *Daemon) needs() []wire.Need {
	at := now()
	archived := map[string]bool{}
	for _, p := range d.Store.Projects() {
		if p.ArchivedAt != nil {
			archived[store.FolderPath(p.Folder)] = true
		}
	}
	var found []wire.Need
	var ids []wire.NeedID
	need := func(id wire.NeedID, a *wire.Agent, kind wire.NeedKind, wanted string, answers []wire.QuickAnswer) {
		t := token(id)
		raised, ok := d.raisedAt[t]
		if !ok {
			raised = at
			d.raisedAt[t], d.raisedNeed[t] = raised, id
		}
		ids = append(ids, id)
		title := ""
		if a.Title != nil {
			title = *a.Title
		}
		folder := projectFolder(a)
		agentID := a.ID
		found = append(found, wire.Need{ID: id, AgentID: &agentID, Folder: fileURL(folder, true), Kind: kind, RaisedAt: raised,
			Headline: truncating(wire.Headline{H1: filepath.Base(folder), H2: title, H3: wanted, Answers: answers})})
	}
	for _, p := range d.pendingPermissions() {
		if a := d.Store.Agent(p.AgentID); a != nil && !archived[projectFolder(a)] {
			id := p.ID
			need(wire.NeedID{Permission: &id}, a, wire.NeedKindPermission, "Wants to "+line(p.ToolCall), permissionAnswers(p))
		}
	}
	for _, e := range d.pendingElicitations() {
		if a := d.Store.Agent(e.AgentID); a != nil && !archived[projectFolder(a)] {
			id := e.ID
			need(wire.NeedID{Elicitation: &id}, a, wire.NeedKindElicitation, "Asks: "+elicitationTitle(e), formAnswers(e))
		}
	}
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateFinished || a.Report == nil || !needsAPerson(a.Report.Outcome) || archived[projectFolder(&a)] {
			continue
		}
		if a.ReportSeenAt != nil && *a.ReportSeenAt == a.Report.At {
			continue // looked at already
		}
		r := *a.Report
		need(wire.NeedID{Report: &wire.NeedIDReport{AgentID: a.ID, At: r.At}}, &a, wire.NeedKindReport, headings[r.Outcome]+": "+r.Message, nil)
	}
	// A change to the app's own files, made outside it (#531): asked in the session of the
	// agent that made it, or of the project when none did.
	for _, p := range d.Store.Projects() {
		folder := store.FolderPath(p.Folder)
		if p.ArchivedAt != nil {
			continue
		}
		for _, c := range d.guardedChanges(folder) {
			id := wire.NeedID{GuardedChange: &wire.NeedIDGuardedChange{Folder: fileURL(folder, true), Path: c.Path}}
			t := token(id)
			raised, ok := d.raisedAt[t]
			if !ok {
				raised = at
				d.raisedAt[t], d.raisedNeed[t] = raised, id
			}
			ids = append(ids, id)
			title := ""
			if c.AskedIn != nil {
				if a := d.Store.Agent(*c.AskedIn); a != nil && a.Title != nil {
					title = *a.Title
				}
			}
			found = append(found, wire.Need{ID: id, AgentID: c.AskedIn, Folder: fileURL(folder, true), Kind: wire.NeedKindGuardedChange,
				RaisedAt: raised, Headline: truncating(wire.Headline{H1: filepath.Base(folder), H2: title, H3: guardedHeadline(c)})})
		}
	}
	// Forget the first-seen time of anything no longer outstanding.
	live := map[string]bool{}
	for _, id := range ids {
		live[token(id)] = true
	}
	for t := range d.raisedAt {
		if !live[t] {
			delete(d.raisedAt, t)
			delete(d.raisedNeed, t)
		}
	}
	sort.SliceStable(found, func(i, j int) bool { return found[i].RaisedAt < found[j].RaisedAt })
	return found
}

func (d *Daemon) attentionPending() wire.AttentionPending {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	out := wire.AttentionPending{Needs: d.needs(), Deliveries: []wire.AttentionDelivery{}}
	for _, n := range out.Needs {
		if dv, ok := d.deliveries[token(n.ID)]; ok {
			out.Deliveries = append(out.Deliveries, wire.AttentionDelivery{NeedID: n.ID, To: dv.To})
		}
	}
	if out.Needs == nil {
		out.Needs = []wire.Need{}
	}
	return out
}

// macPresence is presencesBySurface for the one surface a server has: an active report
// beats an idle one, and the latest heard among equals.
func (d *Daemon) macPresence() (presence, bool) {
	var best presence
	found := false
	for _, p := range d.presences {
		if !found || (p.active && !best.active) || (p.active == best.active && p.heardAt.After(best.heardAt)) {
			best, found = p, true
		}
	}
	return best, found
}

// reconsider is DaemonCore.reconsider on a server: for every outstanding need, the
// ladder's first, second and last rungs, and attention/changed for what moved.
func (d *Daemon) reconsider() {
	d.attentionMu.Lock()
	if d.presences == nil {
		d.attentionMu.Unlock()
		return
	}
	at := now().Time()
	outstanding := d.needs()
	live := map[string]bool{}
	for _, n := range outstanding {
		live[token(n.ID)] = true
	}
	var notes []wire.AttentionNotification
	for t, dv := range d.deliveries {
		if !live[t] {
			delete(d.deliveries, t)
			notes = append(notes, wire.AttentionNotification{NeedID: dv.NeedID})
		}
	}
	for t, timer := range d.settling {
		if !live[t] {
			timer.Stop()
			delete(d.settling, t)
		}
	}
	mac, here := d.macPresence()
	here = here && mac.active && at.Sub(mac.heardAt) < macIdle
	for _, n := range outstanding {
		t := token(n.ID)
		var to *wire.Surface
		alert, wait := false, false
		watched := false
		for _, p := range d.presences {
			watched = watched || (p.active && p.watching != nil && n.AgentID != nil && *p.watching == *n.AgentID)
		}
		switch {
		case watched: // rung 1: it is on screen already
		case here: // rung 2: at the window, after a moment to look
			if at.Sub(n.RaisedAt.Time()) < settlingPause {
				wait = true
			} else {
				to = &wire.Surface{Mac: &struct{}{}}
				// Routing.alert: always for a first delivery, never for the same surface,
				// and again elsewhere once the interval has passed.
				switch dv, ok := d.deliveries[t]; {
				case !ok:
					alert = true
				case reflect.DeepEqual(dv.To, to):
				default:
					alert = at.Sub(dv.AlertedAt.Time()) >= reAlertInterval
				}
			}
		}
		if wait {
			if d.settling[t] == nil {
				due := max(0, n.RaisedAt.Time().Add(settlingPause).Sub(at))
				d.settling[t] = time.AfterFunc(due, func() {
					d.attentionMu.Lock()
					delete(d.settling, t)
					d.attentionMu.Unlock()
					d.reconsider()
				})
			}
			continue
		}
		if timer := d.settling[t]; timer != nil {
			timer.Stop()
			delete(d.settling, t)
		}
		dv, ok := d.deliveries[t]
		need := n
		switch {
		case ok && reflect.DeepEqual(dv.To, to):
		case ok:
			dv.To, dv.UnsentAlert = to, nil
			if alert {
				dv.AlertedAt, dv.AlertCount = wire.DateOf(at), dv.AlertCount+1
			}
			d.deliveries[t] = dv
			notes = append(notes, wire.AttentionNotification{NeedID: n.ID, Need: &need, To: to, Alert: alert})
		case to == nil:
		default:
			d.deliveries[t] = delivery{NeedID: n.ID, To: to, AlertedAt: wire.DateOf(at), AlertCount: 1}
			notes = append(notes, wire.AttentionNotification{NeedID: n.ID, Need: &need, To: to, Alert: true})
		}
	}
	d.writeAttentionIfMoved()
	d.attentionMu.Unlock()
	for _, note := range notes {
		Broadcast(d, wire.NotifyAttentionChanged, note)
	}
}

// reportPresence is presence/report: where a window is and what it shows. A window that
// comes to watch a chat has read it (markRead).
func (d *Daemon) reportPresence(c *Client, r wire.PresenceReport) {
	d.attentionMu.Lock()
	if d.presences == nil {
		d.attentionMu.Unlock()
		return
	}
	before, had := d.presences[c.ID]
	d.presences[c.ID] = presence{watching: r.Watching, active: r.Active, heardAt: time.Now()}
	d.attentionMu.Unlock()
	var was *wire.UUID
	if had && before.active {
		was = before.watching
	}
	if r.Active && r.Watching != nil && (was == nil || *was != *r.Watching) {
		d.markRead(*r.Watching)
	}
	d.reconsider()
}

func (d *Daemon) forgetPresence(c *Client) {
	d.attentionMu.Lock()
	_, had := d.presences[c.ID]
	delete(d.presences, c.ID)
	d.attentionMu.Unlock()
	if had {
		d.reconsider()
	}
}

// markRead is DaemonCore.markRead: read, and its report seen.
func (d *Daemon) markRead(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	unread := a.IsUnread != nil && *a.IsUnread
	unseen := a.Report != nil && (a.ReportSeenAt == nil || *a.ReportSeenAt != a.Report.At)
	if !unread && !unseen {
		return
	}
	d.change(id, func(a *wire.Agent) {
		no := false
		a.IsUnread = &no
		if a.Report != nil {
			seen := a.Report.At
			a.ReportSeenAt = &seen
		}
	})
}

func (d *Daemon) registerAttention() {
	On(d, wire.CallAttentionPending, func(ctx context.Context, c *Client, _ wire.Empty) (wire.AttentionPending, error) {
		return d.attentionPending(), nil
	})
	On(d, wire.CallPresenceReport, func(ctx context.Context, c *Client, r wire.PresenceReport) (wire.Empty, error) {
		d.reportPresence(c, r)
		return wire.Empty{}, nil
	})
}
