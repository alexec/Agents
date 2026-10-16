package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
	"unicode"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// live is an agent with a runtime behind it: its session, its queue of prompts, and the
// cards it is waiting on.
type live struct {
	d       *Daemon
	id      wire.UUID
	mu      sync.Mutex
	session *acp.Session
	running bool
	pending map[wire.UUID]*pendingPermission
	// elicitations is the forms it is waiting on (elicitations.go).
	elicitations map[wire.UUID]*pendingElicitation
	stop         context.CancelFunc
	// inTurn is whether a turn is in flight: a form is asked only in one.
	inTurn bool
	// prompting is whether the turn's words are with the runtime; a stop before then is
	// kept in stopped, and the turn ends there instead of sending them.
	prompting, stopped bool
	// messageText is the text of the agent's last message this turn, for its report.
	lastMessageID string
	lastMessage   strings.Builder
	// toolCalls is the tool calls recorded, by id, so a card waits for the call it names:
	// the SDK hands a request over on a goroutine of its own, ahead of the notifications
	// that came before it on the wire.
	toolCalls map[string]bool
	seen      *sync.Cond
}

type pendingPermission struct {
	req    wire.PermissionRequest
	answer chan string
}

func (d *Daemon) live(id wire.UUID) *live {
	d.mu.Lock()
	defer d.mu.Unlock()
	l := d.lives[id]
	if l == nil {
		l = &live{d: d, id: id, pending: map[wire.UUID]*pendingPermission{}, elicitations: map[wire.UUID]*pendingElicitation{},
			toolCalls: map[string]bool{}}
		l.seen = sync.NewCond(&l.mu)
		d.lives[id] = l
	}
	return l
}

func now() wire.Date { return wire.DateOf(nowFunc()) }

// record appends an entry to an agent's transcript and tells every client.
func (d *Daemon) record(id wire.UUID, kind wire.TranscriptEntryKind) {
	e := wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: kind}
	n, err := d.Store.Append(id, e)
	if err != nil {
		log.Printf("agent %s: could not record an entry: %v", id, err)
		return
	}
	index := int64(n)
	Broadcast(d, wire.NotifyAgentEntry, wire.EntryNotification{AgentID: id, Entry: e, Index: &index})
}

func notice(severity, title, detail string) wire.TranscriptEntryKind {
	n := wire.SessionNotice{Severity: severity, Title: title}
	if detail != "" {
		n.Detail = &detail
	}
	return wire.TranscriptEntryKind{Notice: &wire.TranscriptEntryKindNotice{Value: n}}
}

func stateChanged(s wire.AgentState, reason *wire.EndedReason) wire.TranscriptEntryKind {
	return wire.TranscriptEntryKind{StateChanged: &wire.TranscriptEntryKindStateChanged{Value: s, Reason: reason}}
}

// change saves an agent's record, moved on to now, and tells every client and its project.
func (d *Daemon) change(id wire.UUID, edit func(a *wire.Agent)) *wire.Agent {
	d.agentMu.Lock()
	defer d.agentMu.Unlock()
	a := d.Store.Agent(id)
	if a == nil {
		return nil
	}
	edit(a)
	a.LastActivityAt = now()
	if err := d.Store.Save(*a); err != nil {
		log.Printf("agent %s: %v", id, err)
		return nil
	}
	Broadcast(d, wire.NotifyAgentChanged, *a)
	d.projectChanged(projectFolder(a))
	// Every place a need begins or ends moves the record (DaemonCore.move's reconsider).
	safe.Go("reconsider", d.reconsider)
	return a
}

func (d *Daemon) projectChanged(folder string) {
	for _, s := range d.projects(true) {
		if store.FolderPath(s.Project.Folder) == folder {
			Broadcast(d, wire.NotifyProjectChanged, s)
			return
		}
	}
}

func reason(r wire.EndedReason) *wire.EndedReason { return &r }

// start makes an agent and queues its first turn.
func (d *Daemon) start(r wire.StartRequest) (wire.UUID, error) {
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return "", &Error{Code: CodeRuntimeNotFound, Message: "no runtime " + r.RuntimeID}
	}
	path := store.FolderPath(r.Cwd)
	if !isDir(path) {
		return "", &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	if err := d.needsSignIn(r.RuntimeID); err != nil {
		return "", err
	}
	// The same start sent again (a window retrying) is the agent it made.
	if r.RequestID != nil {
		for _, a := range d.Store.Agents() {
			if a.StartRequestID != nil && *a.StartRequestID == *r.RequestID {
				return a.ID, nil
			}
		}
	}
	values := r.StartOptions.Values
	if values == nil {
		values = map[string]wire.JSONValue{}
	}
	extra := r.StartOptions.ExtraArguments
	if extra == nil {
		extra = []string{}
	}
	// A worktree asked for is made before anything else, and taken back if the start fails.
	var wt *wire.AgentWorktree
	if r.Worktree != nil {
		var err error
		if wt, path, err = d.prepareWorktree(path, *r.Worktree, r.Prompt); err != nil {
			return "", err
		}
	}
	t := now()
	title := titleFrom(r.Prompt)
	a := wire.Agent{
		ID: store.NewUUID(), RuntimeID: r.RuntimeID, Cwd: store.FolderURL(path), State: wire.AgentStateStarting,
		StartOptions:      wire.StartOptions{Values: values, ExtraArguments: extra},
		AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
		CreatedAt: t, LastActivityAt: t, MadeInRoot: &d.Store.RootID, StartRequestID: r.RequestID,
	}
	if title != "" {
		a.Title = &title
	}
	for _, l := range r.Labels {
		a.Labels = append(a.Labels, wire.SessionLabel{Value: l, Owner: wire.SessionLabelOwnerPerson, AddedAt: t})
	}
	a.Worktree = wt
	if err := d.Store.Save(a); err != nil {
		if wt != nil {
			undoWorktree(*r.Worktree, wt)
		}
		return "", err
	}
	Broadcast(d, wire.NotifyAgentChanged, a)
	d.projectChanged(projectFolder(&a))
	if wt != nil {
		d.record(a.ID, runtimeNote(worktreeNote(*wt)))
	}
	if r.Purpose == nil {
		safe.Go("starting point", func() { d.takeStartingPoint(a.ID, path) })
	}
	if err := d.enqueue(a.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: r.Prompt, Attachments: r.Attachments,
		QueuedAt: t, From: wire.PromptOriginPerson}, false); err != nil {
		return "", err
	}
	return a.ID, nil
}

func titleFrom(prompt string) string {
	t := strings.TrimSpace(strings.SplitN(strings.TrimSpace(prompt), "\n", 2)[0])
	if r := []rune(t); len(r) > 60 {
		t = string(r[:60]) + "…"
	}
	return t
}

// enqueue keeps the words on the agent's record (QueuedPrompt), first or last, and sends
// what is queued once the agent is free (DaemonCore.enqueue). The queue is the daemon's,
// never the runtime's, and outlives a restart.
func (d *Daemon) enqueue(id wire.UUID, q wire.QueuedPrompt, first bool) error {
	if q.Attachments == nil {
		q.Attachments = []wire.Attachment{}
	}
	a := d.change(id, func(a *wire.Agent) {
		if first {
			a.QueuedPrompts = append([]wire.QueuedPrompt{q}, a.QueuedPrompts...)
		} else {
			a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), q)
		}
		if q.From == wire.PromptOriginPerson {
			a.Report, a.OutcomeAsked = nil, nil
		}
	})
	if a == nil {
		return &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	d.live(id).kick()
	return nil
}

// kick starts the agent's turns unless they are running.
func (l *live) kick() {
	l.mu.Lock()
	start := !l.running
	l.running = true
	l.mu.Unlock()
	if start {
		safe.Go("agent "+string(l.id), l.run)
	}
}

// nextTurn is QueuedPrompt.nextTurn and merging: the run of the person's prompts at the
// head goes as one (#346), since what was typed later so often corrects what came first;
// anything else goes alone.
func nextTurn(queue []wire.QueuedPrompt) (wire.QueuedPrompt, []wire.QueuedPrompt, bool) {
	if len(queue) == 0 {
		return wire.QueuedPrompt{}, queue, false
	}
	n := 1
	if queue[0].From == wire.PromptOriginPerson {
		for n < len(queue) && queue[n].From == wire.PromptOriginPerson {
			n++
		}
	}
	merged := queue[0]
	var texts, prefaces []string
	merged.Attachments = []wire.Attachment{}
	for _, q := range queue[:n] {
		texts = append(texts, q.Text)
		if q.Preface != nil {
			prefaces = append(prefaces, *q.Preface)
		}
		merged.Attachments = append(merged.Attachments, q.Attachments...)
	}
	merged.Text = strings.Join(texts, "\n\n")
	merged.Preface = nil
	if len(prefaces) > 0 {
		p := strings.Join(prefaces, "\n\n")
		merged.Preface = &p
	}
	return merged, append([]wire.QueuedPrompt(nil), queue[n:]...), true
}

// blocks is QueuedPrompt.blocks: the words, then what is attached.
func blocks(q wire.QueuedPrompt) []wire.ContentBlock {
	out := []wire.ContentBlock{textBlock(q.Text)}
	for _, a := range q.Attachments {
		out = append(out, a.Block)
	}
	return out
}

func textBlock(text string) wire.ContentBlock {
	return wire.ContentBlock{Type: "text", Text: &text}
}

// run sends what is queued, one turn at a time, until the queue is empty or a turn was
// stopped: a stop leaves the queue where it is (drainQueue).
func (l *live) run() {
	for {
		l.mu.Lock()
		a := l.d.Store.Agent(l.id)
		if a == nil || len(a.QueuedPrompts) == 0 {
			l.running = false
			l.mu.Unlock()
			return
		}
		l.mu.Unlock()
		drain := false
		if v := safe.Catch("turn of "+string(l.id), func() { drain = l.turn() }); v != nil {
			// The turn's own defers ran; end it so the window does not wait on it.
			l.d.record(l.id, notice("error", "The host hit a bug", fmt.Sprint(v)))
			l.d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
		}
		if !drain {
			l.mu.Lock()
			l.running = false
			l.mu.Unlock()
			return
		}
	}
}

// turn starts the runtime if it has none, then takes the next turn's words off the queue
// and sends them: a runtime that will not start leaves them where they were. It is true
// when what is queued behind may go next.
func (l *live) turn() bool {
	d := l.d
	a := d.Store.Agent(l.id)
	if a == nil {
		return false
	}
	ctx, cancel := context.WithCancel(d.ctx)
	l.mu.Lock()
	l.stop = cancel
	l.inTurn, l.prompting, l.stopped = true, false, false
	l.mu.Unlock()
	defer cancel()
	defer func() {
		l.mu.Lock()
		l.inTurn, l.prompting = false, false
		l.mu.Unlock()
	}()

	if l.session == nil {
		rt := runtimeByID(a.RuntimeID)
		dir := store.FolderPath(a.Cwd)
		launch, err := d.launchFor(rt, dir)
		if err != nil {
			d.record(l.id, notice("error", rt.Name+" did not start", err.Error()))
			d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
			return false
		}
		d.record(l.id, wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: "Starting " + rt.Name + "…"}})
		continuing := ""
		if a.RuntimeSessionID != nil {
			continuing = *a.RuntimeSessionID
		}
		s, err := acp.Start(ctx, launch, l, d.mcpServersFor(l.id), sessionMeta(a.RuntimeID), continuing)
		if err != nil && ctx.Err() != nil {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
			return false
		}
		if err != nil {
			log.Printf("agent %s: %v", l.id, err)
			d.record(l.id, notice("error", rt.Name+" did not start", err.Error()))
			d.end(l, wire.AgentStateStopped, wire.EndedReasonProcessDied)
			return false
		}
		l.mu.Lock()
		l.session = s
		l.mu.Unlock()
		switch {
		case s.Continued:
			d.record(l.id, runtimeNote("Picked the conversation back up."))
		case s.Lost:
			d.record(l.id, runtimeNote(rt.Name+" no longer has this conversation. Carrying on in a new one; everything above is kept."))
		}
		sessionID := string(s.ID)
		d.change(l.id, func(a *wire.Agent) {
			a.RuntimeSessionID = &sessionID
			if opts := configOptions(s.NewResult.ConfigOptions); opts != nil {
				a.AdvertisedOptions = opts
			}
		})
		safe.Go("session watch", func() {
			<-s.Done()
			l.mu.Lock()
			if l.session == s {
				l.session = nil
			}
			l.mu.Unlock()
		})
		// The start options the window chose (model, mode) go first.
		for k, v := range a.StartOptions.Values {
			var sv string
			if json.Unmarshal(v, &sv) == nil && sv != "" {
				if err := s.SetConfig(ctx, k, sv); err != nil {
					log.Printf("agent %s: set %s=%s: %v", l.id, k, sv, err)
				}
			}
		}
	}
	// The words, off the queue now the runtime is there to take them.
	var q wire.QueuedPrompt
	taken := false
	d.change(l.id, func(a *wire.Agent) { q, a.QueuedPrompts, taken = nextTurn(a.QueuedPrompts) })
	if !taken {
		return false
	}
	bs := blocks(q)
	from := q.From
	if from == "" {
		from = wire.PromptOriginPerson
	}
	um := &wire.TranscriptEntryKindUserMessage{Value: q.Text, From: &from}
	if len(bs) > 1 {
		um.Blocks = bs
	}
	d.record(l.id, wire.TranscriptEntryKind{UserMessage: um})
	l.mu.Lock()
	l.lastMessageID = ""
	l.lastMessage.Reset()
	clear(l.toolCalls)
	l.mu.Unlock()
	d.setState(l.id, wire.AgentStateRunning)
	if q.Preface != nil {
		bs = append([]wire.ContentBlock{textBlock(*q.Preface)}, bs...)
	}
	l.mu.Lock()
	s, stopped := l.session, l.stopped
	l.prompting = !stopped
	l.mu.Unlock()
	if stopped {
		d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
		return false
	}
	r, err := s.Prompt(ctx, acpBlocks(bs))
	if err != nil {
		if ctx.Err() != nil {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
			return false
		}
		log.Printf("agent %s: prompt: %v", l.id, err)
		l.closeForms()
		d.record(l.id, notice("error", "The turn failed", err.Error()))
		select {
		case <-s.Done():
			d.end(l, wire.AgentStateStopped, wire.EndedReasonProcessDied)
		default:
			d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
		}
		return true
	}
	if r.Usage != nil {
		u := wire.TurnUsage{TotalTokens: int64(r.Usage.TotalTokens), InputTokens: int64(r.Usage.InputTokens), OutputTokens: int64(r.Usage.OutputTokens)}
		d.record(l.id, wire.TranscriptEntryKind{UsageRecorded: &wire.TranscriptEntryKindUsageRecorded{Value: u}})
		d.change(l.id, func(a *wire.Agent) { a.LastTurnUsage = &u })
	}
	switch r.StopReason {
	case sdk.StopReasonEndTurn:
		d.end(l, wire.AgentStateFinished, wire.EndedReasonEndTurn)
	case sdk.StopReasonCancelled:
		// A stop leaves what is queued behind it.
		d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
		return false
	case sdk.StopReasonMaxTokens:
		d.end(l, wire.AgentStateStopped, wire.EndedReasonMaxTokens)
	case sdk.StopReasonMaxTurnRequests:
		d.end(l, wire.AgentStateStopped, wire.EndedReasonMaxTurnRequests)
	case sdk.StopReasonRefusal:
		d.end(l, wire.AgentStateStopped, wire.EndedReasonRefusal)
	default:
		d.end(l, wire.AgentStateStopped, wire.EndedReasonUnrecognised)
	}
	return true
}

// acpBlocks is the blocks as ACP has them: the same shape, in the SDK's types.
func acpBlocks(bs []wire.ContentBlock) []sdk.ContentBlock {
	out := make([]sdk.ContentBlock, 0, len(bs))
	for _, b := range bs {
		var c sdk.ContentBlock
		raw, _ := json.Marshal(b)
		if json.Unmarshal(raw, &c) == nil {
			out = append(out, c)
		}
	}
	return out
}

// setState moves a running agent's state, clearing an ending and a report it had.
func (d *Daemon) setState(id wire.UUID, s wire.AgentState) {
	changed := false
	d.change(id, func(a *wire.Agent) {
		if a.State == s {
			return
		}
		changed = true
		a.State = s
		a.EndedReason = nil
		a.ArchivedReason = nil
		if s == wire.AgentStateRunning {
			a.Report = nil
		}
	})
	if changed {
		d.record(id, stateChanged(s, nil))
	}
}

// end closes a turn: the state, its reason, and for a finished turn a report derived
// from the agent's last words (DaemonCore+DerivedEnding): needs_answer when it ends on a
// question, done with its first sentence otherwise.
func (d *Daemon) end(l *live, s wire.AgentState, why wire.EndedReason) {
	l.mu.Lock()
	last := l.lastMessage.String()
	l.mu.Unlock()
	d.change(l.id, func(a *wire.Agent) {
		a.State, a.EndedReason = s, reason(why)
		a.RestartPickUps = nil // any ending but the daemon's going clears the count
		unread := s == wire.AgentStateFinished
		a.IsUnread = &unread
		if s == wire.AgentStateFinished {
			outcome, message := wire.WorkOutcomeDone, firstSentence(last)
			if strings.HasSuffix(strings.TrimSpace(last), "?") {
				outcome = wire.WorkOutcomeNeedsAnswer
			}
			if message == "" {
				message = "Finished."
			}
			a.Report = &wire.WorkReport{Outcome: outcome, Message: message, At: now()}
		}
	})
	d.record(l.id, stateChanged(s, reason(why)))
	// What the turn did to the app's own files is looked at as it ends (guardedTurnEnded).
	d.guardedTurnEnded(l.id)
}

func firstSentence(s string) string {
	// Code is not a sentence: fenced blocks are left out.
	var prose []string
	fenced := false
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			fenced = !fenced
			continue
		}
		if !fenced && strings.TrimSpace(line) != "" {
			prose = append(prose, line)
		}
	}
	s = strings.TrimSpace(strings.Join(prose, "\n"))
	for i, r := range s {
		if (r == '.' || r == '!' || r == '?') && (i+1 == len(s) || unicode.IsSpace(rune(s[i+1]))) {
			return s[:i+1]
		}
		if r == '\n' {
			return strings.TrimSpace(s[:i])
		}
	}
	if r := []rune(s); len(r) > 200 {
		return string(r[:200]) + "…"
	}
	return s
}

// MARK: acp.Sink

// toolCall is SessionUpdate.toolCall(in:): ACP's tool call or update as today's ToolCall
// record. The title is the runtime's, else its kind, else "Tool call"; raw is the update
// without the parts kept as fields of their own.
func toolCall(v any) wire.ToolCall {
	b, _ := json.Marshal(v)
	var u map[string]json.RawMessage
	json.Unmarshal(b, &u)
	str := func(k string) *string {
		var s string
		if json.Unmarshal(u[k], &s) == nil {
			return &s
		}
		return nil
	}
	tc := wire.ToolCall{ToolCallID: str("toolCallId"), Name: str("name"), Kind: str("kind"), Status: str("status"),
		Content: []wire.ToolCallContent{}, Locations: []wire.ToolCallLocation{}}
	switch {
	case str("title") != nil:
		tc.Title = *str("title")
	case tc.Kind != nil:
		tc.Title = *tc.Kind
	default:
		tc.Title = "Tool call"
	}
	if raw, ok := u["content"]; ok {
		var c []wire.ToolCallContent
		if json.Unmarshal(raw, &c) == nil && c != nil {
			tc.Content = c
		}
	}
	if raw, ok := u["locations"]; ok {
		var l []wire.ToolCallLocation
		if json.Unmarshal(raw, &l) == nil && l != nil {
			tc.Locations = l
		}
	}
	if raw, ok := u["rawInput"]; ok && string(raw) != "null" {
		tc.RawInput = raw
	}
	if raw, ok := u["rawOutput"]; ok && string(raw) != "null" {
		tc.RawOutput = raw
	}
	trimmed := map[string]json.RawMessage{}
	for k, v := range u {
		switch k {
		case "content", "rawInput", "rawOutput", "_meta":
		default:
			if string(v) != "null" {
				trimmed[k] = v
			}
		}
	}
	tc.Raw, _ = json.Marshal(trimmed)
	return tc
}

func configOptions(v any) []wire.ConfigOption {
	b, err := json.Marshal(v)
	if err != nil || string(b) == "null" {
		return nil
	}
	var out []wire.ConfigOption
	if json.Unmarshal(b, &out) != nil {
		return nil
	}
	return out
}

// Update turns one ACP session update into today's transcript records.
func (l *live) Update(n sdk.SessionNotification) {
	d := l.d
	u := n.Update
	switch {
	case u.AgentMessageChunk != nil || u.AgentThoughtChunk != nil:
		var c sdk.ContentBlock
		var id *string
		thought := u.AgentThoughtChunk != nil
		if thought {
			c, id = u.AgentThoughtChunk.Content, messageID(u.AgentThoughtChunk.MessageId)
		} else {
			c, id = u.AgentMessageChunk.Content, messageID(u.AgentMessageChunk.MessageId)
		}
		if c.Text == nil || c.Text.Text == "" {
			return
		}
		text := c.Text.Text
		if thought {
			d.record(l.id, wire.TranscriptEntryKind{AgentThought: &wire.TranscriptEntryKindAgentThought{MessageID: id, Text: text}})
			return
		}
		l.mu.Lock()
		mid := ""
		if id != nil {
			mid = *id
		}
		if mid != l.lastMessageID {
			l.lastMessage.Reset()
			l.lastMessageID = mid
		}
		l.lastMessage.WriteString(text)
		l.mu.Unlock()
		d.record(l.id, wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: id, Text: text}})
	case u.ToolCall != nil:
		d.record(l.id, wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{Value: toolCall(u.ToolCall)}})
		l.mu.Lock()
		l.lastMessageID, l.lastMessage = "", strings.Builder{}
		l.toolCalls[string(u.ToolCall.ToolCallId)] = true
		l.seen.Broadcast()
		l.mu.Unlock()
	case u.ToolCallUpdate != nil:
		d.record(l.id, wire.TranscriptEntryKind{ToolCallUpdate: &wire.TranscriptEntryKindToolCallUpdate{Value: toolCall(u.ToolCallUpdate)}})
	case u.Plan != nil:
		b, _ := json.Marshal(u.Plan.Entries)
		var entries []wire.PlanEntry
		json.Unmarshal(b, &entries)
		if entries == nil {
			entries = []wire.PlanEntry{}
		}
		id := "plan"
		plan := wire.Plan{PlanID: &id, Entries: entries, State: wire.PlanStateCurrent, At: now()}
		d.change(l.id, func(a *wire.Agent) { a.Plans = []wire.Plan{plan} })
		d.record(l.id, wire.TranscriptEntryKind{PlanUpdated: &wire.TranscriptEntryKindPlanUpdated{Value: plan}})
	case u.CurrentModeUpdate != nil:
		v, _ := json.Marshal(u.CurrentModeUpdate.CurrentModeId)
		d.record(l.id, wire.TranscriptEntryKind{OptionChanged: &wire.TranscriptEntryKindOptionChanged{ID: "mode", Value: v}})
	case u.ConfigOptionUpdate != nil:
		if opts := configOptions(u.ConfigOptionUpdate.ConfigOptions); opts != nil {
			d.change(l.id, func(a *wire.Agent) { a.AdvertisedOptions = opts })
		}
	case u.AvailableCommandsUpdate != nil:
		b, _ := json.Marshal(u.AvailableCommandsUpdate.AvailableCommands)
		var cmds []wire.SlashCommand
		if json.Unmarshal(b, &cmds) == nil && cmds != nil {
			d.change(l.id, func(a *wire.Agent) { a.AvailableCommands = cmds })
		}
	case u.SessionInfoUpdate != nil:
		// The runtime names the conversation (#492), unless the person named it.
		if t := u.SessionInfoUpdate.Title; t != nil && *t != "" {
			d.change(l.id, func(a *wire.Agent) {
				a.RuntimeTitle = t
				if a.TitleIsPersons == nil || !*a.TitleIsPersons {
					a.Title = t
				}
			})
		}
	default:
		b, _ := json.Marshal(u)
		log.Printf("agent %s: an update not drawn yet: %.120s", l.id, b)
	}
}

func messageID(p *string) *string {
	if p == nil || *p == "" {
		return nil
	}
	return p
}

// Permission asks the person, as a card, and waits for the answer: the option chosen, or
// "" when the turn was stopped.
func (l *live) Permission(ctx context.Context, p sdk.RequestPermissionRequest) string {
	d := l.d
	l.waitForToolCall(string(p.ToolCall.ToolCallId), 500*time.Millisecond)
	req := wire.PermissionRequest{ID: store.NewUUID(), AgentID: l.id, ToolCall: toolCall(p.ToolCall), AskedAt: now(),
		Options: []wire.PermissionOption{}}
	for _, o := range p.Options {
		req.Options = append(req.Options, wire.PermissionOption{OptionID: string(o.OptionId), Name: o.Name, Kind: wire.PermissionOptionKind(o.Kind)})
	}
	// The app's own tools are allowed with no question, as the Swift host does.
	if strings.HasPrefix(req.ToolCall.Title, "mcp__agents__") {
		for _, o := range req.Options {
			if o.Kind == "allow_always" || o.Kind == "allow_once" {
				return o.OptionID
			}
		}
	}
	pp := &pendingPermission{req: req, answer: make(chan string, 1)}
	l.mu.Lock()
	l.pending[req.ID] = pp
	l.mu.Unlock()
	d.record(l.id, wire.TranscriptEntryKind{PermissionAsked: &wire.TranscriptEntryKindPermissionAsked{Value: req}})
	d.setState(l.id, wire.AgentStateWaitingOnUser)
	Broadcast(d, wire.NotifyAgentPermission, wire.PermissionNotification{AgentID: l.id, Request: &req})
	d.reconsider()
	var option string
	select {
	case option = <-pp.answer:
	case <-ctx.Done():
	}
	l.mu.Lock()
	delete(l.pending, req.ID)
	l.mu.Unlock()
	if option != "" {
		name := option
		for _, o := range req.Options {
			if o.OptionID == option {
				name = o.Name
			}
		}
		d.record(l.id, wire.TranscriptEntryKind{PermissionAnswered: &wire.TranscriptEntryKindPermissionAnswered{OptionID: option, OptionName: &name}})
	}
	id := req.ID
	Broadcast(d, wire.NotifyAgentPermission, wire.PermissionNotification{AgentID: l.id, RequestID: &id})
	d.reconsider()
	if ctx.Err() == nil {
		d.setState(l.id, wire.AgentStateRunning)
	}
	return option
}

// waitForToolCall waits, at most for a while, until the tool call id has been recorded.
func (l *live) waitForToolCall(id string, most time.Duration) {
	if id == "" {
		return
	}
	timer := time.AfterFunc(most, func() { l.mu.Lock(); l.seen.Broadcast(); l.mu.Unlock() })
	defer timer.Stop()
	deadline := time.Now().Add(most)
	l.mu.Lock()
	for !l.toolCalls[id] && time.Now().Before(deadline) {
		l.seen.Wait()
	}
	l.mu.Unlock()
}

// Served is a file read or write, or a terminal, done for the runtime.
func (l *live) Served(kind, detail string) {
	log.Printf("agent %s: served %s %s", l.id, kind, detail)
}

func (l *live) answer(permissionID wire.UUID, option string) bool {
	l.mu.Lock()
	pp := l.pending[permissionID]
	l.mu.Unlock()
	if pp == nil {
		return false
	}
	for _, o := range pp.req.Options {
		if o.OptionID == option {
			select {
			case pp.answer <- option:
			default:
			}
			return true
		}
	}
	return false
}

// cancel stops the turn: session/cancel to the runtime, and every open card let go.
func (l *live) cancel() {
	l.closeForms()
	l.mu.Lock()
	s, stop := l.session, l.stop
	if l.inTurn && !l.prompting {
		// Not with the runtime yet: session/cancel would find no turn to end.
		l.stopped = true
		if s != nil {
			s = nil
			stop = nil
		}
	}
	for _, pp := range l.pending {
		select {
		case pp.answer <- "":
		default:
		}
	}
	l.mu.Unlock()
	if s != nil {
		ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		if err := s.Cancel(ctx); err != nil && stop != nil {
			stop()
		}
	} else if stop != nil {
		stop()
	}
}

func (d *Daemon) pendingPermissions() []wire.PermissionRequest {
	d.mu.Lock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	d.mu.Unlock()
	out := []wire.PermissionRequest{}
	for _, l := range ls {
		l.mu.Lock()
		for _, pp := range l.pending {
			out = append(out, pp.req)
		}
		l.mu.Unlock()
	}
	return out
}

func (d *Daemon) stopAll() {
	d.mu.Lock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	d.mu.Unlock()
	for _, l := range ls {
		l.mu.Lock()
		s := l.session
		l.mu.Unlock()
		if s != nil {
			s.Stop()
		}
	}
}
