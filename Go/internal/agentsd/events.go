package agentsd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Events (042), as DaemonCore+Events, EventLog and EventStore keep them: one funnel,
// raise, gives each event its place, writes it to <root>/events.jsonl, and tells the
// windows. The log keeps seven days and at most 10,000 events; a repeat inside a minute
// folds into the last event. <root>/events-state.json holds the next position (a block of
// 64 at a time) and what the sources remember between runs.

const (
	eventRepeatWindow  = 60 * time.Second
	eventKeepFor       = 7 * 24 * time.Hour
	eventMaximum       = 10_000
	eventPageLimit     = 200
	eventPositionBlock = 64
	eventCapMargin     = 500

	maximumEventDetails      = 10
	maximumEventDetailLength = 200
	maximumEventMessage      = 500
)

// eventState is EventState, events-state.json.
type eventState struct {
	NextPosition  int64                        `json:"nextPosition"`
	BranchTips    map[string]map[string]string `json:"branchTips"`
	CostCrossings map[string][]string          `json:"costCrossings"`
	DiskLevels    map[string]string            `json:"diskLevels,omitempty"`
	// PersonAway is how the person stood when a Mac's host last heard (#1219): kept as
	// the Swift host wrote it.
	PersonAway *string `json:"personAway,omitempty"`
	// WaitRestarts is an open wait's id → the restarts it was open over (#1219), told
	// when it next wakes.
	WaitRestarts map[string][]restartGap `json:"waitRestarts,omitempty"`
}

type eventBook struct {
	eventMu            sync.Mutex
	eventList          []wire.Event // oldest first, by position
	eventStateNow      eventState
	eventStateSaved    []byte // events-state.json as last read or written
	positionsReserved  int64  // the end of the block of positions written down
	eventLinesAppended int    // lines appended since the file was last written whole
	eventFile          *os.File
	eventPruner        *time.Ticker
}

// eventLine is EventStore.Line: an event, a consequence of one, or its repeats.
type eventLine struct {
	Event       *wire.Event       `json:"event,omitempty"`
	Consequence *wire.Consequence `json:"consequence,omitempty"`
	Position    *int64            `json:"position,omitempty"`
	Repeat      *int64            `json:"repeat,omitempty"`
	At          *wire.Date        `json:"at,omitempty"`
	Count       *int64            `json:"count,omitempty"`
}

func (d *Daemon) eventsPath() string { return filepath.Join(d.Store.Loc.Root, "events.jsonl") }
func (d *Daemon) eventStatePath() string {
	return filepath.Join(d.Store.Loc.Root, "events-state.json")
}

// loadEvents is EventStore.load and loadState: the log replayed line by line, a torn last
// line skipped, a file with other unreadable lines kept whole beside it first.
func (d *Daemon) loadEvents() {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	d.eventStateNow = eventState{NextPosition: 1}
	if b, err := os.ReadFile(d.eventStatePath()); err == nil {
		if diskjson.Unmarshal(b, &d.eventStateNow) != nil {
			log.Printf("events-state.json: unreadable, starting afresh")
			d.eventStateNow = eventState{NextPosition: 1}
		} else {
			d.eventStateSaved = b
		}
	}
	if d.eventStateNow.NextPosition < 1 {
		d.eventStateNow.NextPosition = 1
	}
	data, err := os.ReadFile(d.eventsPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("events.jsonl: %v; starting with no events", err)
	}
	lines := bytes.Split(data, []byte("\n"))
	var kept [][]byte
	for _, l := range lines {
		if len(l) > 0 {
			kept = append(kept, l)
		}
	}
	unreadable, torn, repeats := 0, false, 0
	for i, raw := range kept {
		var line eventLine
		if diskjson.Unmarshal(raw, &line) != nil || line.Event == nil && line.Consequence == nil && line.Repeat == nil {
			if i == len(kept)-1 {
				torn = true
			} else {
				unreadable++
			}
			continue
		}
		switch {
		case line.Event != nil:
			e := *line.Event
			if e.Consequences == nil {
				e.Consequences = []wire.Consequence{}
			}
			d.insertEvent(e)
		case line.Consequence != nil && line.Position != nil:
			d.addConsequenceLocked(*line.Consequence, *line.Position)
		case line.Repeat != nil && line.At != nil && line.Count != nil:
			if i := d.eventIndex(*line.Repeat); i >= 0 {
				at := *line.At
				d.eventList[i].Count, d.eventList[i].LastAt = *line.Count, &at
			}
			repeats++
		}
	}
	d.eventLinesAppended = repeats
	if unreadable > 0 {
		aside := fmt.Sprintf("%s.unreadable-%d", d.eventsPath(), time.Now().Unix())
		if len(d.eventList) == 0 {
			os.Rename(d.eventsPath(), aside)
		} else {
			os.WriteFile(aside, data, 0o644)
		}
		store.TrimSetAsides(d.eventsPath())
		log.Printf("events.jsonl: skipped %d unreadable line(s); the whole file is kept as %s", unreadable, filepath.Base(aside))
	}
	if torn {
		log.Printf("events.jsonl: skipped a torn last line (%d bytes), from a daemon stopped mid-write", len(kept[len(kept)-1]))
	}
	// A state file lost or older than the log never hands out a position the log has.
	if h := d.eventHead(); d.eventStateNow.NextPosition <= h {
		d.eventStateNow.NextPosition = h + 1
	}
	d.positionsReserved = d.eventStateNow.NextPosition
	d.pruneEventsLocked()
	d.eventPruner = time.NewTicker(time.Hour)
	t := d.eventPruner
	safe.Go("event pruner", func() {
		for {
			select {
			case <-t.C:
				d.eventMu.Lock()
				d.pruneEventsLocked()
				d.eventMu.Unlock()
			case <-d.ctx.Done():
				return
			}
		}
	})
}

func (d *Daemon) stopEvents() {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	if d.eventPruner != nil {
		d.eventPruner.Stop()
	}
	if d.eventFile != nil {
		d.eventFile.Close()
		d.eventFile = nil
	}
}

func (d *Daemon) eventHead() int64 {
	if len(d.eventList) == 0 {
		return 0
	}
	return d.eventList[len(d.eventList)-1].Position
}

func (d *Daemon) eventIndex(position int64) int {
	i := sort.Search(len(d.eventList), func(i int) bool { return d.eventList[i].Position >= position })
	if i < len(d.eventList) && d.eventList[i].Position == position {
		return i
	}
	return -1
}

func (d *Daemon) insertEvent(e wire.Event) {
	if i := d.eventIndex(e.Position); i >= 0 {
		d.eventList[i] = e
		return
	}
	d.eventList = append(d.eventList, e)
	if n := len(d.eventList); n > 1 && d.eventList[n-2].Position > e.Position {
		sort.Slice(d.eventList, func(i, j int) bool { return d.eventList[i].Position < d.eventList[j].Position })
	}
}

// consequenceWorkflow is Consequence.workflow: the workflow it is about, by folder and id.
func consequenceWorkflow(c wire.Consequence) string {
	switch {
	case c.Fired != nil:
		return store.FolderPath(c.Fired.Folder) + "/" + c.Fired.WorkflowID
	case c.Refused != nil:
		return store.FolderPath(c.Refused.Folder) + "/" + c.Refused.WorkflowID
	}
	return ""
}

// waitingFire is Consequence.isWaiting: a fire queued behind a run or held by a cooldown.
func waitingFire(c wire.Consequence) bool {
	return c.Refused != nil && (c.Refused.Reason.Queued != nil || c.Refused.Reason.CoolingDown != nil)
}

// addConsequenceLocked is EventLog.addConsequence: what came of a waiting fire takes the
// waiting's place.
func (d *Daemon) addConsequenceLocked(c wire.Consequence, position int64) *wire.Event {
	i := d.eventIndex(position)
	if i < 0 {
		return nil
	}
	e := &d.eventList[i]
	if w := consequenceWorkflow(c); w != "" {
		kept := e.Consequences[:0:0]
		for _, old := range e.Consequences {
			if !(waitingFire(old) && consequenceWorkflow(old) == w) {
				kept = append(kept, old)
			}
		}
		e.Consequences = kept
	}
	e.Consequences = append(e.Consequences, c)
	out := copyEvent(*e)
	return &out
}

// copyEvent is an event that shares no list with the log, to be sent while the log moves on.
func copyEvent(e wire.Event) wire.Event {
	e.Consequences = append([]wire.Consequence{}, e.Consequences...)
	return e
}

func eventLatest(e wire.Event) time.Time {
	if e.LastAt != nil {
		return e.LastAt.Time()
	}
	return e.At.Time()
}

// pruneEventsLocked is EventLog.prune and pruneEvents: what is too old, then too many,
// dropped, and the file written afresh when anything went.
func (d *Daemon) pruneEventsLocked() {
	cutoff := nowFunc().Add(-eventKeepFor)
	kept := d.eventList[:0]
	for _, e := range d.eventList {
		if !eventLatest(e).Before(cutoff) {
			kept = append(kept, e)
		}
	}
	gone := len(d.eventList) - len(kept)
	d.eventList = kept
	if len(d.eventList) > eventMaximum {
		gone += len(d.eventList) - eventMaximum
		d.eventList = append([]wire.Event(nil), d.eventList[len(d.eventList)-eventMaximum:]...)
	}
	if gone > 0 {
		d.rewriteEventsLocked()
	}
}

func encodeEventLine(l eventLine) []byte {
	b, err := diskjson.Marshal(l)
	if err != nil {
		log.Printf("events.jsonl: encode: %v", err)
		return nil
	}
	return append(b, '\n')
}

// appendEventLocked is EventStore.append: one write on an O_APPEND descriptor, so a line
// lands whole at the end; a file left ending in a torn line is given a newline first.
func (d *Daemon) appendEventLocked(l eventLine) {
	b := encodeEventLine(l)
	if b == nil {
		return
	}
	if d.eventFile == nil {
		path := d.eventsPath()
		os.MkdirAll(filepath.Dir(path), 0o755)
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
		if err != nil {
			log.Printf("events.jsonl: could not append: %v", err)
			return
		}
		if endsTorn(path) {
			f.Write([]byte("\n"))
		}
		d.eventFile = f
	}
	if _, err := d.eventFile.Write(b); err != nil {
		log.Printf("events.jsonl: could not append: %v", err)
		d.eventFile.Close()
		d.eventFile = nil
		return
	}
	d.eventLinesAppended++
}

func endsTorn(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() == 0 {
		return false
	}
	last := make([]byte, 1)
	if _, err := f.ReadAt(last, st.Size()-1); err != nil {
		return false
	}
	return last[0] != '\n'
}

// rewriteEventsLocked is EventStore.rewrite: the whole log as the lines it would have been
// appended as, written through a temporary file and a rename.
func (d *Daemon) rewriteEventsLocked() {
	var buf bytes.Buffer
	for _, e := range d.eventList {
		bare := e
		bare.Consequences = []wire.Consequence{}
		buf.Write(encodeEventLine(eventLine{Event: &bare}))
		for _, c := range e.Consequences {
			p := e.Position
			buf.Write(encodeEventLine(eventLine{Consequence: &c, Position: &p}))
		}
		if e.Count > 1 {
			p, at, n := e.Position, wire.DateOf(eventLatest(e)), e.Count
			buf.Write(encodeEventLine(eventLine{Repeat: &p, At: &at, Count: &n}))
		}
	}
	if d.eventFile != nil {
		d.eventFile.Close()
		d.eventFile = nil
	}
	if err := store.WriteAtomically(d.eventsPath(), buf.Bytes(), 0o644); err != nil {
		log.Printf("events.jsonl: could not rewrite: %v", err)
		return
	}
	d.eventLinesAppended = 0
}

// saveEventStateLocked writes events-state.json, saying the end of the reserved block as
// the next position, and only when it changed.
func (d *Daemon) saveEventStateLocked() {
	s := d.eventStateNow
	s.NextPosition = max(s.NextPosition, d.positionsReserved)
	if s.BranchTips == nil {
		s.BranchTips = map[string]map[string]string{}
	}
	if s.CostCrossings == nil {
		s.CostCrossings = map[string][]string{}
	}
	b, err := diskjson.Marshal(s)
	if err != nil || bytes.Equal(b, d.eventStateSaved) {
		return
	}
	if err := store.WriteAtomically(d.eventStatePath(), b, 0o644); err != nil {
		log.Printf("events-state.json: could not save: %v", err)
		return
	}
	d.eventStateSaved = b
}

func sameScope(a, b wire.EventScope) bool {
	if a.Mac != nil || b.Mac != nil {
		return a.Mac != nil && b.Mac != nil
	}
	if a.Folder == nil || b.Folder == nil {
		return false
	}
	return store.FolderPath(a.Folder.Value) == store.FolderPath(b.Folder.Value)
}

func macScope() wire.EventScope { return wire.EventScope{Mac: &struct{}{}} }

func folderScope(folder string) wire.EventScope {
	return wire.EventScope{Folder: &wire.EventScopeFolder{Value: store.FolderURL(folder)}}
}

func sameDetails(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

func sameMessage(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}

// raise is DaemonCore.raise: the event its place (or folded into the last when it is the
// same again within a minute), written down, then told.
func (d *Daemon) raise(draft wire.EventDraft) wire.Event { return d.raiseAs(draft, nil) }

// raiseAs is raise for an event a person's call raised: it carries their actor (#1751).
func (d *Daemon) raiseAs(draft wire.EventDraft, actor *wire.AuditActor) wire.Event {
	if draft.Details == nil {
		draft.Details = map[string]string{}
	}
	if draft.Scope.Folder != nil {
		draft.Scope = folderScope(store.FolderPath(draft.Scope.Folder.Value))
	}
	d.eventMu.Lock()
	t := nowFunc()
	var e wire.Event
	if n := len(d.eventList); n > 0 && d.isRepeat(draft, actor, d.eventList[n-1], t) {
		last := &d.eventList[n-1]
		last.Count++
		at := wire.DateOf(t)
		last.LastAt = &at
		e = copyEvent(*last)
		p, c := e.Position, e.Count
		d.appendEventLocked(eventLine{Repeat: &p, At: &at, Count: &c})
		if d.eventLinesAppended > eventMaximum+eventCapMargin {
			d.rewriteEventsLocked()
		}
	} else {
		e = wire.Event{Position: d.eventStateNow.NextPosition, Name: draft.Name, At: draft.At, Count: 1, Scope: draft.Scope,
			Sentence: draft.Sentence, Details: draft.Details, Message: draft.Message, ChainDepth: draft.ChainDepth,
			Consequences: []wire.Consequence{}, Actor: actor}
		// The next position is written before the event, a block at a time, so a host
		// killed between the two leaves a gap, never one position given out twice.
		d.eventStateNow.NextPosition = e.Position + 1
		if d.eventStateNow.NextPosition > d.positionsReserved {
			d.positionsReserved = d.eventStateNow.NextPosition + eventPositionBlock
			d.saveEventStateLocked()
		}
		d.eventList = append(d.eventList, e)
		d.appendEventLocked(eventLine{Event: &e})
		if len(d.eventList) > eventMaximum+eventCapMargin {
			d.pruneEventsLocked()
		}
	}
	d.eventMu.Unlock()
	d.tellEvents(&e)
	d.matchWaits(e)
	d.fireWorkflows(e)
	if got := d.event(e.Position); got != nil {
		return *got
	}
	return e
}

func (d *Daemon) isRepeat(draft wire.EventDraft, actor *wire.AuditActor, last wire.Event, t time.Time) bool {
	return last.Name == draft.Name && sameScope(last.Scope, draft.Scope) && sameDetails(last.Details, draft.Details) &&
		sameActor(last.Actor, actor) &&
		last.Publisher == nil && sameMessage(last.Message, draft.Message) && t.Sub(eventLatest(last)) < eventRepeatWindow
}

// addConsequence writes down what came of an event, and tells the windows.
func (d *Daemon) addConsequence(c wire.Consequence, position int64) {
	d.eventMu.Lock()
	e := d.addConsequenceLocked(c, position)
	if e != nil {
		p := position
		d.appendEventLocked(eventLine{Consequence: &c, Position: &p})
	}
	d.eventMu.Unlock()
	if e != nil {
		d.tellEvents(e)
	}
}

func (d *Daemon) event(position int64) *wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	if i := d.eventIndex(position); i >= 0 {
		e := copyEvent(d.eventList[i])
		return &e
	}
	return nil
}

// tellEvents is broadcastEvents: the event that is new or changed, and who waits.
func (d *Daemon) tellEvents(e *wire.Event) {
	Broadcast(d, wire.NotifyEventsChanged, wire.EventsChange{Event: e, Waiting: d.waitingAgents()})
}

// eventGroup is EventSubject.group: the page's capsule for an event's name.
func eventGroup(name string) (wire.EventGroup, bool) {
	subject, _, ok := strings.Cut(name, ".")
	if !ok {
		return "", false
	}
	switch subject {
	case "agent", "folder":
		return wire.EventGroupAgents, true
	case "workflow":
		return wire.EventGroupWorkflows, true
	case "branch":
		return wire.EventGroupBranches, true
	case "dropbox":
		return wire.EventGroupDropbox, true
	case "mac", "machine", "person", "lease", "cost", "server":
		return wire.EventGroupMac, true
	}
	return "", false
}

// eventsPage is EventLog.query: newest first, narrowed to a scope and groups, a page back
// from a position the reader has.
func (d *Daemon) eventsPage(r wire.EventsListRequest) wire.EventsPage {
	limit := int(r.Limit)
	if limit == 0 {
		limit = eventPageLimit
	}
	limit = max(1, min(limit, eventPageLimit))
	groups := map[wire.EventGroup]bool{}
	for _, g := range r.Groups {
		groups[g] = true
	}
	page := []wire.Event{}
	more := false
	d.eventMu.Lock()
	for i := len(d.eventList) - 1; i >= 0; i-- {
		e := d.eventList[i]
		if r.Before != nil && e.Position >= *r.Before {
			continue
		}
		if r.Scope != nil && !sameScope(*r.Scope, e.Scope) {
			continue
		}
		if r.Groups != nil {
			if g, ok := eventGroup(e.Name); !ok || !groups[g] {
				continue
			}
		}
		if len(page) == limit {
			more = true
			break
		}
		page = append(page, copyEvent(e))
	}
	d.eventMu.Unlock()
	return wire.EventsPage{Events: page, Waiting: d.waitingAgents(), HasMore: more}
}

var eventNameShape = regexp.MustCompile(`^[a-z][a-z_]*\.[a-z][a-z0-9_]*$`)

// serverNameShape is EventCatalogue.isEventName: noun.verbed, whoever raises it.
var serverNameShape = regexp.MustCompile(`^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`)

// draftProblem is EventDraft.problem: why a draft cannot be recorded, or "".
func draftProblem(d wire.EventDraft) string {
	if !eventNameShape.MatchString(d.Name) {
		return `"` + d.Name + `" is not an event name: it is lowercase words joined by a dot, like branch.moved.`
	}
	if len(d.Details) > maximumEventDetails {
		return fmt.Sprintf("An event carries at most %d details; this one has %d.", maximumEventDetails, len(d.Details))
	}
	keys := make([]string, 0, len(d.Details))
	for k := range d.Details {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if len([]rune(d.Details[k])) > maximumEventDetailLength {
			return fmt.Sprintf(`The detail "%s" is longer than %d characters.`, k, maximumEventDetailLength)
		}
	}
	if d.Message != nil && len([]rune(*d.Message)) > maximumEventMessage {
		return fmt.Sprintf("The message is longer than %d characters.", maximumEventMessage)
	}
	return ""
}

func eventRefused(message string) error {
	return &Error{Code: int(wire.FailureEventRefused), Message: message}
}

// agentDetails is DaemonCore.agentDetails: the agent, and what it was at that moment.
func agentDetails(a *wire.Agent) map[string]string {
	startedBy := "person"
	if a.StartedByAgent != nil {
		startedBy = "agent"
	} else if a.StartedByWorkflow != nil {
		startedBy = "workflow"
	}
	seen := map[string]bool{}
	var labels []string
	for _, l := range a.Labels {
		if k := labelKey(l.Value); !seen[k] {
			seen[k] = true
			labels = append(labels, k)
		}
	}
	sort.Strings(labels)
	title := "Untitled"
	if a.Title != nil {
		title = *a.Title
	}
	return map[string]string{"agent": string(a.ID), "agent_title": title, "labels": strings.Join(labels, ","),
		"runtime": a.RuntimeID, "started_by": startedBy}
}

// raiseAgentEvent is an event about one agent, in its folder; a writer raises nothing.
func (d *Daemon) raiseAgentEvent(name string, id wire.UUID, sentence string, extra map[string]string) {
	if a := d.Store.Agent(id); a != nil {
		d.raiseAbout(a, name, sentence, extra)
	}
}

// raiseAbout is raiseAgentEvent from a record in hand: one already gone from the store.
func (d *Daemon) raiseAbout(a *wire.Agent, name, sentence string, extra map[string]string) {
	if a.Purpose != nil {
		return
	}
	details := agentDetails(a)
	for k, v := range extra {
		details[k] = v
	}
	var actor *wire.AuditActor
	if personMade(name, details) {
		actor = d.takeActor(a.ID)
	}
	d.raiseAs(wire.EventDraft{Name: name, At: now(), Scope: folderScope(folderPath(a)),
		Sentence: agentName(a.Title) + " " + sentence, Details: details, ChainDepth: d.chainDepth(a)}, actor)
}

// chainDepth is workflowChainDepth: how deep in a chain of workflows anything fired from
// news of this agent would be — its own run's, or the agent that started it.
func (d *Daemon) chainDepth(a *wire.Agent) int64 {
	for seen := map[wire.UUID]bool{}; a != nil && !seen[a.ID]; {
		seen[a.ID] = true
		if a.ChainDepth != nil {
			return *a.ChainDepth
		}
		if a.StartedByAgent == nil {
			return 0
		}
		a = d.Store.Agent(*a.StartedByAgent)
	}
	return 0
}

// agentName is LeaseWords.agentName.
func agentName(title *string) string {
	if title == nil || strings.TrimSpace(*title) == "" {
		return "another agent"
	}
	return "“" + strings.TrimSpace(*title) + "”"
}

// endedSummary is EndedReason.summary.
var endedSummary = map[wire.EndedReason]string{
	wire.EndedReasonMaxTokens: "Ran out of room", wire.EndedReasonMaxTurnRequests: "Hit its limit",
	wire.EndedReasonRefusal: "Refused", wire.EndedReasonCancelled: "Stopped by you",
	wire.EndedReasonProcessDied: "The runtime crashed", wire.EndedReasonDaemonGone: "Stopped with the daemon",
	wire.EndedReasonCostLimit: "Reached its cost limit", wire.EndedReasonUnrecognised: "Stopped for a reason we do not know",
	wire.EndedReasonStoppedByAgent: "Stopped by the agent that started it", wire.EndedReasonSignInRefused: "Its sign-in was refused",
	wire.EndedReasonRuntimeError: "The runtime reported an error", wire.EndedReasonAllowanceSpent: "Its allowance ran out",
	wire.EndedReasonRateLimited: "Rate limited, and still limited after retrying", wire.EndedReasonSandboxFailed: "Its sandbox could not start",
	wire.EndedReasonImported: "Imported from another set-up, so not run here",
	wire.EndedReasonStoppedByAdmin: "Stopped by an admin in the Console",
}

// endedCode is EndedReason.code: allowanceSpent → allowance_spent.
func endedCode(r wire.EndedReason) string {
	var b strings.Builder
	for _, c := range string(r) {
		if c >= 'A' && c <= 'Z' {
			b.WriteByte('_')
			b.WriteRune(c + 'a' - 'A')
		} else {
			b.WriteRune(c)
		}
	}
	return b.String()
}

// raiseAgentEnding is agent.finished, agent.stopped or agent.failed. Stopped is somebody
// or something choosing to stop it; failed is everything that ended it that nobody chose.
func (d *Daemon) raiseAgentEnding(id wire.UUID, next wire.AgentState, why *wire.EndedReason, archiving ...bool) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	if next == wire.AgentStateFinished {
		details := map[string]string{"afterwards": "stay"}
		if len(archiving) > 0 && archiving[0] {
			details["afterwards"] = "archived"
		} else if a.ArchiveRequest != nil && a.ArchiveRequest.Requested != nil {
			details["afterwards"] = "archive_requested"
		}
		sentence := "finished."
		if a.Report != nil {
			details["outcome"] = string(a.Report.Outcome)
			sentence = "finished: " + strings.ToLower(headings[a.Report.Outcome]) + "."
		}
		d.raiseAgentEvent("agent.finished", id, sentence, details)
		return
	}
	if why == nil || *why == wire.EndedReasonCancelled || *why == wire.EndedReasonCostLimit || *why == wire.EndedReasonStoppedByAdmin {
		by := "unknown"
		if why == nil || *why == wire.EndedReasonCancelled {
			by = "you"
		} else if *why == wire.EndedReasonCostLimit {
			by = "cost_limit"
		} else if *why == wire.EndedReasonStoppedByAdmin {
			by = "admin"
		}
		d.raiseAgentEvent("agent.stopped", id, "was stopped.", map[string]string{"by": by})
		return
	}
	words := "stopped"
	if s, ok := endedSummary[*why]; ok {
		words = strings.ToLower(s)
	}
	d.raiseAgentEvent("agent.failed", id, "ended in an error: "+words+".", map[string]string{"reason": endedCode(*why)})
}

// raiseLeaseEvent is lease.granted and lease.released, on the host's log: the event raised,
// or nil.
func (d *Daemon) raiseLeaseEvent(e leaseEvent) *wire.Event {
	l := e.lease
	switch {
	case e.granted:
		title := "Untitled"
		var t *string
		if a := d.Store.Agent(l.Holder); a != nil {
			t = a.Title
			if a.Title != nil {
				title = *a.Title
			}
		}
		raised := d.raise(wire.EventDraft{Name: "lease.granted", At: now(), Scope: macScope(),
			Sentence: agentName(t) + " was given " + l.DisplayName + ".",
			Details:  map[string]string{"resource": string(l.Resource), "agent": string(l.Holder), "agent_title": title}})
		return &raised
	case e.released:
		how, words := "ended", "taken back"
		switch e.ending {
		case "expired":
			how, words = "expired", "let go: its lease ran out"
		case "released":
			how, words = "released", "given back"
		}
		raised := d.raise(wire.EventDraft{Name: "lease.released", At: now(), Scope: macScope(),
			Sentence: l.DisplayName + " was " + words + ".",
			Details:  map[string]string{"resource": string(l.Resource), "how": how}})
		return &raised
	}
	return nil
}

// diskWords is DiskSpace.words: "12.3 GB", "850 MB".
func diskWords(bytes int64) string {
	if bytes >= 1_000_000_000 {
		return fmt.Sprintf("%.1f GB", float64(bytes)/1e9)
	}
	return fmt.Sprintf("%d MB", max(0, bytes)/1_000_000)
}

func freePercent(r wire.DiskReading) int64 {
	if r.TotalBytes <= 0 {
		return 0
	}
	return int64(float64(r.FreeBytes) / float64(r.TotalBytes) * 100)
}

// withNoticed is details with what a look after a restart adds (#1219).
func withNoticed(details, noticed map[string]string) map[string]string {
	for k, v := range noticed {
		details[k] = v
	}
	return details
}

// raiseDiskLow and raiseDiskOK are machine.disk_low and machine.disk_ok.
func (d *Daemon) raiseDiskLow(a wire.DiskAlarm, noticed map[string]string) {
	r := a.Reading
	sentence := r.Volume + " is running low: " + diskWords(r.FreeBytes) + " free."
	if a.Level == wire.DiskLevelCritical {
		sentence = r.Volume + " is almost full: " + diskWords(r.FreeBytes) + " free."
	}
	d.raise(wire.EventDraft{Name: "machine.disk_low", At: now(), Scope: macScope(), Sentence: sentence,
		Details: withNoticed(map[string]string{"volume": r.Volume, "free_bytes": fmt.Sprint(r.FreeBytes), "free_percent": fmt.Sprint(freePercent(r)),
			"level": string(a.Level), "threshold": fmt.Sprint(a.Threshold)}, noticed)})
}

func (d *Daemon) raiseDiskOK(r wire.DiskReading, threshold int64, noticed map[string]string) {
	d.raise(wire.EventDraft{Name: "machine.disk_ok", At: now(), Scope: macScope(),
		Sentence: r.Volume + " has " + diskWords(r.FreeBytes) + " free again.",
		Details: withNoticed(map[string]string{"volume": r.Volume, "free_bytes": fmt.Sprint(r.FreeBytes), "free_percent": fmt.Sprint(freePercent(r)),
			"threshold": fmt.Sprint(threshold)}, noticed)})
}

func (d *Daemon) registerEvents() {
	On(d, wire.CallEventsList, func(ctx context.Context, c *Client, r wire.EventsListRequest) (wire.EventsPage, error) {
		return d.eventsPage(r), nil
	})
	// events/raise: an unreleased build on a scratch root raising an event by hand, so the
	// page can be seen before anything real raises one; never on the ordinary root.
	On(d, wire.CallEventsRaise, func(ctx context.Context, c *Client, r wire.EventRaiseRequest) (wire.Event, error) {
		if !d.RaiseByHand {
			return wire.Event{}, eventRefused("Events are raised by hand only in a debug build, on a scratch root.")
		}
		if p := draftProblem(r.Draft); p != "" {
			return wire.Event{}, eventRefused(p)
		}
		e := d.raiseAs(r.Draft, c.actor)
		for _, c := range r.Consequences {
			d.addConsequence(c, e.Position)
		}
		if got := d.event(e.Position); got != nil {
			return *got, nil
		}
		return e, nil
	})
	// events/server: a server gone or back, as the window that holds its connection saw it.
	On(d, wire.CallEventsServer, func(ctx context.Context, c *Client, r wire.ServerReachabilityChange) (wire.Event, error) {
		server := strings.TrimSpace(r.Server)
		if c.conn.Device() != "" {
			return wire.Event{}, eventRefused("Only the Mac's window says how its servers are.")
		}
		if server == "" {
			return wire.Event{}, eventRefused("A server change needs the server's name.")
		}
		name, sentence := "server.offline", server+" went offline."
		if r.Online {
			name, sentence = "server.online", server+" came back."
		}
		return d.raiseAs(wire.EventDraft{Name: name, At: now(), Scope: macScope(), Sentence: sentence,
			Details: map[string]string{"server": server}}, c.actor), nil
	})
}
