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
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/noticebucket"
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
	// shown is PresenceReport.shownSet: what the page draws, for lean records.
	shown map[wire.UUID]bool
	// device is a phone's or a tablet's connection (a control plane's channel for one, or
	// one the bridge bound): it can watch an agent, but it is not the Mac (#1509).
	device bool
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
	Forwarded   []wire.NeedID     `json:"forwarded"`
}

type attentionState struct {
	attentionMu sync.Mutex
	presences   map[int64]presence
	raisedAt    map[string]wire.Date
	raisedNeed  map[string]wire.NeedID
	deliveries  map[string]delivery
	settling    map[string]*time.Timer
	// announced is every need the clients were told of with no surface to show it on, by
	// token, so each is told when it ends too (#1367): a phone's model, and the widget it
	// writes from it, holds what attention/pending holds and nothing it has dropped.
	announced map[string]wire.NeedID
	// kept is what attention.json holds of another build's (withdrawals), written back as
	// it was; lastWritten is nil until the file has been read.
	kept        attentionRecords
	lastWritten *attentionRecords
	// forwarded is forwardedNeeds: what the control plane was offered and not yet told is
	// over, by token. A Swift host's offers are among them, so they are withdrawn too (#1367).
	forwarded   map[string]wire.NeedID
	toldWaiting *int64
	// toldTurns is the phase the control plane was last told of each recent session's turn
	// (#1744); nil says every one again.
	toldTurns map[wire.UUID]wire.TurnPhase
	// tellControl sends on the control plane's channel 0; nil when the host has none.
	tellControl atomic.Pointer[func(method string, params any)]
	// askControl asks the control plane on channel 0 and waits (workspacetools.go).
	askControl atomic.Pointer[askControl]
	// notices are what agents told the person and are still posted, and noticeBucket the
	// person's attention they share when this host has no control plane (#2805, notify.go).
	notices      []postedNotice
	noticeBucket noticebucket.Bucket
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
	case id.Notice != nil:
		return "notice:" + *id.Notice
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
	d.forwarded, d.announced = map[string]wire.NeedID{}, map[string]wire.NeedID{}
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
			for _, e := range raw.Forwarded {
				var id wire.NeedID
				if diskjson.Unmarshal(e, &id) == nil && token(id) != "" {
					r.Forwarded = append(r.Forwarded, id)
				}
			}
			r.Withdrawing = raw.Withdrawing
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
	for _, id := range r.Forwarded {
		d.forwarded[token(id)] = id
	}
	d.kept = attentionRecords{Withdrawing: r.Withdrawing}
	written := d.records()
	d.lastWritten = &written
}

func (d *Daemon) records() attentionRecords {
	r := attentionRecords{Raised: []raisedNote{}, Deliveries: []delivery{}, Withdrawing: d.kept.Withdrawing, Forwarded: []wire.NeedID{}}
	for t, at := range d.raisedAt {
		r.Raised = append(r.Raised, raisedNote{Need: d.raisedNeed[t], At: at})
	}
	for _, dv := range d.deliveries {
		r.Deliveries = append(r.Deliveries, dv)
	}
	for _, id := range d.forwarded {
		r.Forwarded = append(r.Forwarded, id)
	}
	sort.Slice(r.Forwarded, func(i, j int) bool { return token(r.Forwarded[i]) < token(r.Forwarded[j]) })
	sort.Slice(r.Raised, func(i, j int) bool { return token(r.Raised[i].Need) < token(r.Raised[j].Need) })
	sort.Slice(r.Deliveries, func(i, j int) bool { return token(r.Deliveries[i].NeedID) < token(r.Deliveries[j].NeedID) })
	if r.Withdrawing == nil {
		r.Withdrawing = []json.RawMessage{}
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
	wire.WorkOutcomeNeedsAnswer: "Waiting on your answer",
	wire.WorkOutcomeWaiting: "Waiting"}

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
	for _, p := range d.Store.Folders() {
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
		folder := folderPath(a)
		agentID := a.ID
		found = append(found, wire.Need{ID: id, AgentID: &agentID, Folder: fileURL(folder, true), Kind: kind, RaisedAt: raised,
			Headline: truncating(wire.Headline{H1: filepath.Base(folder), H2: title, H3: wanted, Answers: answers})})
	}
	for _, p := range d.pendingPermissions() {
		if a := d.Store.Agent(p.AgentID); a != nil && !archived[folderPath(a)] {
			id := p.ID
			need(wire.NeedID{Permission: &id}, a, wire.NeedKindPermission, "Wants to "+line(p.ToolCall), permissionAnswers(p))
		}
	}
	for _, e := range d.pendingElicitations() {
		if a := d.Store.Agent(e.AgentID); a != nil && !archived[folderPath(a)] {
			id := e.ID
			need(wire.NeedID{Elicitation: &id}, a, wire.NeedKindElicitation, "Asks: "+elicitationTitle(e), formAnswers(e))
		}
	}
	for _, a := range d.Store.Agents() {
		if a.State != wire.AgentStateFinished || a.Report == nil || !needsAPerson(a.Report.Outcome) || archived[folderPath(&a)] {
			continue
		}
		if a.ReportSeenAt != nil && *a.ReportSeenAt == a.Report.At {
			continue // looked at already
		}
		r := *a.Report
		need(wire.NeedID{Report: &wire.NeedIDReport{AgentID: a.ID, At: r.At}}, &a, wire.NeedKindReport, headings[r.Outcome]+": "+r.Message, nil)
	}
	// A change to the app's own files, made outside it (#531): asked in the session of the
	// agent that made it, or of the folder when none did.
	for _, p := range d.Store.Folders() {
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
	// What an agent told the person (#2805): posted as a need is, never a Needs you row.
	notices := d.noticeNeedsLocked(at.Time())
	found = append(found, notices...)
	for _, n := range notices {
		ids = append(ids, n.ID)
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

// muted says whether the need's session is muted (#2003): it sends no banner and no push,
// yet stays in the model that Needs you and the badge are drawn from.
func (d *Daemon) muted(id *wire.UUID) bool {
	if id == nil {
		return false
	}
	a := d.Store.Agent(*id)
	return a != nil && a.IsMuted != nil && *a.IsMuted
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

// macPresence is presencesBySurface for the Mac: an active report beats an idle one, and
// the latest heard among equals. A device's report is not the Mac's (#1509): an open iPad
// does not keep a need from the control plane, which chooses the device.
func (d *Daemon) macPresence() (presence, bool) {
	var best presence
	found := false
	for _, p := range d.presences {
		if p.device {
			continue
		}
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
	// Notices sent to the window now, for their lines (#2860), recorded once unlocked.
	var toComputer []string
	tell := d.tellControl.Load()
	var told []wire.AttentionNeed
	withdraw := func(t string) {
		if id, ok := d.forwarded[t]; ok {
			delete(d.forwarded, t)
			told = append(told, wire.AttentionNeed{Withdraw: &id})
			log.Printf("attention: %s withdrawn from the control plane", t)
		}
	}
	for t, dv := range d.deliveries {
		if !live[t] {
			delete(d.deliveries, t)
			delete(d.announced, t)
			notes = append(notes, wire.AttentionNotification{NeedID: dv.NeedID})
		}
	}
	for t, id := range d.announced {
		if !live[t] {
			delete(d.announced, t)
			notes = append(notes, wire.AttentionNotification{NeedID: id})
		}
	}
	// Met, or a need this build does not know (a Swift host's): the control plane hears
	// it is over, so a phone takes its banner and widget row down (#1367).
	if tell != nil {
		for t := range d.forwarded {
			if !live[t] {
				withdraw(t)
			}
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
		muted := d.muted(n.AgentID)
		switch {
		case muted: // Mute Notifications (#2003): under Needs you, and nowhere else
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
		// forward: a need shown nowhere this host can see goes to the control plane, which
		// chooses the device; one being looked at, or about to be, is withdrawn from it.
		if tell != nil {
			if wait || to != nil || watched || muted {
				withdraw(t)
			} else if _, ok := d.forwarded[t]; !ok {
				need, buzz, headline := n, true, n.Headline
				d.forwarded[t] = n.ID
				told = append(told, wire.AttentionNeed{Need: &need, Headline: &headline, Buzz: &buzz})
				log.Printf("attention: %s offered to the control plane", t)
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
			if to != nil && n.ID.Notice != nil {
				toComputer = append(toComputer, *n.ID.Notice)
			}
		case to == nil:
			// Shown nowhere, yet still news to every client (#1367): its model is what
			// Needs you and the phone's widget draw from. Not a banner: no surface is named.
			if _, ok := d.announced[t]; !ok {
				d.announced[t] = n.ID
				notes = append(notes, wire.AttentionNotification{NeedID: n.ID, Need: &need})
			}
		default:
			d.deliveries[t] = delivery{NeedID: n.ID, To: to, AlertedAt: wire.DateOf(at), AlertCount: 1}
			notes = append(notes, wire.AttentionNotification{NeedID: n.ID, Need: &need, To: to, Alert: true})
			if n.ID.Notice != nil {
				toComputer = append(toComputer, *n.ID.Notice)
			}
		}
	}
	// Each recent turn that moved, for its Live Activity (#1744).
	var turns []wire.AttentionTurn
	if tell != nil {
		turns = d.turnsMoved(outstanding, at)
	}
	// Every message carries the whole Needs you count, and the count goes alone when it
	// moved with nothing to offer or withdraw (#1163).
	if tell != nil {
		waiting := d.waitingCount()
		if len(told) == 0 && (d.toldWaiting == nil || *d.toldWaiting != waiting) {
			told = append(told, wire.AttentionNeed{})
		}
		for i := range told {
			told[i].Waiting = &waiting
		}
		if len(told) > 0 {
			d.toldWaiting = &waiting
		}
	}
	d.writeAttentionIfMoved()
	d.attentionMu.Unlock()
	for _, note := range notes {
		Broadcast(d, wire.NotifyAttentionChanged, note)
	}
	for _, m := range told {
		(*tell)(wire.CallAttentionNeed.Name, m)
	}
	for _, turn := range turns {
		(*tell)(wire.CallAttentionTurn.Name, turn)
	}
	for _, id := range toComputer {
		d.noticeWentTo(id, wire.NoticeDeviceComputer)
	}
}

// waitingCount is DaemonCore.waitingCount: the agents that need the person (Needs you or
// Blocked), the badge's count, outside archived folders. An unread finish is not
// counted (#1565).
func (d *Daemon) waitingCount() int64 {
	archived := map[string]bool{}
	for _, p := range d.Store.Folders() {
		if p.ArchivedAt != nil {
			archived[store.FolderPath(p.Folder)] = true
		}
	}
	var n int64
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived || archived[folderPath(&a)] {
			continue
		}
		if g := Group(&a); g == "needsAttention" || g == "blocked" {
			n++
		}
	}
	return n
}

// SetControl is where attention/need goes: the uplink's channel 0. A host of a control
// plane offers the needs it shows nowhere, and withdraws them when met (058 R6).
func (d *Daemon) SetControl(tell func(method string, params any)) {
	d.tellControl.Store(&tell)
	d.ControlUplinkChanged(true)
}

// ControlUplinkChanged is DaemonCore.controlUplinkChanged: a restored uplink knows nothing
// of offers dropped while it was down, so every live need is offered again, the stale ones
// withdrawn, and the count said again.
func (d *Daemon) ControlUplinkChanged(up bool) {
	if !up || d.tellControl.Load() == nil {
		return
	}
	d.attentionMu.Lock()
	if d.presences == nil {
		d.attentionMu.Unlock()
		return
	}
	live := map[string]bool{}
	for _, n := range d.needs() {
		live[token(n.ID)] = true
	}
	for t := range d.forwarded {
		if live[t] {
			delete(d.forwarded, t)
		}
	}
	d.toldWaiting = nil
	d.toldTurns = nil
	d.attentionMu.Unlock()
	// A control plane that just heard from this host hears whether it is idle (#1387).
	d.startHostStatus()
	// And the usage it has not sent yet (#1811).
	d.startReports()
	// And which folder is in which project (#2317).
	d.sendJoinedSoon()
	d.reconsider()
}

// reportPresence is presence/report: where a window is and what it shows. A window that
// comes to watch a chat has read it (markRead).
func (d *Daemon) reportPresence(c *Client, r wire.PresenceReport) {
	d.devMu.Lock()
	b, _ := d.callerDevice(c)
	d.devMu.Unlock()
	device := b != nil
	d.attentionMu.Lock()
	if d.presences == nil {
		d.attentionMu.Unlock()
		return
	}
	before, had := d.presences[c.ID]
	shown := map[wire.UUID]bool{}
	if r.Showing != nil {
		shown[*r.Showing] = true
	} else if r.Watching != nil {
		shown[*r.Watching] = true
	}
	for _, id := range r.AlsoShowing {
		shown[id] = true
	}
	d.presences[c.ID] = presence{watching: r.Watching, active: r.Active, heardAt: time.Now(), shown: shown, device: device}
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

// watched is whether an active window has this conversation in front of the person.
func (d *Daemon) watched(id wire.UUID) bool {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	for _, p := range d.presences {
		if p.active && p.watching != nil && *p.watching == id {
			return true
		}
	}
	return false
}

// markRead is DaemonCore.markRead: read, its report seen, and its file to see seen (#1802).
func (d *Daemon) markRead(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	unread := a.IsUnread != nil && *a.IsUnread
	unseen := a.Report != nil && (a.ReportSeenAt == nil || *a.ReportSeenAt != a.Report.At)
	if !unread && !unseen && a.FileToSee == nil {
		return
	}
	d.change(id, func(a *wire.Agent) {
		no := false
		a.IsUnread = &no
		a.FileToSee = nil
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
