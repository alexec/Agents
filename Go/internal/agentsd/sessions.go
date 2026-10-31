package agentsd

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// list_sessions, read_session and message_session, as DaemonCore+Sessions and +Messages
// answer them on the Swift host, in SessionLookup's and SessionHistory's words: any agent
// may read and message any session in its own folder.

const (
	sessionPageSize    = 30
	sessionLargestPage = 100
	historyBudget      = 80_000
	historyBytes       = 1 << 20
	messageCharacters  = 4_000
	messagesPerHour    = 30
	defaultRunningCap  = 3
	sessionUnavailable = "That conversation's history is unavailable."
	queuedMessageNote  = " It is queued, and it is the one message you may have waiting for that session. Replace it with message_session and replace: true, or take it back with cancel_message."
)

type messageState struct {
	messageMu    sync.Mutex
	messagesSent map[wire.UUID][]time.Time
}

var groupTitles = map[string]string{"needsAttention": "Needs you", "blocked": "Blocked", "waiting": "Waiting",
	"running": "Working", "finished": "Done", "stopped": "Paused", "archived": "Archived"}

// sessionStatus is SessionLookup.status: the group, and for a stopped one why.
func sessionStatus(a *wire.Agent) string {
	g := groupTitles[Group(a)]
	if a.State == wire.AgentStateStopped && a.EndedReason != nil {
		if why, ok := endedSummary[*a.EndedReason]; ok {
			return g + ": " + why
		}
	}
	return g
}

func runtimeName(id string) string {
	if id == autoRuntimeID {
		return "Auto"
	}
	if rt := runtimeByID(id); rt != nil && rt.Name != "" {
		return rt.Name
	}
	return id
}

// isoWhen is Date.formatted(.iso8601): to the second, in UTC.
func isoWhen(d wire.Date) string { return d.Time().UTC().Format("2006-01-02T15:04:05Z") }

// folderSessions is SessionLookup.sessions: the folder's, most recent first.
func (d *Daemon) folderSessions(folder string) []wire.Agent {
	var out []wire.Agent
	for _, a := range d.Store.Agents() {
		if folderPath(&a) == folder {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func quoted(title *string) string {
	if title == nil {
		return "Untitled"
	}
	return "“" + *title + "”"
}

// findSession is SessionLookup.find: by id, or by exact title when only one has it.
func (d *Daemon) findSession(value, folder string) (*wire.Agent, string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, "Give a session id or exact title."
	}
	live := d.folderSessions(folder)
	for i := range live {
		if strings.EqualFold(string(live[i].ID), value) && isUUID(value) {
			return &live[i], ""
		}
	}
	var titled []wire.Agent
	for _, a := range live {
		if a.Title != nil && *a.Title == value {
			titled = append(titled, a)
		}
	}
	switch {
	case len(titled) == 1:
		return &titled[0], ""
	case len(titled) > 1:
		var matches []string
		for _, a := range titled {
			matches = append(matches, string(a.ID)+" — "+runtimeName(a.RuntimeID)+", "+sessionStatus(&a)+", "+isoWhen(a.LastActivityAt))
		}
		return nil, "More than one session is named “" + value + "”: " + strings.Join(matches, "; ") + ". Read one by id."
	}
	return nil, "There is no session named “" + value + "” in this folder."
}

func labelsLine(a *wire.Agent) string {
	if len(a.Labels) == 0 {
		return ""
	}
	var each []string
	for _, l := range a.Labels {
		each = append(each, l.Value+" ("+string(l.Owner)+")")
	}
	return " Labels: " + strings.Join(each, ", ") + "."
}

// listSessions is list_sessions: not archived first, most recent first, a page at a time.
func (d *Daemon) listSessions(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was read."}
	}
	if strings.EqualFold(strings.TrimSpace(argString(args, "started_by")), "me") {
		return d.listHelpers(me), nil
	}
	size := sessionPageSize
	if n, ok := argInt(args, "limit"); ok {
		size = n
	}
	size = min(max(1, size), sessionLargestPage)
	after := strings.TrimSpace(argString(args, "after"))
	folder := folderPath(me)
	sorted := d.folderSessions(folder)
	if len(sorted) == 0 {
		return "There are no sessions in this folder.", nil
	}
	var all []wire.Agent
	for _, a := range sorted {
		if a.State != wire.AgentStateArchived {
			all = append(all, a)
		}
	}
	for _, a := range sorted {
		if a.State == wire.AgentStateArchived {
			all = append(all, a)
		}
	}
	from := 0
	if after != "" {
		at := -1
		for i, a := range all {
			if string(a.ID) == strings.ToUpper(after) {
				at = i
			}
		}
		if at < 0 {
			return "No session in this folder has the id “" + after + "” any more. Call list_sessions without `after` to start again.", nil
		}
		from = at + 1
	}
	end := min(from+size, len(all))
	page := all[from:end]
	if len(page) == 0 {
		return "There are no more sessions in this folder.", nil
	}
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	holding := map[wire.UUID][]string{}
	for name, e := range d.book.Entries {
		for _, l := range e.Leases {
			holding[l.Holder] = append(holding[l.Holder], string(name))
		}
	}
	d.leaseMu.Unlock()
	d.settle(loaded)
	lines := []string{"Sessions in this folder, not archived first, most recent first. Read one with read_session, by id or exact title."}
	for _, a := range page {
		name := quoted(a.Title)
		if a.ID == caller {
			name += " (you)"
		}
		line := "- " + string(a.ID) + ": " + name + " — " + runtimeName(a.RuntimeID) + ", " + sessionStatus(&a) + ", last active " + isoWhen(a.LastActivityAt) + "."
		if w := a.Worktree; w != nil {
			line += " Worktree: " + store.FolderPath(w.Root)
			if w.Branch != nil {
				line += " on " + *w.Branch
			}
			line += "."
		}
		if held := holding[a.ID]; len(held) > 0 {
			sort.Strings(held)
			line += " Holding: " + strings.Join(held, ", ") + "."
		}
		if a.Report != nil {
			line += " Last said: " + a.Report.Message
		}
		lines = append(lines, line+labelsLine(&a)+waitingLine(&a, caller))
	}
	text := strings.Join(lines, "\n")
	if rest := all[end:]; len(rest) > 0 {
		archived := 0
		for _, a := range rest {
			if a.State == wire.AgentStateArchived {
				archived++
			}
		}
		more := fmt.Sprintf("\n\n%d more", len(rest))
		switch {
		case archived == len(rest):
			more += ", all archived"
		case archived > 0:
			more += fmt.Sprintf(", %d of them archived", archived)
		}
		text += more + ". For the next page, call list_sessions with after: \"" + string(page[len(page)-1].ID) + "\"."
	}
	return text, nil
}

// historyPiece is a line, a reply, or a tool call of one turn.
type historyPiece struct {
	line  string
	reply *wire.TranscriptEntryKindAgentMessage
	tool  *wire.ToolCall
}

// historyBuilder is SessionHistory.Builder: the first turn and as many of the latest as fit.
type historyBuilder struct {
	runtime    string
	first      *string
	current    []historyPiece
	replyOpen  bool
	suppressed map[string]bool
	kept       []string
	keptSize   int
	dropped    int
	plan       *wire.Plan
}

func isTheAppsTool(tc wire.ToolCall) bool {
	for _, n := range []string{tc.Title, deref(tc.Name)} {
		for _, p := range []string{"mcp__agents__", "agents_", "agents-", "agents/"} {
			if strings.HasPrefix(n, p) {
				return true
			}
		}
	}
	return false
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func (b *historyBuilder) add(e wire.TranscriptEntry) {
	if e.SubagentID != nil {
		return
	}
	k := e.Kind
	if b.replyOpen && k.AgentMessage != nil && len(b.current) > 0 {
		if last := b.current[len(b.current)-1].reply; last != nil && deref(last.MessageID) == deref(k.AgentMessage.MessageID) {
			joined := *last
			joined.Text += k.AgentMessage.Text
			b.current[len(b.current)-1].reply = &joined
			return
		}
	}
	b.replyOpen = false
	switch {
	case k.UserMessage != nil:
		b.close()
		who := "The person"
		if k.UserMessage.From != nil {
			switch *k.UserMessage.From {
			case wire.PromptOriginApp:
				who = "The app"
			case wire.PromptOriginAgent:
				name := "Another agent"
				if e.Sender != nil {
					name = e.Sender.Title
				}
				who = "“" + name + "”"
			}
		}
		b.current = []historyPiece{{line: "**" + who + ":** " + k.UserMessage.Value}}
	case k.AgentMessage != nil:
		m := *k.AgentMessage
		b.current = append(b.current, historyPiece{reply: &m})
		b.replyOpen = true
	case k.ToolCall != nil || k.ToolCallUpdate != nil:
		var call wire.ToolCall
		if k.ToolCall != nil {
			call = k.ToolCall.Value
		} else {
			call = k.ToolCallUpdate.Value
		}
		id := deref(call.ToolCallID)
		if id != "" && b.suppressed[id] {
			return
		}
		if isTheAppsTool(call) {
			if id != "" {
				b.suppressed[id] = true
			}
			return
		}
		for i := len(b.current) - 1; i >= 0 && id != ""; i-- {
			if t := b.current[i].tool; t != nil && deref(t.ToolCallID) == id {
				merged := *t
				if call.Title != "" {
					merged.Title = call.Title
				}
				if call.Status != nil {
					merged.Status = call.Status
				}
				if len(call.Locations) > 0 {
					merged.Locations = call.Locations
				}
				if call.RawInput != nil {
					merged.RawInput = call.RawInput
				}
				b.current[i].tool = &merged
				return
			}
		}
		if k.ToolCall != nil {
			b.current = append(b.current, historyPiece{tool: &call})
		}
	case k.WorkReported != nil:
		r := k.WorkReported.Value
		b.current = append(b.current, historyPiece{line: "*Said how the work went: " + string(r.Outcome) + ". " + r.Message + "*"})
	case k.PlanUpdated != nil:
		p := k.PlanUpdated.Value
		if p.State == wire.PlanStateCurrent {
			b.plan = &p
		} else {
			b.plan = nil
		}
	}
}

func (b *historyBuilder) render(p historyPiece) string {
	switch {
	case p.reply != nil:
		if p.reply.Text == "" {
			return ""
		}
		return "**" + b.runtime + ":** " + p.reply.Text
	case p.tool != nil:
		s := "- " + line(*p.tool)
		if len(p.tool.Locations) > 0 {
			s += " (`" + p.tool.Locations[0].Path + "`)"
		}
		return s
	}
	return p.line
}

func (b *historyBuilder) close() {
	var lines []string
	for _, p := range b.current {
		if s := b.render(p); s != "" {
			lines = append(lines, s)
		}
	}
	b.current = nil
	if len(lines) == 0 {
		return
	}
	turn := strings.Join(lines, "\n")
	if b.first == nil {
		b.first = &turn
		return
	}
	b.kept = append(b.kept, turn)
	b.keptSize += len([]rune(turn)) + 2
	for b.keptSize > historyBudget && len(b.kept) > 0 {
		b.keptSize -= len([]rune(b.kept[0])) + 2
		b.kept = b.kept[1:]
		b.dropped++
	}
}

func (b *historyBuilder) document(header string) string {
	b.replyOpen = false
	b.close()
	if b.first == nil {
		return header + "Nothing has been said in this session yet.\n"
	}
	planText := ""
	if b.plan != nil && len(b.plan.Entries) > 0 {
		var ps []string
		for _, e := range b.plan.Entries {
			mark := " "
			if e.Status == wire.PlanEntryStatusCompleted {
				mark = "x"
			}
			ps = append(ps, "- ["+mark+"] "+e.Content)
		}
		planText = "\n## The plan, as it last stood\n\n" + strings.Join(ps, "\n") + "\n"
	}
	assemble := func(latest []string, leftOut int) string {
		parts := []string{*b.first}
		if leftOut > 0 {
			parts = append(parts, fmt.Sprintf("*%d turns in the middle were left out to fit.*", leftOut))
		}
		parts = append(parts, latest...)
		return header + "## The conversation\n\n" + strings.Join(parts, "\n\n") + "\n" + planText
	}
	latest, leftOut := b.kept, b.dropped
	text := assemble(latest, leftOut)
	for len([]rune(text)) > historyBudget && len(latest) > 0 {
		latest = latest[1:]
		leftOut++
		text = assemble(latest, leftOut)
	}
	return text
}

func historyHeader(a *wire.Agent, caller wire.UUID) string {
	lines := []string{"# Session " + quoted(a.Title), "", "- Id: " + string(a.ID), "- Runtime: " + runtimeName(a.RuntimeID),
		"- Status: " + sessionStatus(a), "- Working folder: `" + store.FolderPath(a.Cwd) + "`"}
	if w := a.Worktree; w != nil {
		l := "- Worktree: " + w.Name
		if w.Branch != nil {
			l += ", on branch `" + *w.Branch + "`"
		}
		lines = append(lines, l)
	}
	if note := waitingNote(a, caller); note != "" {
		lines = append(lines, "- Your message waits: "+note)
	}
	lines = append(lines, "", "This is the app's record of that session: what was asked, what was said, the tools that ran and the plan. "+
		"Reading it did not change it. The files are as that session left them.", "", "")
	return strings.Join(lines, "\n")
}

// readSession is read_session: the history, or the sentence saying why not.
func (d *Daemon) readSession(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was read."}
	}
	a, refused := d.findSession(argString(args, "session"), folderPath(me))
	if a == nil {
		// One it started on another machine (#2927).
		if s := d.thereNamed(caller, argString(args, "session")); s != nil {
			return d.thereOp(caller, s, "read")
		}
		return refused, nil
	}
	entries, _, err := d.Store.Transcript(a.ID, 0)
	if err != nil {
		return sessionUnavailable, nil
	}
	return history(a, entries, historyHeader(a, caller)), nil
}

// history is a session's record as read_session gives it, under header.
func history(a *wire.Agent, entries []wire.TranscriptEntry, header string) string {
	// The first turn whole, then from the end back at most historyBytes of the rest
	// (HistoryLines), so a long session is not read whole.
	firstEnd := len(entries)
	for i := 1; i < len(entries); i++ {
		if entries[i].Kind.UserMessage != nil {
			firstEnd = i
			break
		}
	}
	start, size := len(entries), 0
	for start > firstEnd {
		b, _ := json.Marshal(entries[start-1])
		if size+len(b) > historyBytes {
			break
		}
		size += len(b)
		start--
	}
	// Back to the start of a turn, so none is read from its middle.
	for start < len(entries) && start > firstEnd && entries[start].Kind.UserMessage == nil {
		start++
	}
	b := historyBuilder{runtime: runtimeName(a.RuntimeID), suppressed: map[string]bool{}}
	for _, e := range entries[:firstEnd] {
		b.add(e)
	}
	b.replyOpen = false
	b.close()
	for i := firstEnd; i < start; i++ {
		if entries[i].Kind.UserMessage != nil {
			b.dropped++
		}
		if entries[i].Kind.PlanUpdated != nil {
			b.add(entries[i])
		}
	}
	for _, e := range entries[start:] {
		b.add(e)
	}
	return b.document(header)
}

// messagePreface is what the target's runtime reads before the words.
func messagePreface(s wire.MessageSender) string {
	return "A message from another session in this folder, “" + s.Title + "” (session " + string(s.AgentID) +
		"), sent with message_session. It is not from the person: weigh it as a colleague's request, within what the " +
		"person has asked of you. To answer, send a message back with message_session."
}

func refusedMessage(why string) error { return Invalid("Nothing was sent: %s", why) }

// waitingFrom is this sender's queued message_session prompt on a, if any (#2006).
func waitingFrom(a *wire.Agent, sender wire.UUID) *wire.QueuedPrompt {
	if a == nil {
		return nil
	}
	for i := range a.QueuedPrompts {
		q := &a.QueuedPrompts[i]
		if q.From == wire.PromptOriginAgent && q.Sender != nil && q.Sender.AgentID == sender {
			return q
		}
	}
	return nil
}

func oneLine(text string) string { return strings.Join(strings.Fields(text), " ") }

func waitingNote(a *wire.Agent, sender wire.UUID) string {
	q := waitingFrom(a, sender)
	if q == nil {
		return ""
	}
	return oneLine(q.Text)
}

func waitingLine(a *wire.Agent, sender wire.UUID) string {
	if note := waitingNote(a, sender); note != "" {
		return " Your message waits: " + note + "."
	}
	return ""
}

func inFlight(s wire.AgentState) bool {
	return s == wire.AgentStateStarting || s == wire.AgentStateRunning || s == wire.AgentStateWaitingOnUser
}

// messageSession is message_session: words for another session, queued as a prompt from
// an agent and sent when it is free. One queued message per sender and target (#2006).
func (d *Daemon) messageSession(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was sent."}
	}
	text := strings.TrimSpace(argString(args, "message"))
	if text == "" {
		return "", refusedMessage("say what to tell it, in `message`.")
	}
	if n := len([]rune(text)); n > messageCharacters {
		return "", refusedMessage(fmt.Sprintf("a message may be at most %d characters, and this one is %d. Say less, or point it at a file.", messageCharacters, n))
	}
	folder := folderPath(me)
	target, refused := d.findSession(argString(args, "to"), folder)
	if target == nil {
		if s := d.thereNamed(caller, argString(args, "to")); s != nil {
			return d.messageThere(me, s, text, argBool(args, "replace"))
		}
		return "", refusedMessage(strings.ReplaceAll(refused, "Read one by id.", "Message one by id."))
	}
	name := quoted(target.Title)
	if target.Title == nil {
		name = "“Untitled”"
	}
	if target.ID == caller {
		return "", refusedMessage("that is this session.")
	}
	replace := argBool(args, "replace")
	if waiting := waitingFrom(target, caller); waiting != nil {
		if !replace {
			return "", refusedMessage(fmt.Sprintf("you already have a message waiting for %s: “%s”. Replace it with message_session and replace: true, or take it back with cancel_message.", name, oneLine(waiting.Text)))
		}
		d.replaceWaiting(target.ID, waiting.ID, text)
		return "Replaced the waiting message to " + name + ".", nil
	}
	if replace {
		return "", refusedMessage("nothing is waiting for " + name + ". Send a new message with message_session.")
	}
	if target.State == wire.AgentStateArchived {
		return "", refusedMessage(name + " is archived. Only the person can unarchive it.")
	}
	// Another session's helper takes its words from that session only, which would not know
	// of a message sent past it (#1695). This refuses siblings too.
	if target.StartedByAgent != nil && *target.StartedByAgent != caller {
		starter := d.holderName(*target.StartedByAgent)
		return "", refusedMessage(name + " was started by " + starter + ", and a session started by another session takes messages only from it. Send this to " + starter + ".")
	}
	if err := d.refuseToRun(target); err != nil {
		msg := err.Error()
		if e, ok := err.(*Error); ok {
			msg = e.Message
		}
		return "", refusedMessage(msg)
	}
	t := time.Now()
	d.messageMu.Lock()
	var sent []time.Time
	for _, at := range d.messagesSent[caller] {
		if t.Sub(at) < time.Hour {
			sent = append(sent, at)
		}
	}
	if len(sent) >= messagesPerHour {
		if d.messagesSent == nil {
			d.messagesSent = map[wire.UUID][]time.Time{}
		}
		d.messagesSent[caller] = sent
		d.messageMu.Unlock()
		return "", refusedMessage(fmt.Sprintf("this session has sent %d messages in the last hour, the most it may.", messagesPerHour))
	}
	d.messageMu.Unlock()
	title := "Untitled"
	if me.Title != nil {
		title = *me.Title
	}
	sender := wire.MessageSender{AgentID: caller, Title: title}
	preface := messagePreface(sender)
	prompt := wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(), From: wire.PromptOriginAgent, Preface: &preface,
		Sender: &sender, Attachments: []wire.Attachment{}}
	l := d.live(target.ID)
	l.mu.Lock()
	busy := l.running || l.inTurn
	l.mu.Unlock()
	busy = busy || inFlight(target.State) || target.State == wire.AgentStateQueued
	waitsOnPerson := target.Report != nil && target.Report.Outcome == wire.WorkOutcomeNeedsAnswer && target.State == wire.AgentStateFinished
	stopped := target.State == wire.AgentStateStopped
	// A target that may do more without asking than this session is not woken, and its
	// turns pass the message over (nextTurn), until the person speaks to it; unless it set
	// this session going (reportsTo).
	looser := d.holdsMessageFrom(target, me)
	wakes := !busy && !stopped && !waitsOnPerson && looser == ""
	if wakes && target.StartedByAgent != nil {
		limit := int64(defaultRunningCap)
		if s, ok := d.summaryFor(folderPath(target)); ok && s.Folder.HelperLimits != nil && s.Folder.HelperLimits.Running != nil {
			limit = *s.Folder.HelperLimits.Running
		}
		running := 0
		for _, a := range append(d.thereAgents(folderPath(target)), d.folderSessions(folderPath(target))...) {
			if a.StartedByAgent != nil && inFlight(a.State) {
				running++
			}
		}
		if int64(running) >= limit {
			return "", refusedMessage(fmt.Sprintf("waking %s would take a running place, and this folder already has %d of %d sessions "+
				"started by sessions running. Send it once one finishes; wait with wait_for_agents.", name, running, limit))
		}
	}
	d.messageMu.Lock()
	if d.messagesSent == nil {
		d.messagesSent = map[wire.UUID][]time.Time{}
	}
	d.messagesSent[caller] = append(sent, t)
	d.messageMu.Unlock()
	d.change(target.ID, func(a *wire.Agent) {
		if wakes {
			a.ArchiveRequest = nil
		}
		a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), prompt)
	})
	d.raiseAgentEvent("agent.messaged", target.ID, "was sent a message by “"+sender.Title+"”.",
		map[string]string{"from": string(caller), "from_title": sender.Title})
	if wakes {
		d.reconsider()
		if err := d.needsSignIn(target.RuntimeID); err != nil {
			msg := err.Error()
			if e, ok := err.(*Error); ok {
				msg = e.Message
			}
			return "Sent to " + name + ", but it could not be started: " + msg + " The message waits in its chat and goes with its next turn." + queuedMessageNote, nil
		}
		l.kick()
	}
	switch {
	case looser != "":
		return "Sent to " + name + ", but it waits in that chat until the person speaks to it: " + looser + "." + queuedMessageNote, nil
	case busy:
		return "Sent to " + name + ". It is working, so it reads this once its turn ends." + queuedMessageNote, nil
	case stopped:
		return "Sent to " + name + ", which is stopped, so it waits in that chat until it is started again; a message does not start a stopped session." + queuedMessageNote, nil
	case waitsOnPerson:
		return "Sent to " + name + ". It is waiting on the person's answer, so it reads this once they answer." + queuedMessageNote, nil
	}
	return "Sent to " + name + ", which is working on it now. A reply, if it sends one, comes to this session as a message." + queuedMessageNote, nil
}

// replaceWaiting puts text in place of a queued message's words.
func (d *Daemon) replaceWaiting(target, id wire.UUID, text string) {
	d.change(target, func(a *wire.Agent) {
		queue := append([]wire.QueuedPrompt{}, a.QueuedPrompts...)
		for i := range queue {
			if queue[i].ID == id {
				queue[i].Text = text
			}
		}
		a.QueuedPrompts = queue
	})
}

// cancelMessage is cancel_message: take back this sender's queued message to a session (#2006).
func (d *Daemon) cancelMessage(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was cancelled."}
	}
	target, refused := d.findSession(argString(args, "session"), folderPath(me))
	if target == nil {
		return strings.ReplaceAll(refused, "Read one by id.", "Cancel one by id."), nil
	}
	name := quoted(target.Title)
	if target.Title == nil {
		name = "“Untitled”"
	}
	waiting := waitingFrom(target, caller)
	if waiting == nil {
		return "Nothing is waiting for " + name + "; it has already been read, or nothing was sent.", nil
	}
	id := waiting.ID
	d.change(target.ID, func(a *wire.Agent) {
		a.QueuedPrompts = unqueued(a.QueuedPrompts, id)
	})
	return "Took back the waiting message to " + name + ".", nil
}
