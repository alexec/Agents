package agentsd

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// start_session and the helper queue (#362), as DaemonCore+Helpers and +HelperQueue answer
// them on the Swift host: an agent starts a session in its own folder, within the
// folder's helper limits; past them, or behind others already waiting, it queues, first
// in first out, and starts by itself once a running place and a not-archived place are
// both free.

const defaultRuntimeID = "claude"

type helperQueueState struct {
	queueMu           sync.Mutex
	startingFromQueue map[wire.UUID]bool // queued agents being started now
	reservedHelpers   map[string]int     // by folder: starts decided and not yet on the record
}

// modeRanks is ModeLooseness: how much each mode lets an agent do without asking.
var modeRanks = map[string]int{"plan": 0, "ask": 0, "default": 1, "read-only": 1, "acceptEdits": 2, "agent": 2, "auto": 3,
	"bypassPermissions": 4, "autopilot": 4, "agent-full-access": 4}

func modeRank(m string) (int, bool) {
	if i := strings.LastIndex(m, "#"); i >= 0 {
		m = m[i+1:]
	}
	r, ok := modeRanks[m]
	return r, ok
}

func noLooser(wanted, limit string) bool {
	if wanted == limit {
		return true
	}
	w, ok1 := modeRank(wanted)
	l, ok2 := modeRank(limit)
	return ok1 && ok2 && w <= l
}

// inheritedMode is the caller's own mode, when the helper runs on its runtime.
func inheritedMode(caller *wire.Agent, runtime string) *string {
	if runtime == "" {
		runtime = defaultRuntimeID
	}
	if runtime != caller.RuntimeID {
		return nil
	}
	o := modeOption(caller.AdvertisedOptions)
	if o == nil {
		return nil
	}
	v, ok := caller.StartOptions.Values[o.ID]
	if !ok {
		v = o.CurrentValue
	}
	var s string
	if json.Unmarshal(v, &s) != nil || s == "" {
		return nil
	}
	return &s
}

// looserThan is how the target may do more without asking than the caller, or "": a mode
// looser than the caller's, or its sandbox not on while the caller's is. A message from the
// caller then waits for the person, as start_session gives a helper no looser a mode.
func (d *Daemon) looserThan(target, caller *wire.Agent) string {
	theirs, own := inheritedMode(target, target.RuntimeID), inheritedMode(caller, caller.RuntimeID)
	switch {
	case theirs == nil && own == nil:
	case theirs == nil:
		return "it runs in its runtime's own mode, which may let it do more without asking than yours (" + *own + ")"
	case own == nil:
		return "it runs in " + *theirs + ", and you in your runtime's own mode"
	case !noLooser(*theirs, *own):
		return "it runs in " + *theirs + ", which lets it do more without asking than yours (" + *own + ")"
	}
	on := func(a *wire.Agent) bool {
		return a.EffectiveSandbox != nil && a.EffectiveSandbox.State == wire.SandboxStateOn
	}
	if on(caller) && !on(target) {
		return "its command sandbox is not on, and yours is"
	}
	return ""
}

// reportsTo is whether the target set the sender going: it started the sender, or ran the
// workflow the sender belongs to. The sender's messages then go to it at once, whatever its
// mode, as the work it asked for comes back (#1728).
func (d *Daemon) reportsTo(sender, target *wire.Agent) bool {
	if sender.StartedByAgent != nil && *sender.StartedByAgent == target.ID {
		return true
	}
	ran := d.ranBy(sender)
	return ran != nil && *ran == target.ID
}

// holdsMessageFrom is why a message from the sender waits for the person in the target's
// chat, or "": the target is looser than the sender (looserThan), and did not set it going.
func (d *Daemon) holdsMessageFrom(target, sender *wire.Agent) string {
	if d.reportsTo(sender, target) {
		return ""
	}
	return d.looserThan(target, sender)
}

// heldMessage is whether a message from another session waits in the target's queue
// until the person speaks to it: its sender is gone, or the target holds its messages.
func (d *Daemon) heldMessage(q wire.QueuedPrompt, target *wire.Agent) bool {
	if q.From != wire.PromptOriginAgent {
		return false
	}
	if q.Sender == nil {
		return true
	}
	sender := d.Store.Agent(q.Sender.AgentID)
	return sender == nil || d.holdsMessageFrom(target, sender) != ""
}

// heldMessages is the ids of the messages in the agent's queue that wait for the person.
func (d *Daemon) heldMessages(a *wire.Agent) map[wire.UUID]bool {
	held := map[wire.UUID]bool{}
	for _, q := range a.QueuedPrompts {
		if d.heldMessage(q, a) {
			held[q.ID] = true
		}
	}
	return held
}

func (d *Daemon) unavailableRuntime(rt *runtimeDef) string {
	if p, _, _ := locateFor(rt); p == "" {
		return rt.Name + " is not installed on this machine"
	}
	if err := d.needsSignIn(rt.ID); err != nil {
		if e, ok := err.(*Error); ok {
			return strings.TrimSuffix(e.Message, ".")
		}
		return err.Error()
	}
	return ""
}

func knownRuntimes() string {
	var ids []string
	for _, r := range catalog {
		ids = append(ids, r.ID)
	}
	return strings.Join(ids, ", ")
}

// helperWorktree is where a helper is to work: a new worktree, one there is, or a branch.
func (d *Daemon) helperWorktree(written, folder string) (*wire.WorktreeChoice, error) {
	written = strings.TrimSpace(written)
	if written == "" {
		return nil, nil
	}
	if strings.EqualFold(written, "new") {
		return &wire.WorktreeChoice{New: &struct{}{}}, nil
	}
	if _, ok := repositoryOf(folder); !ok {
		return nil, &Error{Code: wire.FailureNotAWorktree, Message: "this folder is not a git repository, so it has no worktrees"}
	}
	list, _ := worktreeList(folder)
	var names []string
	for _, w := range list {
		if canonical(w.root) == canonical(folder) {
			continue
		}
		name := filepathBase(w.root)
		if name == written || w.branch == written {
			return &wire.WorktreeChoice{Existing: &wire.WorktreeChoiceExisting{Value: store.FolderURL(w.root)}}, nil
		}
		names = append(names, name)
	}
	if _, err := git(folder, "rev-parse", "--verify", "--quiet", "refs/heads/"+written); err == nil {
		return &wire.WorktreeChoice{Branch: &wire.WorktreeChoiceBranch{Value: written}}, nil
	}
	if len(names) == 0 {
		return nil, &Error{Code: wire.FailureNotAWorktree, Message: `there is no worktree called "` + written + `" here. There are none yet; say "new" to make one.`}
	}
	return nil, &Error{Code: wire.FailureNotAWorktree, Message: `there is no worktree called "` + written + `" here. There are: ` +
		strings.Join(names, ", ") + `, or say "new".`}
}

func filepathBase(p string) string {
	p = strings.TrimSuffix(p, "/")
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[i+1:]
	}
	return p
}

func errMessage(err error) (int, string) {
	if e, ok := err.(*Error); ok {
		return e.Code, e.Message
	}
	return CodeInternal, err.Error()
}

// helperLimitRefusal is why the folder has no place for another helper now, or "".
func (d *Daemon) helperLimitRefusal(folder string) string {
	running, notArchived, _ := d.helperLimitsIn(folder)
	d.queueMu.Lock()
	reserved := d.reservedHelpers[folder]
	d.queueMu.Unlock()
	quotedList := func(as []wire.Agent) string {
		if len(as) == 0 {
			return ""
		}
		var names []string
		for _, a := range as {
			names = append(names, quotedTitle(a.Title))
		}
		return " — " + strings.Join(names, ", ")
	}
	starting := ""
	if reserved > 0 {
		starting = fmt.Sprintf(" (%d still starting)", reserved)
	}
	var full []string
	kept := d.helpersIn(folder)
	if int64(len(kept)+reserved) >= notArchived {
		then := "Only the person can archive one to free that place."
		if d.agentsMayArchive(folder) {
			then = "Archive one of yours with archive_session once its work is merged or abandoned, or let the person approve archiving one, to free that place."
		}
		full = append(full, fmt.Sprintf("this folder already has %d of %d sessions started by sessions not yet archived%s%s. %s",
			len(kept)+reserved, notArchived, quotedList(kept), starting, then))
	}
	r := d.runningHelpers(folder)
	if int64(len(r)+reserved) >= running {
		full = append(full, fmt.Sprintf("this folder already has %d of %d sessions started by sessions running%s%s. "+
			"Archive or stop one of yours with archive_session or stop_session when its part is done, or wait for one to finish.",
			len(r)+reserved, running, quotedList(r), starting))
	}
	return strings.Join(full, " And ")
}

// startSession is start_session.
func (d *Daemon) startSession(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	me := d.Store.Agent(caller)
	if me == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	prompt := strings.TrimSpace(argString(args, "prompt"))
	if prompt == "" {
		return "", Invalid("Nothing was started: say what the agent is to do.")
	}
	runtimeID := strings.TrimSpace(argString(args, "runtime"))
	if runtimeID == "" {
		runtimeID = me.RuntimeID
		// A helper of an Auto agent is on Auto too, and Auto picks again (FR-012).
		if me.Auto != nil {
			runtimeID = autoRuntimeID
		}
	}
	model := strings.TrimSpace(argString(args, "model"))
	labels, err := stringList(args, "labels")
	if err != nil {
		return "", err
	}
	mode := inheritedMode(me, runtimeID)
	if runtimeID == autoRuntimeID {
		return d.startAutoHelper(me, args, prompt, model, labels)
	}
	if wanted := strings.TrimSpace(argString(args, "permission_mode")); wanted != "" {
		own := inheritedMode(me, me.RuntimeID)
		if own == nil || !noLooser(wanted, *own) {
			ownWords := "your runtime's own mode"
			if own != nil {
				ownWords = *own
			}
			return "", Invalid("Nothing was started: %s would let it do more without asking than you may (%s). Name no mode and it takes yours.", wanted, ownWords)
		}
		mode = &wanted
	}
	rt := runtimeByID(runtimeID)
	if rt == nil {
		return "", Invalid("Nothing was started: there is no runtime called \"%s\" — this version knows %s.", runtimeID, knownRuntimes())
	}
	if why := d.unavailableRuntime(rt); why != "" {
		return "", Invalid("Nothing was started: %s.", why)
	}
	folder := folderPath(me)
	worktree, err := d.helperWorktree(argString(args, "worktree"), folder)
	if err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: "Nothing was started: " + msg}
	}
	if full := d.helperLimitRefusal(folder); full != "" || len(d.helperQueue(folder)) > 0 {
		return d.queueHelper(me, prompt, runtimeID, model, mode, worktree, labels, full)
	}
	d.queueMu.Lock()
	if d.reservedHelpers == nil {
		d.reservedHelpers = map[string]int{}
	}
	d.reservedHelpers[folder]++
	d.queueMu.Unlock()
	defer func() {
		d.queueMu.Lock()
		d.reservedHelpers[folder]--
		d.queueMu.Unlock()
	}()
	id, err := d.startFor(helperRequest(runtimeID, folder, prompt, model, mode, worktree, labels), startedBy{agent: &caller, owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: "Nothing was started: " + msg}
	}
	a := d.Store.Agent(id)
	note := fmt.Sprintf("Started %s (id %s). This folder now has %s.", quotedTitle(a.Title), id, d.helperPlaces(folder))
	if w := a.Worktree; w != nil {
		note += " It is working in worktree " + w.Name
		if w.Branch != nil {
			note += " on " + *w.Branch + "."
		} else {
			note += "."
		}
	}
	return note, nil
}

func helperRequest(runtimeID, folder, prompt, model string, mode *string, worktree *wire.WorktreeChoice, labels []string) wire.StartRequest {
	values := map[string]wire.JSONValue{}
	// On Auto the model and mode are the shared words (#2658); on a named runtime they are its
	// own, and a workflow has made its words levels already (runAgent).
	var levels *wire.Levels
	if runtimeID == autoRuntimeID {
		levels, model, mode, _, _ = fileLevels(runtimeID, model, mode, "", "")
	}
	if mode != nil {
		values["mode"], _ = json.Marshal(*mode)
	}
	if model != "" {
		values["model"], _ = json.Marshal(model)
	}
	if labels == nil {
		labels = []string{}
	}
	return wire.StartRequest{RuntimeID: runtimeID, Cwd: store.FolderURL(folder), Prompt: prompt, Attachments: []wire.Attachment{},
		StartOptions: wire.StartOptions{Values: values, ExtraArguments: []string{}}, AdditionalDirectories: []wire.URL{},
		McpServers: []wire.MCPServer{}, Worktree: worktree, Labels: labels, Levels: levels}
}

// queueHelper is queueHelper: a queued record, started by itself when there is a place.
func (d *Daemon) queueHelper(caller *wire.Agent, prompt, runtimeID, model string, mode *string, worktree *wire.WorktreeChoice,
	labels []string, full string) (string, error) {
	folder := folderPath(caller)
	queue := d.helperQueue(folder)
	_, _, limit := d.helperLimitsIn(folder)
	if int64(len(queue)) >= limit {
		names := ""
		if len(queue) > 0 {
			var each []string
			for _, a := range queue {
				each = append(each, quotedTitle(a.Title))
			}
			names = " — " + strings.Join(each, ", ")
		}
		behind := "This folder's"
		if full != "" {
			behind = full + " And its"
		}
		return "", &Error{Code: wire.FailureNotYours, Message: fmt.Sprintf("Nothing was started: %s queue is full too: %d of %d sessions queued%s. "+
			"Stop one of yours that is queued with stop_session if it is no longer wanted, or wait for the queue to move. "+
			"The person sets these limits in Folder Settings.", behind, len(queue), limit, names)}
	}
	given, err := changeLabelsAs(wire.SessionLabelOwnerAgent, nil, labels, nil, vocabulary(folder, d.Store.Agents()))
	if err != nil {
		_, msg := errMessage(err)
		return "", Invalid("Nothing was started: %s", msg)
	}
	t := now()
	title := titleFrom(prompt)
	rt := runtimeID
	a := wire.Agent{ID: store.NewUUID(), RuntimeID: runtimeID, Cwd: store.FolderURL(folder), State: wire.AgentStateQueued,
		AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
		StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}},
		CreatedAt:    t, LastActivityAt: t, MadeInRoot: &d.Store.RootID, StartedByAgent: &caller.ID, Labels: given,
		QueuedPrompts: []wire.QueuedPrompt{{ID: store.NewUUID(), Text: prompt, Attachments: []wire.Attachment{}, QueuedAt: t, From: wire.PromptOriginPerson}},
		QueuedStart:   &wire.QueuedStart{RuntimeID: &rt, PermissionMode: mode, Worktree: worktree, Labels: labels}}
	if model != "" {
		a.QueuedStart.Model = &model
	}
	if a.QueuedStart.Labels == nil {
		a.QueuedStart.Labels = []string{}
	}
	if title != "" {
		a.Title = &title
	}
	if err := d.Store.Save(a); err != nil {
		return "", &Error{Code: wire.FailureCouldNotSave, Message: "Nothing was started: the queued agent could not be saved: " + err.Error()}
	}
	d.tellChanged(a, nil)
	d.folderChanged(folder)
	d.record(a.ID, runtimeNote("Queued by "+d.holderName(caller.ID)+". It starts by itself when this folder has a place free."))
	position := len(queue) + 1
	for i, q := range d.helperQueue(folder) {
		if q.ID == a.ID {
			position = i + 1
		}
	}
	ahead := "Others are queued ahead of it. "
	if full != "" {
		ahead = strings.ToUpper(full[:1]) + full[1:] + " "
	}
	note := fmt.Sprintf("Queued %s (id %s), %s in this folder's queue: %sIt starts by itself, oldest first, once a running place and a "+
		"not-archived place are both free. Wait for it with wait_for_agents as for any session, or take it off the queue with stop_session. "+
		"This folder now has %s.", quotedTitle(a.Title), a.ID, ordinal(position), ahead, d.helperPlaces(folder))
	d.checkQueueSoon(folder)
	return note, nil
}

// checkEveryQueue looks at every folder with a queue, as a restart does.
func (d *Daemon) checkEveryQueue() {
	seen := map[string]bool{}
	for _, a := range d.Store.Agents() {
		if f := folderPath(&a); a.State == wire.AgentStateQueued && !seen[f] {
			seen[f] = true
			d.checkQueueSoon(f)
		}
	}
}

// checkQueueSoon starts what the folder's queue may start now, off this call.
func (d *Daemon) checkQueueSoon(folder string) {
	d.goAfterTurn("helper queue", func() { d.startFromQueue(folder) })
}

func (d *Daemon) startFromQueue(folder string) {
	for {
		next := d.nextFromQueue(folder)
		if next == nil {
			return
		}
		d.startQueued(*next, folder)
	}
}

func (d *Daemon) nextFromQueue(folder string) *wire.Agent {
	running, notArchived, _ := d.helperLimitsIn(folder)
	d.queueMu.Lock()
	defer d.queueMu.Unlock()
	reserved := d.reservedHelpers[folder]
	for _, q := range d.helperQueue(folder) {
		if d.startingFromQueue[q.ID] {
			continue
		}
		if int64(len(d.runningHelpers(folder))+reserved) >= running || int64(len(d.helpersIn(folder))+reserved) >= notArchived {
			return nil
		}
		if d.startingFromQueue == nil {
			d.startingFromQueue = map[wire.UUID]bool{}
		}
		if d.reservedHelpers == nil {
			d.reservedHelpers = map[string]int{}
		}
		d.startingFromQueue[q.ID] = true
		d.reservedHelpers[folder]++
		q := q
		return &q
	}
	return nil
}

func (d *Daemon) startQueued(q wire.Agent, folder string) {
	defer func() {
		d.queueMu.Lock()
		delete(d.startingFromQueue, q.ID)
		d.reservedHelpers[folder]--
		d.queueMu.Unlock()
	}()
	if a := d.Store.Agent(q.ID); a == nil || a.State != wire.AgentStateQueued || a.StartedByAgent == nil {
		return
	}
	s := q.QueuedStart
	if s == nil {
		s = &wire.QueuedStart{}
	}
	runtimeID := q.RuntimeID
	if s.RuntimeID != nil {
		runtimeID = *s.RuntimeID
	}
	prompt := ""
	if len(q.QueuedPrompts) > 0 {
		prompt = q.QueuedPrompts[0].Text
	} else if q.Title != nil {
		prompt = *q.Title
	}
	model := ""
	if s.Model != nil {
		model = *s.Model
	}
	r := helperRequest(runtimeID, folder, prompt, model, s.PermissionMode, s.Worktree, nil)
	reuse := q
	reuse.QueuedPrompts = nil
	if _, err := d.startFor(r, startedBy{agent: q.StartedByAgent, owner: wire.SessionLabelOwnerAgent, queued: &reuse}); err != nil {
		_, why := errMessage(err)
		if a := d.Store.Agent(q.ID); a != nil && a.State == wire.AgentStateQueued {
			d.record(q.ID, runtimeNote("It could not start from the queue: "+why))
			d.change(q.ID, func(a *wire.Agent) {
				a.State, a.EndedReason = wire.AgentStateStopped, reason(wire.EndedReasonRuntimeError)
			})
		}
	}
}

// listHelpers is list_sessions with started_by me: its own, and every one below them.
func (d *Daemon) listHelpers(caller *wire.Agent) string {
	folder := folderPath(caller)
	places := "This folder has " + d.helperPlaces(folder) + "."
	var mine []wire.Agent
	for _, a := range append(d.helpersIn(folder), d.helperQueue(folder)...) {
		for _, s := range d.starters(&a) {
			if s == caller.ID {
				mine = append(mine, a)
				break
			}
		}
	}
	runtimes := d.runtimeChoices(caller.RuntimeID)
	if len(mine) == 0 {
		return "You have not started any sessions that are still here. " + places + "\n" + runtimes
	}
	lines := []string{places}
	queue := d.helperQueue(folder)
	for _, a := range mine {
		below := ""
		if a.StartedByAgent != nil && *a.StartedByAgent != caller.ID {
			below = ", started by " + d.holderName(*a.StartedByAgent)
		}
		lines = append(lines, "- "+string(a.ID)+": "+quotedTitle(a.Title)+below+" — "+helperStatus(&a, queue)+labelsLine(&a)+waitingLine(&a, caller.ID))
	}
	return strings.Join(append(lines, runtimes), "\n")
}

func helperStatus(a *wire.Agent, queue []wire.Agent) string {
	if r := a.ArchiveRequest; r != nil && r.Requested != nil {
		return "waiting for the person to approve archiving it"
	} else if r != nil && r.WhenTurnEnds != nil {
		return "to wait for archive approval when the turn ends"
	}
	said := ""
	if a.Report != nil {
		said = ": " + string(a.Report.Outcome) + " — " + a.Report.Message
	}
	switch a.State {
	case wire.AgentStateQueued:
		for i, q := range queue {
			if q.ID == a.ID {
				return fmt.Sprintf("queued (position %d)", i+1)
			}
		}
		return "queued"
	case wire.AgentStateStarting:
		return "starting"
	case wire.AgentStateRunning:
		return "working"
	case wire.AgentStateWaitingOnUser:
		return "waiting on the person"
	case wire.AgentStateFinished:
		return "finished" + said
	case wire.AgentStateStopped:
		why := ""
		if a.EndedReason != nil {
			if s, ok := endedSummary[*a.EndedReason]; ok {
				why = " (" + strings.ToLower(s) + ")"
			}
		}
		return "stopped" + why + said
	}
	return "archived"
}

// runtimeChoices is which runtimes an agent may name, as this host has them now.
func (d *Daemon) runtimeChoices(callerRuntime string) string {
	var available, not []string
	for i := range catalog {
		rt := &catalog[i]
		if why := d.unavailableRuntime(rt); why != "" {
			not = append(not, rt.ID+" ("+strings.TrimPrefix(why, rt.Name+" ")+")")
		} else {
			available = append(available, rt.ID)
		}
	}
	lines := []string{"No runtime can take a new agent on this machine right now."}
	if len(available) > 0 {
		lines = []string{"Runtimes you can start agents on (your own runtime, " + callerRuntime + ", if you name none): " + strings.Join(available, ", ") + "."}
	}
	if len(not) > 0 {
		lines = append(lines, "Not available on this machine: "+strings.Join(not, ", ")+".")
	}
	return strings.Join(lines, "\n")
}

// startAutoHelper is start_session on Auto (#2658, FR-012): the levels in the shared words,
// none looser than the caller's own permission mode, which it takes when it names none.
func (d *Daemon) startAutoHelper(me *wire.Agent, args map[string]json.RawMessage, prompt, model string, labels []string) (string, error) {
	var own *wire.PermissionLevel
	if me.Levels != nil {
		own = me.Levels.Permission
	}
	if own == nil && me.Auto != nil {
		own = me.Auto.Levels.Permission
	}
	var mode *string
	if wanted := strings.TrimSpace(argString(args, "permission_mode")); wanted != "" {
		mode = &wanted
	} else if own != nil {
		w := permissionWord(*own)
		mode = &w
	}
	levels, _, _, _, err := fileLevels(autoRuntimeID, model, mode, "", "")
	if err != nil {
		return "", &Error{Code: CodeInvalidParams, Message: "Nothing was started: " + err.(*Error).Message}
	}
	// With no mode of the caller's to take, the helper plans: the least it may do.
	if levels.Permission == nil {
		p := wire.PermissionLevelPlan
		levels.Permission = &p
	}
	rank := levelRank[wire.AutoFieldPermission]
	if wanted := rank[string(*levels.Permission)]; own == nil && wanted > 0 || own != nil && wanted > rank[string(*own)] {
		ownWords := "your runtime's own mode"
		if own != nil {
			ownWords = permissionWord(*own)
		}
		return "", Invalid("Nothing was started: %s would let it do more without asking than you may (%s). Name no mode and it takes yours.",
			permissionWord(*levels.Permission), ownWords)
	}
	folder := folderPath(me)
	worktree, err := d.helperWorktree(argString(args, "worktree"), folder)
	if err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: "Nothing was started: " + msg}
	}
	if full := d.helperLimitRefusal(folder); full != "" || len(d.helperQueue(folder)) > 0 {
		w := permissionWord(*levels.Permission)
		m := ""
		if levels.Model != nil {
			m = string(*levels.Model)
		}
		return d.queueHelper(me, prompt, autoRuntimeID, m, &w, worktree, labels, full)
	}
	r := helperRequest(autoRuntimeID, folder, prompt, "", nil, worktree, labels)
	r.Levels = levels
	id, err := d.startFor(r, startedBy{agent: &me.ID, owner: wire.SessionLabelOwnerAgent})
	if err != nil {
		code, msg := errMessage(err)
		return "", &Error{Code: code, Message: "Nothing was started: " + msg}
	}
	a := d.Store.Agent(id)
	return fmt.Sprintf("Started %s (id %s) on Auto, which picked %s. This folder now has %s.", quotedTitle(a.Title), id,
		runtimeName(a.RuntimeID), d.helperPlaces(folder)), nil
}
