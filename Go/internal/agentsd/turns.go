package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/redact"
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
	// turnSeq counts turns, so a cancel sent again is only for the turn it was meant for.
	turnSeq int
	// reported is whether this turn said how it went itself (a wait on agents), so its
	// ending keeps that rather than one worked out from its last words.
	reported bool
	// showedFile is whether this turn called show_file (#1802): ending 2, which no
	// archive_session puts away unseen.
	showedFile bool
	// messageText is the text of the agent's last message this turn, for its report.
	lastMessageID string
	lastMessage   strings.Builder
	// held is the end of the last message chunk, held back for the next (chunkseam.go),
	// and heldID its message.
	held   string
	heldID *string
	// toolCalls is the tool calls recorded, by id, so a card waits for the call it names:
	// the SDK hands a request over on a goroutine of its own, ahead of the notifications
	// that came before it on the wire.
	toolCalls map[string]bool
	seen      *sync.Cond
	// evidence is what this turn's commands printed and what it replied, for a sandbox
	// that could not start (sandboxfailure.go).
	evidence turnEvidence
	// failure is the turn's typed failure and rateLimit the latest plan window the
	// runtime reported (limits.go); lastSent the turn's prompt, sent again after a rate
	// limit as resend, which is not recorded twice; rateLimitStreak and rateLimitAttempts
	// this chat's rate limits; stops counts the person's stops, which end a retry's wait.
	failure           *sessionFailure
	rateLimit         *wire.RateLimitInfo
	lastSent          *wire.QueuedPrompt
	resend            wire.UUID
	rateLimitStreak   []time.Time
	rateLimitAttempts int
	stops             int
	// briefDue is whether the next prompt carries the brief (brief.go): a new conversation
	// on a runtime that takes no system prompt.
	briefDue bool
	// tools is the turn's tool calls in flight, for Agent.RunningTool (runningtool.go).
	tools toolsInFlight
}

type pendingPermission struct {
	req    wire.PermissionRequest
	answer chan string
}

// noteShown is show_file's mark on the turn in flight (#1802).
func (l *live) noteShown() {
	l.mu.Lock()
	l.showedFile = true
	l.mu.Unlock()
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

// record appends an entry to an agent's transcript and tells the clients showing it.
func (d *Daemon) record(id wire.UUID, kind wire.TranscriptEntryKind) {
	d.recordFrom(id, kind, nil)
}

// recordFrom is record with the agent that sent the words, for a message between agents.
func (d *Daemon) recordFrom(id wire.UUID, kind wire.TranscriptEntryKind, sender *wire.MessageSender) {
	e := wire.TranscriptEntry{ID: store.NewUUID(), At: now(), Kind: kind, Sender: sender}
	n, e, err := d.Store.AppendOne(id, e)
	if err != nil {
		log.Printf("agent %s: could not record an entry: %v", id, err)
		return
	}
	d.tellEntry(id, e, n)
	// Where the turn's time went (#852), banked when it ends.
	if _, ok := timeMarkOf(e); ok {
		if a := d.Store.Agent(id); a != nil {
			d.noteTime(e, id, a.RuntimeID)
		}
	}
	// A turn starting or ending can earn the first agent or five at once (#984).
	if kind.StateChanged != nil {
		d.checkMilestonesSoon()
	}
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

// change saves an agent's record, moved on to now, and tells every client and its folder.
func (d *Daemon) change(id wire.UUID, edit func(a *wire.Agent)) *wire.Agent {
	return d.changeAgent(id, true, edit)
}

// changeAgent is change; with moveOn false, the record keeps its last activity, so a mark
// such as Mute (#2003) does not move the session up its list.
func (d *Daemon) changeAgent(id wire.UUID, moveOn bool, edit func(a *wire.Agent)) *wire.Agent {
	d.agentMu.Lock()
	defer d.agentMu.Unlock()
	a := d.Store.Agent(id)
	if a == nil {
		return nil
	}
	before := *a
	edit(a)
	if moveOn {
		a.LastActivityAt = now()
	}
	if err := d.Store.Save(*a); err != nil {
		log.Printf("agent %s: %v", id, err)
		return nil
	}
	d.tellChanged(*a, &before)
	d.folderChanged(folderPath(a))
	// A folder quiet after working says folder.idle (#1368).
	if before.State != a.State {
		folder := folderPath(a)
		safe.Go("folder idle", func() { d.watchForIdle(folder) })
	}
	// Every place a need begins or ends moves the record (DaemonCore.move's reconsider).
	safe.Go("reconsider", d.reconsider)
	return a
}

func (d *Daemon) folderChanged(folder string) {
	for _, s := range d.folders(true) {
		if store.FolderPath(s.Folder.Folder) == folder {
			Broadcast(d, wire.NotifyFolderChanged, s)
			return
		}
	}
}

func reason(r wire.EndedReason) *wire.EndedReason { return &r }

// start makes an agent and queues its first turn.
func (d *Daemon) start(r wire.StartRequest) (wire.UUID, error) {
	return d.startFor(r, startedBy{owner: wire.SessionLabelOwnerPerson})
}

// startAs is start for a person's call: agent.started names them (#1751).
func (d *Daemon) startAs(r wire.StartRequest, actor *wire.AuditActor) (wire.UUID, error) {
	return d.startFor(r, startedBy{owner: wire.SessionLabelOwnerPerson, actor: actor})
}

// startedBy is who a start is for: an agent that started it (a helper), the owner its
// labels are given, and the queued record it takes the place of.
type startedBy struct {
	agent  *wire.UUID
	owner  wire.SessionLabelOwner
	queued *wire.Agent
	// actor is the person whose call started it, when one did (#1751).
	actor *wire.AuditActor
}

func (d *Daemon) startFor(r wire.StartRequest, by startedBy) (wire.UUID, error) {
	// Auto picks the runtime, and the shared words become the runtime's own settings
	// (#2658), before anything else reads them.
	pick, client, err := d.resolveLevels(&r, by)
	if err != nil {
		return "", err
	}
	// The organisation's policy first (#998): its refusal says why, in its own words.
	policyNote, err := d.policyStart(&r, by)
	if err != nil {
		return "", err
	}
	if err := d.startRefusal(); err != nil {
		return "", err
	}
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return "", &Error{Code: CodeRuntimeNotFound, Message: "no runtime " + r.RuntimeID}
	}
	path := store.FolderPath(r.Cwd)
	if !isDir(path) {
		return "", &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	// An added account has its own sign-in (#840): the host's is not wanted for it.
	// "default" names the runtime's own sign-in (#999).
	ownNamed := r.AccountID != nil && *r.AccountID == ownSignIn
	if r.AccountID != nil && (*r.AccountID == "" || ownNamed) {
		r.AccountID = nil
	}
	// A helper on its starter's runtime uses its starter's account, where the policy lets it.
	if r.AccountID == nil && by.agent != nil {
		if c := d.Store.Agent(*by.agent); c != nil && c.RuntimeID == r.RuntimeID && c.AccountID != nil {
			if p := d.accountProfile(c.RuntimeID, *c.AccountID); p != nil && reachRefusal(d.orgPolicy(), r.RuntimeID, p, nil) == nil {
				r.AccountID = c.AccountID
			}
		}
	}
	// A session that names no account takes the runtime's default (#999, FR-016); a helper
	// or a workflow says so in its chat.
	if r.AccountID == nil && !ownNamed {
		if def := d.defaultAccount(r.RuntimeID); def != nil {
			r.AccountID = &def.ID
			if by.agent != nil || by.owner != wire.SessionLabelOwnerPerson {
				policyNote = strings.TrimSpace(policyNote + " It runs on " + def.Name + ", " + rt.Name + "'s default account.")
			}
		}
	}
	var account *wire.AccountProfile
	if r.AccountID != nil {
		if account = d.accountProfile(r.RuntimeID, *r.AccountID); account == nil {
			return "", Invalid("%s has no such account. It may have been removed.", rt.Name)
		}
	}
	// The organisation's policy may require the org path (#999, FR-015).
	if err := d.accountRefusal(r.RuntimeID, account); err != nil {
		return "", err
	}
	if account == nil {
		if err := d.needsSignIn(r.RuntimeID); err != nil {
			return "", err
		}
	}
	// The same start sent again (a window retrying) is the agent it made.
	if r.RequestID != nil {
		for _, a := range d.Store.Agents() {
			if a.StartRequestID != nil && *a.StartRequestID == *r.RequestID {
				return a.ID, nil
			}
		}
	}
	if r.DraftID != nil {
		d.closeDraft(*r.DraftID)
	}
	values := r.StartOptions.Values
	if values == nil {
		values = map[string]wire.JSONValue{}
	}
	extra := r.StartOptions.ExtraArguments
	if extra == nil {
		extra = []string{}
	}
	// Codex's sandbox is its mode, so the choice in force picks the mode it starts in.
	choice, _ := d.resolveSandbox(r.RuntimeID, r.Sandbox, by.agent)
	if mode, ok := codexStartMode(r.RuntimeID, choice, stringValue(values["mode"])); ok {
		values = maps.Clone(values)
		values["mode"], _ = json.Marshal(mode)
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
		StartedByAgent: by.agent, SandboxOverride: r.Sandbox, Persona: r.Persona, AccountID: r.AccountID,
		Auto: pick, ClientPermission: client,
	}
	a.Levels = d.matchLevels(&a)
	if q := by.queued; q != nil {
		// Out of the queue, the same agent: its id, its title and when it was asked for.
		a.ID, a.CreatedAt, a.Title, a.Labels = q.ID, q.CreatedAt, q.Title, q.Labels
	}
	if title != "" && a.Title == nil {
		a.Title = &title
	}
	if by.queued == nil {
		for _, l := range r.Labels {
			a.Labels = append(a.Labels, wire.SessionLabel{Value: l, Owner: by.owner, AddedAt: t})
		}
	}
	a.Worktree = wt
	if err := d.Store.Save(a); err != nil {
		if wt != nil {
			undoWorktree(*r.Worktree, wt)
		}
		return "", err
	}
	d.actedOn(a.ID, by.actor)
	d.tellChanged(a, nil)
	d.folderChanged(folderPath(&a))
	if wt != nil {
		d.record(a.ID, runtimeNote(worktreeNote(*wt)))
	}
	if pick != nil {
		d.record(a.ID, runtimeNote(autoNote(*pick)))
	}
	if policyNote != "" {
		d.record(a.ID, runtimeNote(policyNote))
	}
	if r.Purpose == nil {
		safe.Go("starting point", func() { d.takeStartingPoint(a.ID, path) })
	}
	// Started from voice mode (#2375): its first reply is heard, as a voice prompt's is.
	var preface *string
	if r.Voice != nil && *r.Voice {
		p := voicePreface
		preface = &p
	}
	if err := d.enqueue(a.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: r.Prompt, Attachments: r.Attachments,
		QueuedAt: t, From: wire.PromptOriginPerson, Preface: preface}, false); err != nil {
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
	q = d.withViewContext(id, q)
	a := d.change(id, func(a *wire.Agent) {
		if first {
			a.QueuedPrompts = append([]wire.QueuedPrompt{q}, a.QueuedPrompts...)
		} else {
			a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), q)
		}
		if q.From == wire.PromptOriginPerson {
			a.Report, a.OutcomeAsked = nil, nil
		}
		// Any message goes now, so the chat no longer waits for its allowance (#1859).
		a.ContinueWhenBack = nil
	})
	if a == nil {
		return &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	d.live(id).kick()
	return nil
}

// hasTurn is whether something in the agent's queue may go now.
func (d *Daemon) hasTurn(a *wire.Agent) bool {
	_, _, ok := nextTurn(a.QueuedPrompts, d.heldMessages(a))
	return ok
}

// kick starts the agent's turns unless they are running, or the host is going.
func (l *live) kick() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running {
		l.running = l.d.goAfterTurn("agent "+string(l.id), l.run)
	}
}

// nextTurn is QueuedPrompt.nextTurn and merging: the run of the person's prompts at the
// head goes as one (#346), since what was typed later so often corrects what came first;
// anything else goes alone. A held message (heldMessage) is passed over, and waits where
// it is, until the person has something in the queue too.
func nextTurn(queue []wire.QueuedPrompt, held map[wire.UUID]bool) (wire.QueuedPrompt, []wire.QueuedPrompt, bool) {
	start := 0
	if !slices.ContainsFunc(queue, func(q wire.QueuedPrompt) bool { return q.From == wire.PromptOriginPerson }) {
		for start < len(queue) && held[queue[start].ID] {
			start++
		}
	}
	if start == len(queue) {
		return wire.QueuedPrompt{}, queue, false
	}
	n := start + 1
	if queue[start].From == wire.PromptOriginPerson {
		for n < len(queue) && queue[n].From == wire.PromptOriginPerson {
			n++
		}
	}
	merged := queue[start]
	var texts, prefaces []string
	merged.Attachments = []wire.Attachment{}
	for _, q := range queue[start:n] {
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
	return merged, append(append([]wire.QueuedPrompt(nil), queue[:start]...), queue[n:]...), true
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
		if a == nil || !l.d.hasTurn(a) {
			l.running = false
			l.mu.Unlock()
			return
		}
		l.mu.Unlock()
		// What is queued waits while the organisation's policy refuses the turn (#998),
		// and while the agent or the day is at its limit.
		if l.d.holdsForPolicy(l) || l.d.holdsForLimit(l.id) {
			l.mu.Lock()
			l.running = false
			l.mu.Unlock()
			return
		}
		drain := false
		if v := safe.Catch("turn of "+string(l.id), func() { drain = l.turn() }); v != nil {
			// The turn's own defers ran; end it so the window does not wait on it.
			l.d.record(l.id, notice("error", "The machine hit a bug", fmt.Sprint(v)))
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
	l.turnSeq++
	l.inTurn, l.prompting, l.stopped, l.reported, l.showedFile = true, false, false, false, false
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
		account, err := d.accountFor(a)
		var launch acp.Launch
		if err == nil {
			launch, err = d.launchOn(rt, dir, account, l.id)
		}
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
		sandbox, why := d.resolveSandbox(a.RuntimeID, a.SandboxOverride, a.StartedByAgent)
		launch, meta := withSandbox(launch, agentSessionMeta(a), a.RuntimeID, sandbox)
		brief := d.briefFor(a)
		compatibilityMeta := withSystemPrompt(meta, a.RuntimeID, brief)
		s, err := acp.Start(ctx, launch, l, d.mcpServersFor(l.id), meta, compatibilityMeta, continuing, brief)
		if err != nil {
			d.dropAppTokens(l.id)
			d.dropStandIn(l.id)
		}
		if err != nil && ctx.Err() != nil {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
			return false
		}
		if err != nil {
			log.Printf("agent %s: %v", l.id, err)
			// Its sandbox first (064): a runtime that fell over because it could not set one up.
			if detail := sandboxMatch(a.RuntimeID, err.Error()); detail != "" {
				d.recordSandboxFailure(l.id, detail, 0)
				d.end(l, wire.AgentStateStopped, wire.EndedReasonSandboxFailed)
				return false
			}
			// A runtime with no sign-in refuses session/new with -32000 (#1430): it is not
			// signed in, not crashed, and the Pool page says so.
			if code, _ := refusal(err); code != nil && *code == authRequired {
				// An added account's sign-in is its own (#840): the runtime's is not in question.
				if account == nil {
					d.markNeedsSignIn(a.RuntimeID)
				}
				d.record(l.id, notice("error", d.credentialName(agentKey(a))+" is not signed in", err.Error()))
				d.end(l, wire.AgentStateStopped, wire.EndedReasonSignInRefused)
				return false
			}
			d.record(l.id, notice("error", rt.Name+" did not start", err.Error()))
			d.end(l, wire.AgentStateStopped, wire.EndedReasonProcessDied)
			return false
		}
		l.mu.Lock()
		l.session = s
		// A conversation begun, or begun again because the runtime lost it: the brief it
		// had lived in the history that is gone.
		l.briefDue = !s.Continued && brief != "" && !s.SupportsSystemPrompt() && compatibilitySystemPromptDelivery[a.RuntimeID] == ""
		l.mu.Unlock()
		// Started as the host goes, after stopAll looked (#1272): it would be left running.
		if d.going() {
			s.Stop()
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
			return false
		}
		d.noteEffectiveSandbox(l.id, sandbox, why)
		// The handshake says the runtime is ready, and what it takes (noteAccount).
		pc := s.Init.AgentCapabilities.PromptCapabilities
		image, audio, embedded := pc.Image, pc.Audio, pc.EmbeddedContext
		d.noteAccount(a.RuntimeID, s.SupportsSteering(), wire.ACPPromptCapabilities{Image: &image, Audio: &audio, EmbeddedContext: &embedded})
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
				a.AdvertisedOptions = d.markOptions(a.RuntimeID, withAppOptions(a.RuntimeID, a.StartOptions.Values, opts))
				a.Levels = d.matchLevels(a)
			}
		})
		safe.Go("session watch", func() {
			<-s.Done()
			l.mu.Lock()
			ours := l.session == s
			if ours {
				l.session = nil
				// Before the next runtime can start, so its stand-in is a new one.
				d.dropStandIn(l.id)
			}
			l.mu.Unlock()
			// A new process is a new MCP server, with a token of its own.
			if ours {
				d.dropAppTokens(l.id)
			}
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
		// The policy again, now the runtime has said its options: an agent with no model
		// or mode chosen runs on the runtime's own, which the check before it started
		// could not see. A refused one waits, as at the start of a turn.
		if d.holdsForPolicy(l) {
			return false
		}
	}
	// The words, off the queue now the runtime is there to take them.
	var q wire.QueuedPrompt
	taken := false
	held := map[wire.UUID]bool{}
	if a := d.Store.Agent(l.id); a != nil {
		held = d.heldMessages(a)
	}
	d.change(l.id, func(a *wire.Agent) { q, a.QueuedPrompts, taken = nextTurn(a.QueuedPrompts, held) })
	if !taken {
		return false
	}
	d.change(l.id, func(a *wire.Agent) {
		if a.PendingSandboxFailure != nil {
			a.PendingSandboxFailure = nil
		}
	})
	bs := blocks(q)
	from := q.From
	if from == "" {
		from = wire.PromptOriginPerson
	}
	um := &wire.TranscriptEntryKindUserMessage{Value: q.Text, From: &from}
	if len(bs) > 1 {
		um.Blocks = bs
	}
	// A prompt sent again after a rate limit is in the conversation already.
	l.mu.Lock()
	resent := l.resend == q.ID
	l.resend = ""
	sent := q
	l.lastSent = &sent
	l.mu.Unlock()
	// A branch's first prompt carries the record it was branched with (#1658), read here
	// as it goes rather than kept on the queued prompt, which every client is sent on each
	// change (#1851); before the prompt is recorded, so the record is the one it went on from.
	branch := d.branchPreface(a)
	if !resent {
		d.recordFrom(l.id, wire.TranscriptEntryKind{UserMessage: um}, q.Sender)
	}
	// What was suggested has been answered, taken or typed past; only by the person.
	if from == wire.PromptOriginPerson {
		d.change(l.id, func(a *wire.Agent) {
			if len(a.SuggestedPrompts) > 0 {
				a.SuggestedPrompts = nil
			}
		})
	}
	l.mu.Lock()
	l.lastMessageID = ""
	l.lastMessage.Reset()
	clear(l.toolCalls)
	l.evidence = turnEvidence{}
	l.failure = nil
	l.mu.Unlock()
	// Archived or stopped while it got ready (#1611): its context is gone, and the state
	// is left as the stop wrote it.
	if ctx.Err() != nil {
		d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
		return false
	}
	l.forgetTools()
	d.moveState(l.id, wire.AgentStateRunning, true)
	// What the person changed on a live page since this agent's last turn (022 FR-016),
	// whoever sent the prompt, told once: the edit itself is in the file.
	if note := d.pageEdits.take(l.id); note != "" {
		bs = append([]wire.ContentBlock{textBlock(note)}, bs...)
	}
	if q.Preface != nil {
		bs = append([]wire.ContentBlock{textBlock(*q.Preface)}, bs...)
	}
	if branch != nil {
		bs = append([]wire.ContentBlock{textBlock(*branch)}, bs...)
	}
	// The brief first of all (#763), once per conversation: our words before the person's,
	// so theirs are the last thing the agent reads.
	l.mu.Lock()
	due := l.briefDue
	l.mu.Unlock()
	brief := ""
	if a := d.Store.Agent(l.id); due && a != nil {
		brief = d.briefFor(a)
	}
	l.mu.Lock()
	s, stopped := l.session, l.stopped
	if brief != "" && !stopped && s != nil {
		l.briefDue = false
		bs = append([]wire.ContentBlock{textBlock(brief)}, bs...)
	}
	l.prompting = !stopped && s != nil
	l.mu.Unlock()
	if stopped {
		d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
		return false
	}
	// The runtime went since it started (#1619): a stop, the host's going or an exit of its
	// own, not a bug of the host's, so the host's going says it was cut off.
	if s == nil {
		if ctx.Err() != nil {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
		} else {
			d.record(l.id, notice("error", "The turn failed", "The runtime ended before it took the prompt."))
			d.end(l, wire.AgentStateStopped, wire.EndedReasonProcessDied)
		}
		return false
	}
	r, err := s.Prompt(ctx, acpBlocks(bs))
	// The turn is over: what a message chunk held back goes now (#1001).
	l.flushHeld()
	if err != nil {
		if ctx.Err() != nil {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonCancelled)
			return false
		}
		log.Printf("agent %s: prompt: %v", l.id, err)
		l.closeForms(false)
		if detail := l.sandboxFailure(err.Error()); detail != "" {
			d.end(l, wire.AgentStateStopped, wire.EndedReasonSandboxFailed)
			return false
		}
		// What the refusal says about the runtime's allowance (052).
		if code, msg := refusal(err); code != nil {
			l.mu.Lock()
			window := l.rateLimit
			l.mu.Unlock()
			if why, ok, retryAt := d.applyLimit(l, classifyLimit(a.RuntimeID, nil, window, code, msg, ""), false); ok {
				d.end(l, wire.AgentStateStopped, why)
				if !retryAt.IsZero() {
					l.retryLater(retryAt)
				}
				return false
			}
		}
		// An added account with no sign-in in its folder (#840): said as that, with where to fix it.
		if code, _ := refusal(err); code != nil && *code == authRequired && a.AccountID != nil {
			d.record(l.id, notice("error", d.credentialName(agentKey(a))+" is not signed in",
				"Sign it in from "+runtimeName(a.RuntimeID)+"’s sign-in sheet on the Mac, under Accounts."))
			d.end(l, wire.AgentStateStopped, wire.EndedReasonSignInRefused)
			return false
		}
		d.record(l.id, notice("error", "The turn failed", err.Error()))
		select {
		case <-s.Done():
			d.end(l, wire.AgentStateStopped, wire.EndedReasonProcessDied)
		default:
			d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
		}
		return true
	}
	// On an org account, the relay's count of the provider's answers goes beside what the
	// runtime says (#999, FR-019), also from a runtime that says nothing.
	relayed, route := d.takeRelayTokens(l.id)
	if r.Usage != nil || relayed != nil {
		u := wire.TurnUsage{}
		if r.Usage != nil {
			u = wire.TurnUsage{TotalTokens: int64(r.Usage.TotalTokens), InputTokens: int64(r.Usage.InputTokens), OutputTokens: int64(r.Usage.OutputTokens)}
			optional := func(n *int) *int64 {
				if n == nil {
					return nil
				}
				v := int64(*n)
				return &v
			}
			u.ThoughtTokens, u.CachedReadTokens, u.CachedWriteTokens = optional(r.Usage.ThoughtTokens), optional(r.Usage.CachedReadTokens), optional(r.Usage.CachedWriteTokens)
		}
		if relayed != nil {
			u.RelayTokens = relayed
			if route != "" {
				u.Route = &route
			}
		}
		d.record(l.id, wire.TranscriptEntryKind{UsageRecorded: &wire.TranscriptEntryKindUsageRecorded{Value: u}})
		// The turn's tokens on the agent, the day and the charts (finishTurn's banking).
		d.bankTurnUsage(l.id, u)
	}
	// What the ending says about the runtime's allowance (052): its typed failure, on the
	// answer or on an update during the turn, paid overage begun, or a refusal said in
	// words in a turn ended as usual.
	l.mu.Lock()
	failure, window, said := l.failure, l.rateLimit, l.lastMessage.String()
	l.mu.Unlock()
	failure = failure.supersededBy(failureIn(r.Meta))
	if r.StopReason != sdk.StopReasonEndTurn {
		said = ""
	}
	// A warning is a retry the runtime is making: said, and the turn's own ending stands.
	// An error is said too, and the turn failed whatever its stop reason.
	failed := failure != nil && failure.isError()
	if failure != nil {
		d.noteFailure(l.id, a.RuntimeID, failure)
	}
	lim := classifyLimit(a.RuntimeID, failure, window, nil, "", said)
	worked := r.StopReason == sdk.StopReasonEndTurn && !failed
	if why, ok, retryAt := d.applyLimit(l, lim, worked); ok {
		d.end(l, wire.AgentStateStopped, why)
		if !retryAt.IsZero() {
			l.retryLater(retryAt)
		}
		return false
	}
	if failed {
		d.end(l, wire.AgentStateStopped, wire.EndedReasonRuntimeError)
		return true
	}
	if worked && lim.kind == limitNone {
		d.allowanceWorked(l, agentKey(a))
	}
	// A command whose sandbox could not be set up: the turn ran to its end, and the agent
	// stops there with the card. Never once it said how it went itself (#224).
	if r.StopReason == sdk.StopReasonEndTurn && l.sandboxFailure("") != "" {
		d.end(l, wire.AgentStateStopped, wire.EndedReasonSandboxFailed)
		return false
	}
	// A turn that took the agent to its limit stops it there, the turn finished first.
	if r.StopReason == sdk.StopReasonEndTurn {
		if a := d.Store.Agent(l.id); a != nil {
			if note := d.crossedLimit(a); note != "" {
				d.raiseCostLimit("agent", a)
				d.record(l.id, runtimeNote(note))
				d.end(l, wire.AgentStateStopped, wire.EndedReasonCostLimit)
				return false
			}
		}
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

// setState moves a running agent's state, clearing an ending and a report it had. A card
// answered mid-turn (waiting on the person, then running again) keeps the turn's report:
// a block reported before the card is still how the turn ends (#1432).
func (d *Daemon) setState(id wire.UUID, s wire.AgentState) {
	d.moveState(id, s, false)
}

// moveState is setState; only a turn's words sent to an archived agent take it out of the
// archive (unarchive): a card or an answer in a turn its archive cut off leaves it there
// (#1611).
func (d *Daemon) moveState(id wire.UUID, s wire.AgentState, fromArchive bool) {
	changed, started := false, false
	d.change(id, func(a *wire.Agent) {
		if a.State == s || a.State == wire.AgentStateArchived && !fromArchive {
			return
		}
		changed, started = true, a.State == wire.AgentStateStarting && s == wire.AgentStateRunning
		answered := a.State == wire.AgentStateWaitingOnUser
		a.State = s
		a.EndedReason = nil
		a.ArchivedReason = nil
		if s == wire.AgentStateRunning && !answered {
			a.Report = nil
			a.RunningTool = nil // a new turn begins thinking (#1902)
		}
	})
	if changed {
		d.record(id, stateChanged(s, nil))
	}
	// Its first turn has begun (042).
	if started {
		d.raiseAgentEvent("agent.started", id, "started working.", nil)
	}
}

// end closes a turn: the state, its reason, and for a finished turn a report derived
// from the agent's last words (DaemonCore+DerivedEnding): needs_answer when it ends on a
// question, done with its first sentence otherwise.
func (d *Daemon) end(l *live, s wire.AgentState, why wire.EndedReason) {
	l.mu.Lock()
	last, reported, showedFile := l.lastMessage.String(), l.reported, l.showedFile
	l.mu.Unlock()
	// The report says the last message as the transcript does: whole, so a token in it,
	// or split across its chunks, is cut out (#1001).
	last = redact.Text(last)
	// A turn its archive cut off (#1611): the session stays archived, and the ending is not
	// said, as a stop or a crash, nor picked up after a restart.
	if a := d.Store.Agent(l.id); a != nil && a.State == wire.AgentStateArchived {
		l.forgetTools()
		d.workflowRunFinished(l.id)
		d.guardedTurnEnded(l.id)
		d.checkQueueSoon(folderPath(a))
		d.agentEnded(l.id)
		return
	}
	// A turn the host's going cut off is the daemon's going, not a stop somebody chose
	// (#1605): the next start picks it up, as after a crash.
	if d.going() && s == wire.AgentStateStopped && (why == wire.EndedReasonCancelled || why == wire.EndedReasonProcessDied) {
		why = wire.EndedReasonDaemonGone
		if a := d.Store.Agent(l.id); a != nil {
			d.noteCutOff(l.id, a.State)
		}
	}
	// An admin's stop from the Console (#2435) says so to the owner, not "Stopped by you".
	if adminStopped := d.takeAdminStop(l.id); adminStopped && s == wire.AgentStateStopped && why == wire.EndedReasonCancelled {
		why = wire.EndedReasonStoppedByAdmin
	}
	var requested, archiveNow bool
	l.forgetTools()
	d.change(l.id, func(a *wire.Agent) {
		a.State, a.EndedReason, a.RunningTool = s, reason(why), nil
		if why != wire.EndedReasonDaemonGone {
			a.RestartPickUps = nil // any ending but the daemon's going clears the count
		}
		unread := s == wire.AgentStateFinished
		a.IsUnread = &unread
		if s == wire.AgentStateFinished && !(reported && a.Report != nil) {
			outcome, message := wire.WorkOutcomeDone, firstSentence(last)
			if strings.HasSuffix(strings.TrimSpace(last), "?") {
				outcome = wire.WorkOutcomeNeedsAnswer
			}
			if message == "" {
				message = "Finished."
			}
			a.Report = &wire.WorkReport{Outcome: outcome, Message: message, At: now()}
		}
		requested, archiveNow = d.settleArchiveRequest(a, s, why, showedFile)
	})
	d.record(l.id, stateChanged(s, reason(why)))
	// A move asked for in this turn is made now, before the ending is heard and before an
	// archive, so the worktree left is removed either way (053).
	// An agent that moved itself and goes on in the new folder has not finished (#1955):
	// no agent.finished, its workflow run goes on, and those waiting on it wait on.
	goesOn := d.afterTurnMove(l.id, s, requested || archiveNow)
	// The event after the record (042): what a waiting agent hears and what the log keeps.
	if !goesOn {
		d.raiseAgentEnding(l.id, s, reason(why), archiveNow)
		d.workflowRunFinished(l.id)
	}
	d.afterArchiveRequest(l.id, requested, archiveNow)
	// What the turn did to the app's own files is looked at as it ends (guardedTurnEnded).
	d.guardedTurnEnded(l.id)
	// A place may have come free for a queued helper, and those waiting on it may go on.
	if a := d.Store.Agent(l.id); a != nil {
		d.checkQueueSoon(folderPath(a))
	}
	if goesOn {
		return
	}
	d.agentEnded(l.id)
	if s == wire.AgentStateFinished {
		d.scoreAssessmentIfDue(l.id)
	}
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
	// What a message chunk held back goes before any other update (#1001).
	if u.AgentMessageChunk == nil {
		l.flushHeld()
	}
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
		l.evidence.takeReply(text)
		l.mu.Unlock()
		// The end that could start a token waits for the next chunk (#1001).
		earlier, now := l.holdChunk(id, text)
		if earlier != nil {
			d.record(l.id, wire.TranscriptEntryKind{AgentMessage: earlier})
		}
		if now != "" {
			d.record(l.id, wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: id, Text: now}})
		}
	case u.ToolCall != nil:
		call := toolCall(u.ToolCall)
		d.record(l.id, wire.TranscriptEntryKind{ToolCall: &wire.TranscriptEntryKindToolCall{Value: call}})
		d.noteAgentViewCall(l.id, call)
		l.mu.Lock()
		l.evidence.takeCall(call)
		l.lastMessageID, l.lastMessage = "", strings.Builder{}
		l.toolCalls[string(u.ToolCall.ToolCallId)] = true
		l.seen.Broadcast()
		l.mu.Unlock()
		l.noteToolCall(call, true)
	case u.ToolCallUpdate != nil:
		call := toolCall(u.ToolCallUpdate)
		d.record(l.id, wire.TranscriptEntryKind{ToolCallUpdate: &wire.TranscriptEntryKindToolCallUpdate{Value: call}})
		d.noteAgentViewCall(l.id, call)
		l.mu.Lock()
		l.evidence.takeCall(call)
		l.mu.Unlock()
		l.noteToolCall(call, false)
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
		d.change(l.id, func(a *wire.Agent) {
			id := "mode"
			if o := modeOption(a.AdvertisedOptions); o != nil {
				id = o.ID
			}
			keepMode(a, id, v)
		})
		d.record(l.id, wire.TranscriptEntryKind{OptionChanged: &wire.TranscriptEntryKindOptionChanged{ID: "mode", Value: v}})
	case u.ConfigOptionUpdate != nil:
		if opts := configOptions(u.ConfigOptionUpdate.ConfigOptions); opts != nil {
			d.change(l.id, func(a *wire.Agent) {
				was, now := modeOption(a.AdvertisedOptions), modeOption(opts)
				if was != nil && now != nil && was.ID == now.ID && len(now.CurrentValue) > 0 && !bytes.Equal(was.CurrentValue, now.CurrentValue) {
					keepMode(a, now.ID, now.CurrentValue)
				}
				a.AdvertisedOptions = d.markOptions(a.RuntimeID, withAppOptions(a.RuntimeID, a.StartOptions.Values, opts))
				a.Levels = d.matchLevels(a)
			})
		}
	case u.AvailableCommandsUpdate != nil:
		b, _ := json.Marshal(u.AvailableCommandsUpdate.AvailableCommands)
		var cmds []wire.SlashCommand
		if json.Unmarshal(b, &cmds) == nil && cmds != nil {
			d.change(l.id, func(a *wire.Agent) { a.AvailableCommands = cmds })
		}
	case u.UsageUpdate != nil:
		// The context window and, where the runtime prices it, the session's cost so far;
		// Claude's plan window beside them.
		uu := u.UsageUpdate
		if w := rateLimitIn(uu.Meta); w != nil {
			if a := d.Store.Agent(l.id); a != nil {
				d.notePlanWindow(l, agentKey(a), w)
			}
		}
		usage := wire.Usage{Used: int64(uu.Used), Size: int64(uu.Size), At: now()}
		if uu.Cost != nil && uu.Cost.Amount != 0 && uu.Cost.Currency != "" {
			usage.Cost = &wire.Cost{Amount: uu.Cost.Amount, Currency: uu.Cost.Currency}
		}
		d.change(l.id, func(a *wire.Agent) { a.Usage = &usage })
		if usage.Cost != nil {
			d.bankSessionCost(l.id, *usage.Cost)
		}
	case u.SessionInfoUpdate != nil:
		// A typed failure (052): the turn's, kept for its end; between turns, said.
		if f := failureIn(u.SessionInfoUpdate.Meta); f != nil {
			l.mu.Lock()
			inTurn := l.inTurn
			if inTurn {
				l.failure = l.failure.supersededBy(f)
			}
			l.mu.Unlock()
			if a := d.Store.Agent(l.id); !inTurn && a != nil {
				d.noteFailure(l.id, a.RuntimeID, f)
			}
		}
		// The goal it keeps working towards (#2742), drawn as a card over the plan's.
		if g, said := goalIn(u.SessionInfoUpdate.Meta, now()); said {
			d.change(l.id, func(a *wire.Agent) { a.Goal = g })
		}
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
	// On a bot's machine the policy alone answers (#1761, FR-032): what it did not allow
	// already is refused, and the agent carries on.
	if d.isBot() {
		return l.refuseForBot(req)
	}
	// Always-approve answers before a card, for Cursor, Grok and OpenCode (061). A request
	// with no allow option still waits for the person.
	if a := d.Store.Agent(l.id); a != nil && d.agentAlwaysApproves(a) {
		for _, kind := range []wire.PermissionOptionKind{wire.PermissionOptionKindAllowOnce, wire.PermissionOptionKindAllowAlways} {
			for _, o := range req.Options {
				if o.Kind == kind {
					return o.OptionID
				}
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
	d.raiseAgentEvent("agent.asked_permission", l.id, "is asking for permission.", nil)
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

// refuseForBot answers a permission on a bot's machine: its reject option, said in the
// transcript; "" (the turn's own refusal) when it offers none.
func (l *live) refuseForBot(req wire.PermissionRequest) string {
	option := ""
	for _, kind := range []wire.PermissionOptionKind{"reject_once", "reject_always"} {
		for _, o := range req.Options {
			if o.Kind == kind && option == "" {
				option = o.OptionID
			}
		}
	}
	l.d.record(l.id, wire.TranscriptEntryKind{PermissionAsked: &wire.TranscriptEntryKindPermissionAsked{Value: req}})
	name := noOneAnswersWords
	l.d.record(l.id, wire.TranscriptEntryKind{PermissionAnswered: &wire.TranscriptEntryKindPermissionAnswered{OptionID: option, OptionName: &name}})
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
	l.closeForms(false)
	l.mu.Lock()
	l.stops++
	s, stop, seq := l.session, l.stop, l.turnSeq
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
		} else if stop != nil {
			go l.cancelAgain(s, seq, stop)
		}
	} else if stop != nil {
		stop()
	}
}

// halt ends the turn and the runtime for the daemon's own reasons (an archive, a delete):
// the turn's context goes first, so the turn ends cancelled and the runtime's exit is not
// taken for a crash (#1611).
func (l *live) halt() {
	l.cancel()
	l.closeForms(true)
	l.mu.Lock()
	s, stop := l.session, l.stop
	l.session = nil
	l.mu.Unlock()
	if stop != nil {
		stop()
	}
	if s != nil {
		s.Stop()
	}
}

// cancelAgain sends session/cancel again while the same turn goes on, then ends it from
// this side: a cancel that reaches the runtime before its prompt is under way finds no
// turn to end, and the turn would wait for ever (#1296).
func (l *live) cancelAgain(s *acp.Session, seq int, stop context.CancelFunc) {
	still := func() bool {
		l.mu.Lock()
		defer l.mu.Unlock()
		return l.inTurn && l.turnSeq == seq
	}
	for range 3 {
		select {
		case <-l.d.ctx.Done():
			return
		case <-time.After(cancelAgainAfter):
		}
		if !still() {
			return
		}
		ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		err := s.Cancel(ctx)
		c()
		if err != nil {
			break
		}
	}
	if still() {
		stop()
	}
}

// cancelAgainAfter is how long a cancelled turn has to end before session/cancel goes again.
var cancelAgainAfter = time.Second

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
		s, stop := l.session, l.stop
		l.mu.Unlock()
		// A turn still starting its runtime has no session yet: its context ends it.
		if stop != nil {
			stop()
		}
		if s != nil {
			s.Stop()
		}
	}
}

// keepMode is the runtime moving itself to another mode (Claude leaving plan mode): the
// agent's mode now, as the Swift host kept it, so that the checks that read it
// (inheritedMode, looserThan) see the mode it runs in, not the one it started in.
func keepMode(a *wire.Agent, id string, v wire.JSONValue) {
	values := make(map[string]wire.JSONValue, len(a.StartOptions.Values)+1)
	for k, old := range a.StartOptions.Values {
		values[k] = old
	}
	values[id] = v
	a.StartOptions.Values = values
	opts := append([]wire.ConfigOption(nil), a.AdvertisedOptions...)
	for i := range opts {
		if opts[i].ID == id {
			opts[i].CurrentValue = v
		}
	}
	a.AdvertisedOptions = opts
}
