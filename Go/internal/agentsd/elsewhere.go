package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Sessions on another machine (#2927). A session an agent here started on another machine
// with start_session (#2887) is in that machine's Store, not this one, so this host keeps a
// record of it in <root>/elsewhere.json: the machine, its id, and the starter's folder,
// whose helper limits count it. list_sessions, read_session, message_session,
// wait_for_agents, stop_session and archive_session reach it through the control plane
// (machines/sessionCall), which sends that machine's agents/fromStarter; that machine
// answers only the agent that started it (#1695, #1728), from its own record of who did.
// When it ends, that machine says so (machines/sessionEnded), the control plane tells this
// one (agents/endedElsewhere), and the waits on it close. A host offline then is not told:
// its agent's next status, read or wait asks.

const (
	sessionCallMethod  = "machines/sessionCall"
	sessionEndedMethod = "machines/sessionEnded"
	// elsewhereKept bounds each list in elsewhere.json, newest kept.
	elsewhereKept = 200
)

type elsewhereBook struct {
	elsewhereMu     sync.Mutex
	elsewhereLoaded bool
	elsewhere       elsewhereFile
}

type elsewhereFile struct {
	// Started is the sessions agents here started on other machines, oldest first. One
	// archived there is dropped: it holds no place.
	Started []startedThere `json:"started"`
	// From is the sessions here that agents on other machines started.
	From []startedHere `json:"from"`
}

type startedThere struct {
	Machine string    `json:"machine"`
	Session wire.UUID `json:"session"`
	Starter wire.UUID `json:"starter"`
	// Folder is the starter's, whose limits count it; There is the folder on Machine.
	Folder string    `json:"folder"`
	There  string    `json:"there"`
	Title  string    `json:"title"`
	At     wire.Date `json:"at"`
	// Ended is how it ended, as last heard; nil while it goes on.
	Ended *wire.WaitEndingHow `json:"ended,omitempty"`
}

type startedHere struct {
	Session wire.UUID        `json:"session"`
	From    wire.StartedFrom `json:"from"`
}

func (d *Daemon) elsewherePath() string { return filepath.Join(d.Store.Loc.Root, "elsewhere.json") }

func (d *Daemon) elsewhereLocked() *elsewhereFile {
	if !d.elsewhereLoaded {
		d.elsewhereLoaded = true
		readStore(d.elsewherePath(), &d.elsewhere, "sessions started on other machines are not reached from here")
	}
	return &d.elsewhere
}

func (d *Daemon) saveElsewhereLocked() {
	f := d.elsewhereLocked()
	var started []startedThere
	for _, s := range f.Started {
		if s.Ended == nil || s.Ended.Archived == nil {
			started = append(started, s)
		}
	}
	var from []startedHere
	for _, h := range f.From {
		if d.Store.Agent(h.Session) != nil {
			from = append(from, h)
		}
	}
	f.Started, f.From = started[max(0, len(started)-elsewhereKept):], from[max(0, len(from)-elsewhereKept):]
	writeStore(d.elsewherePath(), elsewhereFile{Started: append([]startedThere{}, f.Started...), From: append([]startedHere{}, f.From...)})
}

// noteStartedThere keeps a session an agent here started on another machine.
func (d *Daemon) noteStartedThere(s startedThere) {
	d.elsewhereMu.Lock()
	defer d.elsewhereMu.Unlock()
	f := d.elsewhereLocked()
	f.Started = append(f.Started, s)
	d.saveElsewhereLocked()
}

// noteStartedHere keeps who on another machine started a session here.
func (d *Daemon) noteStartedHere(id wire.UUID, from wire.StartedFrom) {
	d.elsewhereMu.Lock()
	defer d.elsewhereMu.Unlock()
	f := d.elsewhereLocked()
	f.From = append(f.From, startedHere{Session: id, From: from})
	d.saveElsewhereLocked()
}

// startedFromOf is who on another machine started a session here, or nil.
func (d *Daemon) startedFromOf(id wire.UUID) *wire.StartedFrom {
	d.elsewhereMu.Lock()
	defer d.elsewhereMu.Unlock()
	for _, h := range d.elsewhereLocked().From {
		if h.Session == id {
			from := h.From
			return &from
		}
	}
	return nil
}

// startedThereBy is the sessions starter started on other machines.
func (d *Daemon) startedThereBy(starter wire.UUID) []startedThere {
	d.elsewhereMu.Lock()
	defer d.elsewhereMu.Unlock()
	var out []startedThere
	for _, s := range d.elsewhereLocked().Started {
		if s.Starter == starter {
			out = append(out, s)
		}
	}
	return out
}

// thereNamed is the session on another machine value names, by id or exact title, of the
// ones starter started; nil when none is.
func (d *Daemon) thereNamed(starter wire.UUID, value string) *startedThere {
	value = strings.TrimSpace(value)
	var titled []startedThere
	for _, s := range d.startedThereBy(starter) {
		if strings.EqualFold(string(s.Session), value) {
			return &s
		}
		if s.Title == value {
			titled = append(titled, s)
		}
	}
	if len(titled) == 1 {
		return &titled[0]
	}
	return nil
}

// heardThere is what the session's machine said of it: its title, and how it ended, nil
// while it goes on. An archived one is dropped, and the waits on an ended one close.
// elsewhere.json is written only when what was heard changes a record (#2977): a status
// probe of a session that goes on as before costs no write.
func (d *Daemon) heardThere(session wire.UUID, machine, title string, ended *wire.WaitEndingHow) {
	d.elsewhereMu.Lock()
	f := d.elsewhereLocked()
	changed := false
	for i := range f.Started {
		s := &f.Started[i]
		if s.Session != session {
			continue
		}
		if machine != "" && s.Machine != machine {
			s.Machine, changed = machine, true
		}
		if title != "" && s.Title != title {
			s.Title, changed = title, true
		}
		if !reflect.DeepEqual(s.Ended, ended) {
			s.Ended, changed = ended, true
		}
	}
	if changed {
		d.saveElsewhereLocked()
	}
	d.elsewhereMu.Unlock()
	if ended != nil {
		d.closeWaits(session, *ended)
	}
}

// thereAgents is the sessions on other machines that count in folder's helper limits, as
// records helpersIn can count: running until heard to have ended.
func (d *Daemon) thereAgents(folder string) []wire.Agent {
	d.elsewhereMu.Lock()
	defer d.elsewhereMu.Unlock()
	var out []wire.Agent
	for _, s := range d.elsewhereLocked().Started {
		if s.Folder != folder {
			continue
		}
		title, starter := s.Title+" (on "+s.Machine+")", s.Starter
		a := wire.Agent{ID: s.Session, Title: &title, CreatedAt: s.At, StartedByAgent: &starter, State: wire.AgentStateRunning}
		if s.Ended != nil {
			a.State = wire.AgentStateFinished
		}
		out = append(out, a)
	}
	return out
}

// statusProbePatience bounds thereStatus's live ask (P20261030-1): list_sessions and
// askThereWaits each ask every session on another machine, so one slow machine must not hold
// up the rest — it falls back to "as last heard" instead, as it already does on any error.
const statusProbePatience = 3 * time.Second

// callThere is one agents/fromStarter on a session caller started on another machine,
// through the control plane, and what it said is kept. patience is 0 to wait as long as the
// control plane's own patience for the op allows, or a shorter bound for a status probe.
func (d *Daemon) callThere(caller wire.UUID, s *startedThere, call wire.SessionCall, patience time.Duration) (wire.SessionCallReply, error) {
	var reply wire.SessionCallReply
	call.From, call.Session = wire.StartedFrom{Agent: caller}, s.Session
	params := wire.MachineSessionCall{Host: s.Machine, Call: call}
	var out json.RawMessage
	var err error
	if patience > 0 {
		out, err = d.askWorkspacesPatient(caller, sessionCallMethod, params, patience)
	} else {
		out, err = d.askWorkspaces(caller, sessionCallMethod, params)
	}
	if err != nil {
		return reply, err
	}
	if json.Unmarshal(out, &reply) != nil {
		return reply, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: the control plane's answer could not be read."}
	}
	d.heardThere(s.Session, "", deref(reply.Title), reply.Ended)
	return reply, nil
}

// thereOp is a call that says only its words: read, stop and archive.
func (d *Daemon) thereOp(caller wire.UUID, s *startedThere, op string) (string, error) {
	reply, err := d.callThere(caller, s, wire.SessionCall{Op: op}, 0)
	if err != nil {
		return "", err
	}
	return reply.Said, nil
}

// thereStatus is how a session on another machine stands, asked now, with a short patience
// of its own (P20261030-1); what was last heard, and why, when its machine can't say quickly.
func (d *Daemon) thereStatus(caller wire.UUID, s startedThere) string {
	reply, err := d.callThere(caller, &s, wire.SessionCall{Op: "status"}, statusProbePatience)
	if err == nil {
		return reply.Said
	}
	why := err.Error()
	if e, ok := err.(*Error); ok {
		why = e.Message
	}
	last := "working"
	if s.Ended != nil {
		e := wire.WaitEnding{How: *s.Ended}
		last = endingSummary(&e)
	}
	return last + ", as last heard (" + strings.TrimSuffix(why, ".") + ")"
}

// askThereWaits asks how each session on another machine that an agent here waits on
// stands, so a wait on one that ended while this host was away closes. Asked at once
// (P20261030-1), not one after another: one slow machine must not hold up every other
// session's check.
func (d *Daemon) askThereWaits() {
	var wg sync.WaitGroup
	for _, a := range d.Store.Agents() {
		if !isOpenBlock(a.Report) || a.Report.Block == nil {
			continue
		}
		for _, w := range a.Report.Block.Waits {
			s := d.thereNamed(a.ID, string(w.AgentID))
			if s == nil || w.Ending != nil || d.Store.Agent(w.AgentID) != nil {
				continue
			}
			caller, there := a.ID, *s
			wg.Add(1)
			safe.Go("status of a waited-on session elsewhere", func() {
				defer wg.Done()
				d.thereStatus(caller, there)
			})
		}
	}
	wg.Wait()
}

// listThere is list_sessions started_by me's lines for the sessions on other machines, each
// asked at once (P20261030-1): one slow machine must not make list_sessions wait for every
// other session in turn.
func (d *Daemon) listThere(caller wire.UUID) []string {
	started := d.startedThereBy(caller)
	lines := make([]string, len(started))
	var wg sync.WaitGroup
	for i, s := range started {
		i, s := i, s
		wg.Add(1)
		safe.Go("status of a session elsewhere", func() {
			defer wg.Done()
			lines[i] = "- " + string(s.Session) + ": " + quotedTitle(&s.Title) + " on " + s.Machine + ", in " + s.There + " — " + d.thereStatus(caller, s)
		})
	}
	wg.Wait()
	return lines
}

// waitThere is the session on another machine wait_for_agents names, as a record waitOn
// can wait on, or nil when name is none of caller's.
func (d *Daemon) waitThere(name string, caller wire.UUID) (*wire.Agent, error) {
	s := d.thereNamed(caller, name)
	if s == nil {
		return nil, nil
	}
	reply, err := d.callThere(caller, s, wire.SessionCall{Op: "status"}, 0)
	ended := s.Ended
	if err == nil {
		ended = reply.Ended
	}
	if ended != nil {
		e := wire.WaitEnding{How: *ended}
		return nil, blockRefusal(quotedTitle(&s.Title) + " on " + s.Machine + " has already ended (" + endingSummary(&e) + "). Read it with read_session rather than waiting on it.")
	}
	title := s.Title
	return &wire.Agent{ID: s.Session, Title: &title}, nil
}

// messageThere is message_session to a session caller started on another machine.
func (d *Daemon) messageThere(me *wire.Agent, s *startedThere, text string, replace bool) (string, error) {
	if s.Ended != nil && s.Ended.Finished != nil {
		running, _, _ := d.helperLimitsIn(s.Folder)
		if r := len(d.runningHelpers(s.Folder)); int64(r) >= running {
			return "", refusedMessage(fmt.Sprintf("waking %s would take a running place, and this folder already has %d of %d sessions "+
				"started by sessions running. Send it once one finishes; wait with wait_for_agents.", quotedTitle(&s.Title), r, running))
		}
	}
	if !replace && !d.spendMessage(me.ID) {
		return "", refusedMessage(fmt.Sprintf("this session has sent %d messages in the last hour, the most it may.", messagesPerHour))
	}
	reply, err := d.callThere(me.ID, s, wire.SessionCall{Op: "message", Message: &text, Replace: &replace}, 0)
	if err != nil {
		if e, ok := err.(*Error); ok && !strings.HasPrefix(e.Message, "Nothing") {
			return "", refusedMessage(e.Message)
		}
		return "", err
	}
	return reply.Said, nil
}

// spendMessage counts one message_session against the sender's hour, false past it.
func (d *Daemon) spendMessage(caller wire.UUID) bool {
	t := time.Now()
	d.messageMu.Lock()
	defer d.messageMu.Unlock()
	var sent []time.Time
	for _, at := range d.messagesSent[caller] {
		if t.Sub(at) < time.Hour {
			sent = append(sent, at)
		}
	}
	if d.messagesSent == nil {
		d.messagesSent = map[wire.UUID][]time.Time{}
	}
	if len(sent) >= messagesPerHour {
		d.messagesSent[caller] = sent
		return false
	}
	d.messagesSent[caller] = append(sent, t)
	return true
}

// endedElsewhere is agents/endedElsewhere: a session an agent here started on another
// machine has ended.
func (d *Daemon) endedElsewhere(r wire.SessionEnded) error {
	known := false
	for _, s := range d.startedThereBy(r.Starter) {
		known = known || s.Session == r.Session
	}
	if !known {
		return &Error{Code: wire.FailureNotYours, Message: "No agent here started that session."}
	}
	d.heardThere(r.Session, r.Machine, deref(r.Title), &r.How)
	return nil
}

// tellStarter says to the machine whose agent started a session here that it has ended,
// off the call that ended it.
func (d *Daemon) tellStarter(id wire.UUID, how wire.WaitEndingHow) {
	from := d.startedFromOf(id)
	if from == nil || d.askControl.Load() == nil {
		return
	}
	ended := wire.SessionEnded{Machine: from.Machine, Session: id, Starter: from.Agent, How: how}
	if a := d.Store.Agent(id); a != nil {
		ended.Title = a.Title
	}
	safe.Go("tell the starter", func() {
		if _, err := d.askWorkspaces(id, sessionEndedMethod, ended); err != nil {
			log.Printf("agent %s: tell %s it ended: %v", id, from.Machine, err)
		}
	})
}

// fromStarter is agents/fromStarter: the agent on another machine that started a session
// here reads, messages, stops or archives it, or asks how it stands. Only that agent.
func (d *Daemon) fromStarter(r wire.SessionCall) (wire.SessionCallReply, error) {
	var reply wire.SessionCallReply
	from := d.startedFromOf(r.Session)
	t := d.Store.Agent(r.Session)
	if from == nil || t == nil || from.Agent != r.From.Agent || !strings.EqualFold(from.Machine, r.From.Machine) {
		return reply, &Error{Code: wire.FailureNotYours, Message: "Nothing was done: you did not start that session, or it is not there any more."}
	}
	name := quotedTitle(t.Title)
	reply.Title = t.Title
	switch r.Op {
	case "status":
		reply.Said = helperStatus(t, nil)
	case "read":
		entries, _, err := d.Store.Transcript(t.ID, 0)
		if err != nil {
			reply.Said = sessionUnavailable
		} else {
			reply.Said = history(t, entries, historyHeader(t, r.From.Agent))
		}
	case "message":
		said, err := d.messageFromStarter(t, *from, deref(r.Message), r.Replace != nil && *r.Replace)
		if err != nil {
			return reply, err
		}
		reply.Said = said
	case "stop":
		if !d.stopHelper(t) {
			reply.Said = name + " had already stopped; nothing changed."
		} else {
			reply.Said = "Stopped " + name + ", freeing its running place; it keeps its other place until it is archived."
		}
	case "archive":
		reply.Said = d.archiveForStarter(t)
	default:
		return reply, Invalid("Nothing was done: %s is not something a starter can ask.", r.Op)
	}
	if t = d.Store.Agent(r.Session); t != nil && d.hasEnded(t) != "" {
		reply.Ended = waitEndingHow(t)
		if reply.Ended == nil {
			reply.Ended = &wire.WaitEndingHow{Finished: &wire.WaitEndingHowFinished{}}
		}
	}
	return reply, nil
}

// archiveForStarter is archive_session from the starter on another machine, as for a
// helper here: archived now when this folder lets agents and it is not running, else the
// person approves it.
func (d *Daemon) archiveForStarter(t *wire.Agent) string {
	name := quotedTitle(t.Title)
	may := d.agentsMayArchive(folderPath(t))
	if may && !helperRunning(t) {
		d.archiveBy(t.ID, wire.AgentArchivedReasonByAgent)
		return "Archived " + name + ", freeing its place; the person can unarchive it."
	}
	if r := t.ArchiveRequest; r != nil && (r.Requested != nil || r.WhenTurnEnds != nil) {
		return name + " already waits for the person to approve archiving it; nothing changed."
	}
	working := inFlight(t.State)
	d.requestArchive(t.ID)
	if working && may {
		return name + " will be archived when its turn ends, if it ends done or with nothing to do; otherwise the person approves it."
	}
	return name + " waits for the person to approve archiving it; it keeps its place until it is archived."
}

// messageFromStarter is message_session from the starter on another machine. Its words go
// at once, as a helper's starter's do (#1728); a reply goes back as the session's report.
func (d *Daemon) messageFromStarter(t *wire.Agent, from wire.StartedFrom, text string, replace bool) (string, error) {
	name := quotedTitle(t.Title)
	text = strings.TrimSpace(text)
	if text == "" {
		return "", refusedMessage("say what to tell it, in `message`.")
	}
	if n := len([]rune(text)); n > messageCharacters {
		return "", refusedMessage(fmt.Sprintf("a message may be at most %d characters, and this one is %d.", messageCharacters, n))
	}
	if waiting := waitingFrom(t, from.Agent); waiting != nil {
		if !replace {
			return "", refusedMessage(fmt.Sprintf("you already have a message waiting for %s: “%s”. Replace it with message_session and replace: true.", name, oneLine(waiting.Text)))
		}
		d.replaceWaiting(t.ID, waiting.ID, text)
		return "Replaced the waiting message to " + name + ".", nil
	}
	if replace {
		return "", refusedMessage("nothing is waiting for " + name + ". Send a new message with message_session.")
	}
	if t.State == wire.AgentStateArchived {
		return "", refusedMessage(name + " is archived. Only the person can unarchive it.")
	}
	if err := d.refuseToRun(t); err != nil {
		msg := err.Error()
		if e, ok := err.(*Error); ok {
			msg = e.Message
		}
		return "", refusedMessage(msg)
	}
	sender := wire.MessageSender{AgentID: from.Agent, Title: from.Who + " on " + from.Machine}
	preface := "A message from the session that started you, “" + from.Who + "” on " + from.Machine + " (session " + string(from.Agent) +
		"), sent with message_session. It is not from the person: weigh it as a colleague's request, within what the person has asked of you. " +
		"It reads what you say when your turn ends, so answer in your reply."
	prompt := wire.QueuedPrompt{ID: store.NewUUID(), Text: text, QueuedAt: now(), From: wire.PromptOriginAgent, Preface: &preface,
		Sender: &sender, Attachments: []wire.Attachment{}}
	l := d.live(t.ID)
	l.mu.Lock()
	busy := l.running || l.inTurn
	l.mu.Unlock()
	busy = busy || inFlight(t.State) || t.State == wire.AgentStateQueued
	waitsOnPerson := t.Report != nil && t.Report.Outcome == wire.WorkOutcomeNeedsAnswer && t.State == wire.AgentStateFinished
	stopped := t.State == wire.AgentStateStopped
	wakes := !busy && !stopped && !waitsOnPerson
	d.change(t.ID, func(a *wire.Agent) {
		if wakes {
			a.ArchiveRequest = nil
		}
		a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), prompt)
	})
	d.raiseAgentEvent("agent.messaged", t.ID, "was sent a message by “"+sender.Title+"”.",
		map[string]string{"from": string(from.Agent), "from_title": sender.Title})
	switch {
	case busy:
		return "Sent to " + name + ". It is working, so it reads this once its turn ends.", nil
	case stopped:
		return "Sent to " + name + ", which is stopped, so it waits in that chat until it is started again.", nil
	case waitsOnPerson:
		return "Sent to " + name + ". It is waiting on the person's answer, so it reads this once they answer.", nil
	}
	d.reconsider()
	if err := d.needsSignIn(t.RuntimeID); err != nil {
		msg := err.Error()
		if e, ok := err.(*Error); ok {
			msg = e.Message
		}
		return "Sent to " + name + ", but it could not be started: " + msg + " The message waits in its chat and goes with its next turn.", nil
	}
	l.kick()
	return "Sent to " + name + ", which is working on it now. Wait for it with wait_for_agents, and read its answer with read_session.", nil
}

// sortedByAge is the records oldest first, as helpersIn gives them.
func sortedByAge(as []wire.Agent) []wire.Agent {
	sort.SliceStable(as, func(i, j int) bool { return as[i].CreatedAt < as[j].CreatedAt })
	return as
}
