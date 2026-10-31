package agentsd

import (
	"encoding/json"
	"slices"
	"strings"
	"unicode"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The finished turns, as the chat shows them until one is opened (agents/turns): what was
// asked, how it went and how many steps it took, made as TurnSummary.of makes them from the
// transcript as TranscriptEntry.display draws it. Where they start and how they are kept
// is turnscache.go.

const turnsLimitCeiling = 200

// turnSummaryOf is TurnSummary.of.
func turnSummaryOf(entries []wire.TranscriptEntry, start int64) wire.TurnSummary {
	var ask *wire.TranscriptEntry
	if len(entries) > 0 && isPersonsAsk(&entries[0]) {
		a := entries[0]
		ask = &a
	}
	items := display(entries)
	s := wire.TurnSummary{Start: start, End: start + int64(len(entries)), Ask: ask,
		Outcome: []wire.TranscriptEntry{}}
	switch {
	case ask != nil:
		s.ID = ask.ID
	case len(entries) > 0:
		s.ID = entries[0].ID
	default:
		s.ID = store.NewUUID()
	}
	rest := items
	if ask != nil && len(rest) > 0 {
		rest = rest[1:]
	}
	outcome, steps := turnParts(rest)
	for _, it := range outcome {
		s.Outcome = append(s.Outcome, it.concise())
	}
	s.Steps = &steps
	s.Usage = totalUsage(entries)
	return s
}

// MARK: the items a transcript is drawn as (TranscriptItem)

// item is an entry, or a run of tool calls drawn as one line.
type item struct {
	entry *wire.TranscriptEntry
	runID wire.UUID
	runAt wire.Date
	calls []wire.ToolCall
}

func (it item) isRun() bool { return it.entry == nil }

func (it item) kind() *wire.TranscriptEntryKind {
	if it.entry == nil {
		return &wire.TranscriptEntryKind{}
	}
	return &it.entry.Kind
}

func isPersonsAsk(e *wire.TranscriptEntry) bool {
	// Another agent's message starts a turn as the person's prompt does (#560); the app's
	// own question does not.
	u := e.Kind.UserMessage
	return u != nil && (u.From == nil || *u.From != wire.PromptOriginApp)
}

func (it item) isAgentMessage() bool { return it.kind().AgentMessage != nil }
func (it item) isThought() bool      { return it.kind().AgentThought != nil }
func (it item) isReport() bool       { return it.kind().WorkReported != nil }

// isBranch is the note that says where a branch was cut (#1749).
func (it item) isBranch() bool {
	n := it.kind().RuntimeNote
	return n != nil && strings.HasPrefix(n.Value, "Branched from ")
}

func (it item) isOutcome() bool {
	k := it.kind()
	switch {
	case it.isRun():
		return false
	case k.ElicitationAnswered != nil, k.WorkReported != nil, k.SandboxFailure != nil, k.AppView != nil, k.FileShown != nil, k.Notified != nil:
		return true
	case k.StateChanged != nil:
		return k.StateChanged.Value == wire.AgentStateStopped
	case k.Notice != nil:
		return k.Notice.Value.Severity == "error"
	case k.RuntimeNote != nil:
		// Where a branch was cut (#1749): drawn at every level, after the reply it keeps.
		return it.isBranch()
	}
	return false
}

func (it item) isInTurn() bool {
	if k := it.kind(); k.StateChanged != nil {
		return k.StateChanged.Value == wire.AgentStateStopped
	}
	return true
}

func (it item) isPassing() bool { return it.entry != nil && entryIsPassing(it.entry) }

func (it item) isDrawn() bool { return it.entry == nil || !isUnrecognised(&it.entry.Kind) }

func isUnrecognised(k *wire.TranscriptEntryKind) bool { return k.Unrecognised != nil }

// concise is the item as a summary keeps it: a run as its last call, without its output.
func (it item) concise() wire.TranscriptEntry {
	if it.entry != nil {
		return *it.entry
	}
	call := it.calls[len(it.calls)-1]
	said := describedAs(call)
	call.Content, call.Locations, call.RawInput, call.RawOutput, call.Raw = []wire.ToolCallContent{}, []wire.ToolCallLocation{}, nil, nil, nil
	if s := said; s != "" {
		call.RawInput, _ = json.Marshal(map[string]string{"description": s})
	}
	return wire.TranscriptEntry{ID: it.runID, At: it.runAt, Kind: wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{Value: call}}}
}

func describedAs(c wire.ToolCall) string {
	var in struct {
		Description string `json:"description"`
	}
	if len(c.RawInput) == 0 || json.Unmarshal(c.RawInput, &in) != nil {
		return ""
	}
	return strings.TrimSpace(in.Description)
}

func entryIsPassing(e *wire.TranscriptEntry) bool {
	k := e.Kind
	switch {
	case k.StateChanged != nil:
		s := k.StateChanged
		return s.Value == wire.AgentStateStarting || s.Value == wire.AgentStateRunning ||
			s.Value == wire.AgentStateStopped && s.Reason != nil && *s.Reason == wire.EndedReasonDaemonGone
	case k.RuntimeNote != nil:
		t := k.RuntimeNote.Value
		if t == "Picked the conversation back up." || t == "This agent was working when the daemon stopped, so it stopped too." {
			return true
		}
		return strings.HasPrefix(t, "Starting ") && strings.HasSuffix(t, "…") && len([]rune(t)) > len("Starting ")+1
	}
	return false
}

func carriesOn(k *wire.TranscriptEntryKind) bool {
	return k.AgentMessage != nil || k.AgentThought != nil || k.ToolCall != nil || k.ToolCallUpdate != nil ||
		k.AppView != nil || k.FileShown != nil || k.Notified != nil || k.PlanUpdated != nil || k.PermissionAsked != nil || k.ElicitationAsked != nil
}

func endsTheWork(k *wire.TranscriptEntryKind) bool {
	if k.UserMessage != nil {
		return true
	}
	if s := k.StateChanged; s != nil {
		return s.Value != wire.AgentStateStarting && s.Value != wire.AgentStateRunning
	}
	return false
}

// turnParts is TurnParts for a finished turn: the outcome and the count of steps.
func turnParts(items []item) ([]item, int64) {
	var shown []item
	for _, it := range items {
		if it.isInTurn() && !it.isPassing() && !it.isThought() {
			shown = append(shown, it)
		}
	}
	reply := map[int]bool{}
	for k := len(shown) - 1; k >= 0; k-- {
		if shown[k].isAgentMessage() {
			reply[k] = true
		} else if !shown[k].isOutcome() {
			break
		}
	}
	if len(reply) == 0 {
		for k := len(shown) - 1; k >= 0; k-- {
			if shown[k].isAgentMessage() {
				reply[k] = true
				break
			}
		}
	}
	var outcome, reports []item
	var steps int64
	for k, it := range shown {
		switch {
		case it.isReport(), it.isBranch():
			reports = append(reports, it)
		case reply[k] || it.isOutcome():
			outcome = append(outcome, it)
		case it.isRun():
			steps += int64(len(it.calls))
		default:
			steps++
		}
	}
	// The report is the turn's last line, whatever the agent said after it, and where a
	// branch was cut comes after that (#1749).
	return append(outcome, reports...), steps
}

// totalUsage is TurnUsage.total: every usage report added up, nil for none.
func totalUsage(entries []wire.TranscriptEntry) *wire.TurnUsage {
	var total *wire.TurnUsage
	add := func(a, b *int64) *int64 {
		if a == nil && b == nil {
			return nil
		}
		var n int64
		if a != nil {
			n += *a
		}
		if b != nil {
			n += *b
		}
		return &n
	}
	for _, e := range entries {
		u := e.Kind.UsageRecorded
		if u == nil {
			continue
		}
		if total == nil {
			v := u.Value
			if v.Cost != nil {
				c := *v.Cost
				v.Cost = &c
			}
			total = &v
			continue
		}
		v := u.Value
		total.TotalTokens += v.TotalTokens
		total.InputTokens += v.InputTokens
		total.OutputTokens += v.OutputTokens
		total.ThoughtTokens = add(total.ThoughtTokens, v.ThoughtTokens)
		total.CachedReadTokens = add(total.CachedReadTokens, v.CachedReadTokens)
		total.CachedWriteTokens = add(total.CachedWriteTokens, v.CachedWriteTokens)
		if v.Cost != nil {
			if total.Cost == nil {
				c := *v.Cost
				total.Cost = &c
			} else if total.Cost.Currency == v.Cost.Currency {
				total.Cost.Amount += v.Cost.Amount
			}
		}
	}
	return total
}

// MARK: TranscriptDisplayBuilder

// display is TranscriptEntry.display, for the agent's own entries (no subagent's).
func display(entries []wire.TranscriptEntry) []item {
	b := &displayBuilder{suppressed: map[string]bool{}, closedRunAt: map[string]int{}, viewAt: map[wire.UUID]int{}, noticeAt: map[wire.UUID]int{}}
	for i := range entries {
		b.add(entries[i])
	}
	return b.items()
}

type displayBuilder struct {
	drawn       []item
	run         []wire.ToolCall
	runID       *wire.UUID
	runAt       wire.Date
	suppressed  map[string]bool
	closedRunAt map[string]int
	viewAt      map[wire.UUID]int
	last        *wire.TranscriptEntry
	settled     int
	// noticeAt is where each notice's line is (#2860): where it went is said on it.
	noticeAt map[wire.UUID]int
}

func (b *displayBuilder) add(e wire.TranscriptEntry) {
	// Before anything else, including the join: a subagent's chunk arriving between two
	// of the agent's is not part of either message.
	if e.SubagentID != nil {
		return
	}
	if joined := joinEntry(e, b.last); joined != nil {
		b.last = joined
		if len(b.drawn) > 0 {
			b.drawn[len(b.drawn)-1] = item{entry: joined}
		}
		return
	}
	b.last = &e
	k := &e.Kind
	switch {
	case k.ToolCall != nil || k.ToolCallUpdate != nil:
		var call wire.ToolCall
		if k.ToolCall != nil {
			call = k.ToolCall.Value
		} else {
			call = k.ToolCallUpdate.Value
		}
		update := k.ToolCallUpdate != nil
		called := call.Title
		if call.Name != nil {
			called = *call.Name
		}
		// The app's own end-of-turn call is not drawn, by its name or the two it had.
		if strings.HasSuffix(called, "finish_turn") || strings.HasSuffix(called, "suggest_next_prompts") || strings.HasSuffix(called, "report_outcome") {
			if call.ToolCallID != nil {
				b.suppressed[*call.ToolCallID] = true
			}
			return
		}
		if call.ToolCallID != nil && b.suppressed[*call.ToolCallID] {
			return
		}
		existing := -1
		if call.ToolCallID != nil {
			existing = slices.IndexFunc(b.run, func(c wire.ToolCall) bool { return c.ToolCallID != nil && *c.ToolCallID == *call.ToolCallID })
		}
		switch {
		case existing >= 0:
			b.run[existing] = mergeCall(call, b.run[existing])
		case update && call.ToolCallID != nil && b.mergeIntoClosedRun(call, *call.ToolCallID):
			return
		case update && saysNothing(call):
			return
		default:
			b.run = append(b.run, call)
		}
		if b.runID == nil {
			id := e.ID
			b.runID, b.runAt = &id, e.At
		}
		b.resolveIntermittentErrors()
	case k.AppView != nil:
		id := k.AppView.Value.ID
		if at, ok := b.viewAt[id]; ok && at < len(b.drawn) && b.drawn[at].entry != nil {
			first := *b.drawn[at].entry
			first.Kind = wire.TranscriptEntryKind{AppView: k.AppView}
			b.drawn[at] = item{entry: &first}
			return
		}
		b.closeRun()
		b.resolveIntermittentErrors()
		b.viewAt[id] = len(b.drawn)
		b.drawn = append(b.drawn, item{entry: &e})
	case k.FileShown != nil, k.Notified != nil:
		// The card stands on its own, after the run that called it (#836); so does what
		// the agent told the person (#2805).
		b.closeRun()
		b.resolveIntermittentErrors()
		if k.Notified != nil {
			b.noticeAt[e.ID] = len(b.drawn)
		}
		b.drawn = append(b.drawn, item{entry: &e})
	case k.NoticeDelivered != nil:
		// Said on the notice's line (#2860), never a line of its own.
		if at, ok := b.noticeAt[k.NoticeDelivered.Value.Notice]; ok && at < len(b.drawn) && b.drawn[at].entry != nil {
			line := *b.drawn[at].entry
			if line.Kind.Notified != nil {
				notice := line.Kind.Notified.Value
				to := k.NoticeDelivered.Value.To
				notice.To = &to
				line.Kind = wire.TranscriptEntryKind{Notified: &wire.TranscriptEntryKindNotified{Value: notice}}
				b.drawn[at] = item{entry: &line}
			}
		}
	case k.Compaction != nil:
		if at := b.compactionAt(k.Compaction.ID); at >= 0 {
			if merged := mergeCompaction(e, *b.drawn[at].entry); merged != nil {
				b.drawn[at] = item{entry: merged}
				return
			}
		}
		b.closeRun()
		b.drawn = append(b.drawn, item{entry: &e})
	case k.Background != nil && (k.Background.Value.State == wire.BackgroundItemStateRunning || k.Background.Value.State == wire.BackgroundItemStatePaused) &&
		k.Background.Value.Kind == wire.BackgroundItemKindTask && k.Background.Value.ToolCallID != nil:
		// A task starting from a tool call: the call is already on the page (057).
		return
	case k.OptionChanged != nil:
		// Plumbing, not conversation, and not a break in a run of tool calls either.
		return
	case k.ServedRequest != nil && k.ServedRequest.Value.Kind.ReadFile != nil && k.ServedRequest.Value.Outcome.Served != nil:
		// A read the app served: on the record, not on the page.
		return
	case k.StateChanged != nil && k.StateChanged.Value == wire.AgentStateFinished, k.UsageRecorded != nil:
		// The turn ending, and what it cost: neither drawn, but each ends the run.
		b.closeRun()
		b.supersedePassingLines()
		if k.StateChanged != nil {
			b.settleIntermittentErrors()
		}
	default:
		b.closeRun()
		if carriesOn(k) {
			b.resolveIntermittentErrors()
		} else if endsTheWork(k) {
			b.settleIntermittentErrors()
		}
		b.drawn = append(b.drawn, item{entry: &e})
	}
}

func (b *displayBuilder) supersedePassingLines() {
	for len(b.drawn) > 0 && b.drawn[len(b.drawn)-1].isPassing() {
		b.drawn = b.drawn[:len(b.drawn)-1]
	}
	b.settled = min(b.settled, len(b.drawn))
}

func (b *displayBuilder) settleIntermittentErrors() {
	leaveOutErrorsPassedInMessage(b.drawn, b.settled)
	b.settled = len(b.drawn)
}

func leaveOutErrorsPassedInMessage(all []item, from int) {
	for i := from; i < len(all); i++ {
		m := all[i].kind().AgentMessage
		if all[i].entry == nil || m == nil || len(m.Blocks) > 0 {
			continue
		}
		if rest, ok := withoutIntermittentErrors(m.Text, false); ok {
			all[i] = item{entry: withMessageText(all[i].entry, rest)}
		}
	}
}

func (b *displayBuilder) resolveIntermittentErrors() {
	for i := len(b.drawn) - 1; i >= b.settled; i-- {
		m := b.drawn[i].kind().AgentMessage
		if b.drawn[i].entry == nil || m == nil || len(m.Blocks) > 0 {
			continue
		}
		rest, ok := withoutIntermittentErrors(m.Text, true)
		if !ok {
			continue
		}
		if rest == "" {
			b.drawn = slices.Delete(b.drawn, i, i+1)
		} else {
			b.drawn[i] = item{entry: withMessageText(b.drawn[i].entry, rest)}
		}
	}
}

func withMessageText(e *wire.TranscriptEntry, text string) *wire.TranscriptEntry {
	c := *e
	m := *e.Kind.AgentMessage
	m.Text = text
	c.Kind = wire.TranscriptEntryKind{AgentMessage: &m}
	return &c
}

func (b *displayBuilder) compactionAt(id *string) int {
	if id != nil {
		for i := len(b.drawn) - 1; i >= 0; i-- {
			if c := b.drawn[i].kind().Compaction; b.drawn[i].entry != nil && c != nil && c.ID != nil && *c.ID == *id {
				return i
			}
		}
		return -1
	}
	if n := len(b.drawn); len(b.run) == 0 && n > 0 {
		if c := b.drawn[n-1].kind().Compaction; b.drawn[n-1].entry != nil && c != nil && c.Status == "in_progress" {
			return n - 1
		}
	}
	return -1
}

func (b *displayBuilder) mergeIntoClosedRun(update wire.ToolCall, id string) bool {
	at, ok := b.closedRunAt[id]
	if !ok || at >= len(b.drawn) || !b.drawn[at].isRun() {
		return false
	}
	calls := slices.Clone(b.drawn[at].calls)
	i := slices.IndexFunc(calls, func(c wire.ToolCall) bool { return c.ToolCallID != nil && *c.ToolCallID == id })
	if i < 0 {
		return false
	}
	calls[i] = mergeCall(update, calls[i])
	b.drawn[at].calls = calls
	return true
}

func (b *displayBuilder) closeRun() {
	if len(b.run) == 0 || b.runID == nil {
		return
	}
	// Only lines after a run are ever taken back off drawn, so its place holds.
	for _, c := range b.run {
		if c.ToolCallID != nil {
			b.closedRunAt[*c.ToolCallID] = len(b.drawn)
		}
	}
	b.drawn = append(b.drawn, item{runID: *b.runID, runAt: b.runAt, calls: b.run})
	b.run, b.runID = nil, nil
}

func (b *displayBuilder) items() []item {
	all := slices.Clone(b.drawn)
	leaveOutErrorsPassedInMessage(all, b.settled)
	if len(b.run) > 0 && b.runID != nil {
		all = append(all, item{runID: *b.runID, runAt: b.runAt, calls: b.run})
	}
	// withoutSupersededPassingLines: only the latest drawn line may be a passing one.
	latest := -1
	for i := len(all) - 1; i >= 0; i-- {
		if all[i].isDrawn() {
			latest = i
			break
		}
	}
	if latest < 0 {
		return all
	}
	var out []item
	for i, it := range all {
		if it.isPassing() && i != latest {
			continue
		}
		out = append(out, it)
	}
	return out
}

// joinEntry is TranscriptEntry.join: a chunk that continues the message or thought before
// it, as one.
func joinEntry(e wire.TranscriptEntry, previous *wire.TranscriptEntry) *wire.TranscriptEntry {
	if previous == nil {
		return nil
	}
	same := func(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
	p, n := previous.Kind, e.Kind
	switch {
	case p.AgentMessage != nil && n.AgentMessage != nil && same(p.AgentMessage.MessageID, n.AgentMessage.MessageID):
		j := *previous
		m := *p.AgentMessage
		m.Text += n.AgentMessage.Text
		m.Blocks = append(slices.Clone(m.Blocks), n.AgentMessage.Blocks...)
		j.Kind = wire.TranscriptEntryKind{AgentMessage: &m}
		return &j
	case p.AgentThought != nil && n.AgentThought != nil && same(p.AgentThought.MessageID, n.AgentThought.MessageID):
		j := *previous
		t := *p.AgentThought
		t.Text += n.AgentThought.Text
		j.Kind = wire.TranscriptEntryKind{AgentThought: &t}
		return &j
	}
	return nil
}

// mergeCompaction is TranscriptEntry.mergeCompaction.
func mergeCompaction(e, earlier wire.TranscriptEntry) *wire.TranscriptEntry {
	c, n := earlier.Kind.Compaction, e.Kind.Compaction
	if c == nil || n == nil {
		return nil
	}
	m := *c
	if m.ID == nil {
		m.ID = n.ID
	}
	if n.Status == "in_progress" {
		m.Summary = append(slices.Clone(c.Summary), n.Summary...)
	} else {
		m.Status = n.Status
		if len(n.Summary) > 0 {
			m.Summary = n.Summary
		}
		if n.Error != nil {
			m.Error = n.Error
		}
	}
	merged := earlier
	merged.Kind = wire.TranscriptEntryKind{Compaction: &m}
	return &merged
}

// mergeCall is TranscriptEntry.merge: an update to a call, onto the call as it stood.
func mergeCall(update, existing wire.ToolCall) wire.ToolCall {
	m := existing
	if update.Title != "" && update.Title != "Tool call" {
		m.Title = update.Title
	}
	if update.Name != nil {
		m.Name = update.Name
	}
	if update.Kind != nil {
		m.Kind = update.Kind
	}
	if update.Status != nil {
		m.Status = update.Status
	}
	if len(update.Content) > 0 {
		m.Content = append(slices.Clone(existing.Content), update.Content...)
	}
	if len(update.Locations) > 0 {
		m.Locations = update.Locations
	}
	if update.RawInput != nil {
		m.RawInput = update.RawInput
	}
	if update.RawOutput != nil {
		m.RawOutput = update.RawOutput
	}
	if update.Raw != nil {
		m.Raw = update.Raw
	}
	return m
}

func saysNothing(c wire.ToolCall) bool {
	return (c.Title == "" || c.Title == "Tool call") && c.Name == nil && c.Kind == nil && c.Status == nil &&
		len(c.Content) == 0 && len(c.Locations) == 0 && c.RawInput == nil && c.RawOutput == nil
}

// MARK: IntermittentError

const intermittentMarker = "RetriableError"

func isIntermittentLine(line string) bool {
	t := strings.TrimLeftFunc(line, unicode.IsSpace)
	return strings.HasPrefix(t, "Error: "+intermittentMarker) || strings.HasPrefix(t, intermittentMarker)
}

// withoutIntermittentErrors is IntermittentError.without: the text with its retried
// errors left out (with all false, only those something said follows), and whether any
// were.
func withoutIntermittentErrors(text string, all bool) (string, bool) {
	if !strings.Contains(text, intermittentMarker) {
		return "", false
	}
	lines := strings.Split(text, "\n")
	var kept []string
	dropped, followed := false, false
	for i := len(lines) - 1; i >= 0; i-- {
		line := lines[i]
		if isIntermittentLine(line) && (all || followed) {
			dropped = true
			continue
		}
		if !isIntermittentLine(line) && strings.TrimFunc(line, unicode.IsSpace) != "" {
			followed = true
		}
		kept = append(kept, line)
	}
	if !dropped {
		return "", false
	}
	slices.Reverse(kept)
	result := strings.Join(kept, "\n")
	for strings.Contains(result, "\n\n\n") {
		result = strings.ReplaceAll(result, "\n\n\n", "\n\n")
	}
	return strings.Trim(result, "\n\r"), true
}
