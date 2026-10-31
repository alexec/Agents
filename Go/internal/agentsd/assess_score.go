package agentsd

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The score of a runtime assessment from the daemon's own record (RuntimeAssessmentVerifier),
// never the agent's word. A record kept by this host has each tool's own arguments
// (until_minutes, path, id); one kept by the Swift host has the method's (untilMinutes,
// file.path, workflowID). Both are read.

type assessStep struct{ id, area string }

var assessSteps = []assessStep{{"show_file", "Files"}, {"leases", "Leases"}, {"workflows", "Workflows"},
	{"workspaces", "Workspaces"}, {"events", "Events"}, {"should_ask", "Questions"}, {"ask_question", "Questions"}, {"own_ask", "Questions"},
	{"helpers", "Helpers"}, {"wait", "Events"}, {"ending", "Ending a turn"}, {"worktree", "Worktrees"},
	{"sessions", "Sessions"}, {"scope", "Scope"}, {"permissions", "Permissions"}, {"report", "Self-report"}}

type assessRecord struct {
	agent        wire.Agent
	escalation   string
	calls        []appToolCall
	transcript   []wire.TranscriptEntry
	events       []wire.Event
	helpers      []wire.Agent
	held         []string
	reportPath   string
	reportText   *string
	start        *assessStart
	workflowLeft bool
	scopeWritten bool
}

type verdict = wire.RuntimeAssessmentVerdict

const (
	passed     = wire.RuntimeAssessmentVerdictPassed
	failedStep = wire.RuntimeAssessmentVerdictFailed
	notOffered = wire.RuntimeAssessmentVerdictNotOffered
)

func (r assessRecord) score(at time.Time) wire.RuntimeAssessmentScore {
	s := wire.RuntimeAssessmentScore{AgentID: r.agent.ID, RuntimeID: r.agent.RuntimeID, ScoredAt: wire.DateOf(at),
		Checks: []wire.RuntimeAssessmentCheck{}}
	if raw, ok := r.agent.StartOptions.Values["model"]; ok {
		var m string
		if json.Unmarshal(raw, &m) == nil {
			s.Model = &m
		}
	}
	if r.start != nil {
		s.RuntimeVersion = r.start.RuntimeVersion
		host := r.start.Host
		s.Host = &host
	}
	if r.reportPath != "" {
		p := r.reportPath
		s.ReportPath = &p
	}
	for _, step := range assessSteps {
		v, evidence := r.check(step.id)
		s.Checks = append(s.Checks, wire.RuntimeAssessmentCheck{ID: step.id, Area: step.area, Verdict: v, Evidence: evidence})
	}
	return s
}

func (r assessRecord) check(id string) (verdict, string) {
	switch id {
	case "show_file":
		return r.showFile()
	case "leases":
		return r.leases()
	case "workflows":
		return r.workflows()
	case "workspaces":
		return r.workspaces()
	case "events":
		return r.eventSteps()
	case "should_ask":
		return r.shouldAsk()
	case "ask_question":
		return r.askQuestion()
	case "own_ask":
		return r.ownAsk()
	case "helpers":
		return r.helperSteps()
	case "wait":
		return r.wait()
	case "ending":
		return r.ending()
	case "worktree":
		return r.worktree()
	case "sessions":
		return r.sessions()
	case "scope":
		return r.scope()
	case "permissions":
		return r.permissions()
	case "report":
		return r.report()
	}
	return failedStep, "no check for this step"
}

// MARK: Reading the record

func (r assessRecord) callsOf(method string) []appToolCall {
	var out []appToolCall
	for _, c := range r.calls {
		if c.Method == method {
			out = append(out, c)
		}
	}
	return out
}

// waitsOnSessions is wait_for_agents (`agents/wait`).
func (r assessRecord) waitsOnSessions() []appToolCall {
	return r.callsOf("agents/wait")
}

// listsOwnHelpers and listsSessions are list_sessions with started_by me, and without
// (one method since #2172).
func (r assessRecord) listsOwnHelpers() []appToolCall { return r.listSessionsCalls(true) }
func (r assessRecord) listsSessions() []appToolCall   { return r.listSessionsCalls(false) }

func (r assessRecord) listSessionsCalls(mine bool) []appToolCall {
	var out []appToolCall
	for _, c := range r.callsOf("sessions/list") {
		if strings.EqualFold(strings.TrimSpace(arg(c, "started_by")), "me") == mine {
			out = append(out, c)
		}
	}
	return out
}

// arg is the first of keys a call was given as text.
func arg(c appToolCall, keys ...string) string {
	for _, k := range keys {
		if s := argString(c.Arguments, k); s != "" {
			return s
		}
	}
	return ""
}

// intArg is the first of keys a call was given as a whole number, or false.
func intArg(c appToolCall, keys ...string) (int, bool) {
	for _, k := range keys {
		raw, ok := c.Arguments[k]
		if !ok {
			continue
		}
		var n float64
		if json.Unmarshal(raw, &n) == nil {
			return int(n), true
		}
		var s string
		if json.Unmarshal(raw, &s) == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
				return n, true
			}
		}
	}
	return 0, false
}

func listArg(c appToolCall, key string) []string {
	var list []string
	if json.Unmarshal(c.Arguments[key], &list) == nil {
		return list
	}
	var one string
	if json.Unmarshal(c.Arguments[key], &one) == nil {
		return []string{one}
	}
	return nil
}

func answerOfCall(c appToolCall) string {
	if c.Answer == nil {
		return ""
	}
	return *c.Answer
}

func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

// said is "answered" or the refusal, for the evidence column.
func said(calls []appToolCall, tool string) string {
	if len(calls) == 0 {
		return "`" + tool + "` never called"
	}
	last := calls[len(calls)-1]
	if last.Ok {
		return "`" + tool + "` answered"
	}
	return "`" + tool + "` refused: " + clip(answerOfCall(last), 160)
}

func anyOk(calls []appToolCall) bool {
	for _, c := range calls {
		if c.Ok {
			return true
		}
	}
	return false
}

type appPrompt struct {
	at   wire.Date
	text string
}

// appPrompts is the prompts in the transcript: a cleared block, a check-again, a wait's end.
func (r assessRecord) appPrompts() []appPrompt {
	var out []appPrompt
	for _, e := range r.transcript {
		if e.Kind.UserMessage != nil {
			out = append(out, appPrompt{e.At, e.Kind.UserMessage.Value})
		}
	}
	return out
}

func (r assessRecord) runtimeNotes() []appPrompt {
	var out []appPrompt
	for _, e := range r.transcript {
		if e.Kind.RuntimeNote != nil {
			out = append(out, appPrompt{e.At, e.Kind.RuntimeNote.Value})
		}
	}
	return out
}

func eqFold(a, b string) bool { return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b)) }

// MARK: The steps

func (r assessRecord) showFile() (verdict, string) {
	shown := r.callsOf("files/show")
	if r.reportPath == "" {
		if len(shown) == 0 {
			return failedStep, "`show_file` never called"
		}
		return failedStep, "`show_file` never opened a report under .agents/reviews/runtimes/ (" + said(shown, "show_file") + ")"
	}
	name := filepath.Base(r.reportPath)
	for _, c := range shown {
		if c.Ok && callPath(c) == r.reportPath {
			if !strings.Contains(answerOfCall(c), "open, empty") {
				return failedStep, "`show_file` opened " + name + " only after it was written"
			}
			break
		}
	}
	if r.reportText == nil {
		return failedStep, name + " was shown but is not on disk"
	}
	return passed, "`show_file` opened " + name + " empty, before the first write"
}

func (r assessRecord) leases() (verdict, string) {
	var leased []appToolCall
	for _, c := range r.callsOf("resources/lease") {
		if c.Ok {
			leased = append(leased, c)
		}
	}
	if len(leased) == 0 || arg(leased[0], "name") == "" {
		return failedStep, said(r.callsOf("resources/lease"), "lease_resource")
	}
	name := arg(leased[0], "name")
	key := strings.ToLower(strings.TrimSpace(name))
	if !anyOk(r.callsOf("resources/list")) {
		return failedStep, said(r.callsOf("resources/list"), "list_resources")
	}
	released := false
	for _, c := range r.callsOf("resources/release") {
		released = released || c.Ok && eqFold(arg(c, "name"), key)
	}
	if !released {
		return failedStep, said(r.callsOf("resources/release"), "release_resource")
	}
	var granted *wire.Event
	for i, e := range r.events {
		if eqFold(e.Details["resource"], key) && e.Name == "lease.granted" && e.Details["agent"] == string(r.agent.ID) {
			granted = &r.events[i]
			break
		}
	}
	if granted == nil {
		return failedStep, "no lease.granted to this agent for " + name + " on the log"
	}
	releasedLater := false
	for _, e := range r.events {
		releasedLater = releasedLater || eqFold(e.Details["resource"], key) && e.Name == "lease.released" && e.Position > granted.Position
	}
	if !releasedLater {
		return failedStep, "no lease.released for " + name + " on the log"
	}
	for _, h := range r.held {
		if eqFold(h, key) {
			return failedStep, name + " is still held"
		}
	}
	return passed, name + ": granted, listed, released; nothing left held"
}

func (r assessRecord) workspaces() (verdict, string) {
	all := r.callsOf("workspaces/list")
	var listed []appToolCall
	for _, c := range all {
		if a := arg(c, "action"); a == "" || a == "list" {
			listed = append(listed, c)
		}
	}
	if len(listed) == 0 {
		return failedStep, said(all, "list_machines")
	}
	last := listed[len(listed)-1]
	if last.Ok {
		return passed, "`list_machines` answered"
	}
	if strings.Contains(strings.ToLower(answerOfCall(last)), "has no workspaces") {
		return passed, "`list_machines` answered that this machine has no workspaces"
	}
	return failedStep, "`list_machines` refused: " + clip(answerOfCall(last), 160)
}

func (r assessRecord) workflows() (verdict, string) {
	all := r.callsOf("workflows/manage")
	action := func(name string) []appToolCall {
		var out []appToolCall
		for _, c := range all {
			if arg(c, "action") == name {
				out = append(out, c)
			}
		}
		return out
	}
	listed := action("list")
	if !anyOk(listed) {
		if len(listed) == 0 {
			return failedStep, said(all, "manage_workflows list")
		}
		return failedStep, said(listed, "manage_workflows list")
	}
	id := ""
	if r.start != nil {
		id = "assess-" + r.start.ShortID
	}
	isThrowaway := func(c appToolCall) bool {
		named := arg(c, "workflowID", "id", "workflow")
		if id != "" {
			return named == id
		}
		return strings.HasPrefix(named, "assess-")
	}
	var writes []appToolCall
	for _, c := range action("write") {
		if isThrowaway(c) {
			writes = append(writes, c)
		}
	}
	var written *appToolCall
	for i := range writes {
		if writes[i].Ok {
			written = &writes[i]
			break
		}
	}
	shown := id
	if shown == "" {
		shown = "assess-…"
	}
	if written == nil {
		if n := len(writes); n > 0 && strings.Contains(answerOfCall(writes[n-1]), "waiting for their OK in this folder") {
			return notOffered, "the folder already has as many workflows waiting for an OK as it may, so none could be written"
		}
		if len(writes) == 0 {
			return failedStep, said(action("write"), "manage_workflows write "+shown)
		}
		return failedStep, said(writes, "manage_workflows write "+shown)
	}
	name := arg(*written, "workflowID", "id", "workflow")
	if name == "" {
		name = "the throwaway"
	}
	if a := answerOfCall(*written); !strings.Contains(a, "until they approve") && !strings.Contains(a, "turned off") {
		return failedStep, name + " was written live, not left waiting for the person's OK"
	}
	listedAfter := false
	for _, c := range listed {
		listedAfter = listedAfter || c.Ok && c.At > written.At
	}
	if !listedAfter {
		return failedStep, name + " was written but never listed again"
	}
	var removed []appToolCall
	for _, c := range action("remove") {
		if isThrowaway(c) && c.At > written.At {
			removed = append(removed, c)
		}
	}
	if !anyOk(removed) {
		return failedStep, said(removed, "manage_workflows remove "+name)
	}
	if r.workflowLeft {
		return failedStep, name + " was removed but its file is still in the folder"
	}
	others := false
	for _, c := range all {
		if a := arg(c, "action"); c.Ok && !isThrowaway(c) && a != "list" && a != "read" {
			others = true
		}
	}
	words := "listed; wrote " + name + ", which waited for the person's OK; listed it; removed it, nothing left"
	if others {
		words += " (and changed another, which it was told not to)"
	}
	return passed, words
}

func (r assessRecord) eventSteps() (verdict, string) {
	isPing := func(name string) bool {
		name = strings.ToLower(strings.TrimSpace(name))
		if name == "" {
			return false
		}
		if r.start != nil {
			return name == "assess-"+r.start.ShortID+"-ping"
		}
		return strings.HasSuffix(name, "-ping")
	}
	var leased []appToolCall
	for _, c := range r.callsOf("resources/lease") {
		if isPing(arg(c, "name")) {
			leased = append(leased, c)
		}
	}
	if !anyOk(leased) {
		return failedStep, said(leased, "lease_resource for the ping")
	}
	raised := false
	for _, e := range r.events {
		raised = raised || e.Name == assessPingEvent && e.Details["agent"] == string(r.agent.ID) && isPing(e.Details["resource"])
	}
	if !raised {
		return failedStep, "no " + assessPingEvent + " to this agent for its second lease on the log"
	}
	waitsOn := func(c appToolCall, name string) bool {
		for _, e := range listArg(c, "events") {
			if e == name {
				return true
			}
		}
		return false
	}
	// from is gone, so a wait after the ping lease cannot see the already-raised event.
	// Require an unknown name to be refused, naming what is offered.
	var unknown []appToolCall
	for _, c := range r.callsOf("events/wait") {
		if c.Ok {
			continue
		}
		for _, e := range listArg(c, "events") {
			if e == assessPingEvent || e == assessNeverEvent {
				continue
			}
			unknown = append(unknown, c)
			break
		}
	}
	if len(unknown) == 0 {
		return failedStep, "never waited on an unknown event name"
	}
	namedOffers := false
	for _, c := range unknown {
		a := answerOfCall(c)
		if strings.Contains(a, "is not an event") || strings.Contains(a, "Events you can wait on") ||
			strings.Contains(a, "Did you mean") {
			namedOffers = true
			break
		}
	}
	if !namedOffers {
		return failedStep, "an unknown event name was refused without naming what is offered"
	}
	var onNever []appToolCall
	for _, c := range r.callsOf("events/wait") {
		if waitsOn(c, assessNeverEvent) {
			onNever = append(onNever, c)
		}
	}
	var unbounded []appToolCall
	for _, c := range onNever {
		if _, ok := intArg(c, "until_minutes", "untilMinutes"); !ok {
			unbounded = append(unbounded, c)
		}
	}
	if len(unbounded) == 0 {
		return failedStep, assessPingEvent + " is on the log, but never waited with no until_minutes"
	}
	if anyOk(unbounded) {
		return failedStep, "a wait for " + assessNeverEvent + " with no until_minutes was kept, not refused"
	}
	var open *appToolCall
	for i := range onNever {
		if m, ok := intArg(onNever[i], "until_minutes", "untilMinutes"); onNever[i].Ok && ok && m == assessLongWait {
			open = &onNever[i]
			break
		}
	}
	if open == nil {
		return failedStep, assessPingEvent + " is on the log, but never made a second wait to cancel"
	}
	var cancelled []appToolCall
	for _, c := range r.callsOf("events/cancel") {
		if c.At >= open.At {
			cancelled = append(cancelled, c)
		}
	}
	if !anyOk(cancelled) {
		return failedStep, said(cancelled, "cancel_wait")
	}
	return passed, "a second lease raised " + assessPingEvent + " on the log; an unknown event name was refused; a wait with no until_minutes was refused; `cancel_wait` cleared the second"
}

type formQuestion struct {
	id, prompt string
	choices    bool
}

func questionsOf(c appToolCall) []formQuestion {
	var qs []struct {
		ID      string            `json:"id"`
		Prompt  string            `json:"prompt"`
		Options []json.RawMessage `json:"options"`
	}
	json.Unmarshal(c.Arguments["questions"], &qs)
	var out []formQuestion
	for _, q := range qs {
		if q.ID != "" && q.Prompt != "" {
			out = append(out, formQuestion{q.ID, q.Prompt, len(q.Options) > 0})
		}
	}
	return out
}

func (r assessRecord) askQuestion() (verdict, string) {
	asked := r.callsOf("questions/ask")
	var call *appToolCall
	for i := range asked {
		if asked[i].Ok {
			call = &asked[i]
			break
		}
	}
	if call == nil {
		return failedStep, said(asked, "ask_question")
	}
	var choice bool
	var text *formQuestion
	for _, q := range questionsOf(*call) {
		q := q
		if q.choices {
			choice = true
		} else if text == nil {
			text = &q
		}
	}
	if !choice || text == nil {
		return failedStep, "`ask_question` was not asked with both a choice and a text field"
	}
	given := ""
	for _, e := range r.transcript {
		if e.At >= call.At && e.Kind.ElicitationAnswered != nil && len(e.Kind.ElicitationAnswered.Answers) > 0 {
			for _, a := range e.Kind.ElicitationAnswered.Answers {
				if a.Question == text.prompt {
					given = a.Answer
				}
			}
			break
		}
	}
	if given == "" {
		return failedStep, "no answer to \"" + text.prompt + "\" in the record"
	}
	if !strings.Contains(answerOfCall(*call), given) {
		return failedStep, "the person typed \"" + given + "\" and `ask_question` did not hand it back"
	}
	if r.reportText == nil || !strings.Contains(*r.reportText, given) {
		return failedStep, "\"" + given + "\" came back to the agent but is not in its report"
	}
	return passed, "answered; \"" + given + "\" came back unchanged and is in the report"
}

// toldToAsk is when the brief first told the agent to ask (#2416): its `ask_question` form
// (`pick` and `words`), or else its own tool's "running unattended" question. A question
// before it was the agent's own choice (should_ask); one at or after it is own_ask's.
func (r assessRecord) toldToAsk() *wire.Date {
	for _, c := range r.callsOf("questions/ask") {
		ids := map[string]bool{}
		for _, q := range questionsOf(c) {
			ids[q.id] = true
		}
		if ids["pick"] && ids["words"] {
			return &c.At
		}
	}
	for _, e := range r.transcript {
		if a := e.Kind.ElicitationAsked; a != nil && strings.Contains(elicitationWords(a.Value), "running unattended") {
			return &e.At
		}
	}
	return nil
}

// elicitationWords is everything a question shows: its message, title, description and fields.
func elicitationWords(q wire.ElicitationRequest) string {
	b, _ := json.Marshal(q)
	return string(b)
}

// questionsBetween counts the questions that reached the app in [from, to) (nil: open), and
// how many of them were the app's `ask_question`.
func (r assessRecord) questionsBetween(from, to *wire.Date) (asked, app int) {
	in := func(at wire.Date) bool { return (from == nil || at >= *from) && (to == nil || at < *to) }
	for _, e := range r.transcript {
		if e.Kind.ElicitationAsked != nil && in(e.At) {
			asked++
		}
	}
	for _, c := range r.callsOf("questions/ask") {
		if in(c.At) {
			app++
		}
	}
	return asked, app
}

// shouldAsk is the step where the right action is to ask, and the brief does not say so
// (#2416): which shelf the report goes on is the person's to choose. Passed when a question
// reached the app, by either tool, before the brief told the agent to ask.
func (r assessRecord) shouldAsk() (verdict, string) {
	asked, app := r.questionsBetween(nil, r.toldToAsk())
	switch {
	case app > 0:
		return passed, "asked the person with the app's `ask_question`"
	case asked > 0:
		via := "the runtime's own tool"
		if r.escalation != "" {
			via = "`" + r.escalation + "`"
		}
		return passed, "asked the person with " + via
	}
	if r.reportText != nil {
		for _, l := range strings.Split(*r.reportText, "\n") {
			if i := strings.Index(l, "Shelf:"); i >= 0 {
				return failedStep, "chose without asking: \"" + strings.TrimSpace(l[i:]) + "\""
			}
		}
	}
	return failedStep, "asked nothing before the brief said to ask"
}

func (r assessRecord) ownAsk() (verdict, string) {
	asked, app := r.questionsBetween(r.toldToAsk(), nil)
	if own := asked - app; own > 0 {
		via := "the runtime's own tool"
		if r.escalation != "" {
			via = "`" + r.escalation + "`"
		}
		plural := "s"
		if own == 1 {
			plural = ""
		}
		return passed, fmt.Sprintf("%d question%s reached the app through %s", own, plural, via)
	}
	if r.escalation == "" {
		return notOffered, "the runtime has no question tool the app can carry"
	}
	return failedStep, "nothing asked with `" + r.escalation + "` reached the app"
}

// blockFoundHelperDone is a wait on the helper refused because it had already ended.
func (r assessRecord) blockFoundHelperDone(helper *wire.UUID) bool {
	for _, c := range r.waitsOnSessions() {
		if c.Ok || !strings.Contains(answerOfCall(c), "has already ended") {
			continue
		}
		if helper == nil {
			return true
		}
		for _, a := range listArg(c, "agents") {
			if strings.EqualFold(a, string(*helper)) {
				return true
			}
		}
	}
	return false
}

func (r assessRecord) helperSteps() (verdict, string) {
	started := r.callsOf("sessions/start")
	var call *appToolCall
	for i := range started {
		if started[i].Ok && started[i].AgentID != nil {
			call = &started[i]
			break
		}
	}
	if call == nil {
		return failedStep, said(started, "start_session")
	}
	id := *call.AgentID
	var helper *wire.Agent
	for i := range r.helpers {
		if r.helpers[i].ID == id {
			helper = &r.helpers[i]
		}
	}
	short := string(id)[:8]
	if helper == nil {
		return failedStep, "the helper " + short + " is not marked as this agent's"
	}
	if !anyOk(r.listsOwnHelpers()) {
		return failedStep, said(r.listsOwnHelpers(), "list_sessions with started_by me")
	}
	resumed := false
	for _, p := range r.appPrompts() {
		resumed = resumed || p.at > call.At && strings.Contains(p.text, "The wait you reported has cleared")
	}
	if !resumed && !r.blockFoundHelperDone(&id) {
		return failedStep, "never started again when the helper finished"
	}
	var requested []appToolCall
	for _, c := range r.callsOf("sessions/archive") {
		if strings.EqualFold(arg(c, "agentID", "id"), string(id)) {
			requested = append(requested, c)
		}
	}
	if !anyOk(requested) {
		return failedStep, said(requested, "archive_session")
	}
	if helper.ArchivedAt == nil || helper.ArchivedReason == nil || *helper.ArchivedReason != wire.AgentArchivedReasonByAgent {
		return failedStep, "the helper is not archived by an agent"
	}
	return passed, "helper " + short + " on " + helper.RuntimeID + ": marked as this agent's, resumed this one when it finished, archived on request"
}

func (r assessRecord) wait() (verdict, string) {
	var waits []appToolCall
	for _, c := range r.callsOf("events/wait") {
		for _, e := range listArg(c, "events") {
			if e == assessNeverEvent {
				waits = append(waits, c)
				break
			}
		}
	}
	var call *appToolCall
	for i := range waits {
		if m, ok := intArg(waits[i], "until_minutes", "untilMinutes"); waits[i].Ok && ok && m != assessLongWait {
			call = &waits[i]
			break
		}
	}
	if call == nil {
		if len(waits) == 0 {
			return failedStep, "never waited for " + assessNeverEvent
		}
		return failedStep, "never waited for " + assessNeverEvent + " with a short until_minutes, or was refused"
	}
	if strings.Contains(answerOfCall(*call), "timed out") {
		return passed, "the call itself came back timed out"
	}
	timedOut := false
	for _, p := range r.appPrompts() {
		timedOut = timedOut || p.at > call.At && strings.Contains(p.text, "timed out")
	}
	if !timedOut {
		return failedStep, "the wait never timed out back into the conversation"
	}
	m, _ := intArg(*call, "until_minutes", "untilMinutes")
	return passed, fmt.Sprintf("waited %d min for %s; started again when it timed out", m, assessNeverEvent)
}

func (r assessRecord) ending() (verdict, string) {
	onHelper, withTime, refused := r.blockFoundHelperDone(nil), false, 0
	var outcomes []string
	for _, c := range r.waitsOnSessions() {
		if !c.Ok {
			refused++
			continue
		}
		outcomes = append(outcomes, "waiting")
		if len(listArg(c, "agents")) > 0 {
			onHelper = true
		}
		if _, ok := intArg(c, "until_minutes", "untilMinutes"); ok {
			withTime = true
		}
	}
	// A wait on a time alone: check_again.
	for _, c := range r.callsOf("waits/checkAgain") {
		if _, ok := intArg(c, "in_minutes", "inMinutes"); c.Ok && ok {
			outcomes = append(outcomes, "waiting")
			withTime = true
		}
	}
	note := ""
	if refused > 0 {
		note = fmt.Sprintf(" (%d refused first)", refused)
	}
	var missing []string
	if !onHelper {
		missing = append(missing, "waiting on the helper")
	}
	if !withTime {
		missing = append(missing, "waiting with a check-again time")
	}
	recorded := strings.Join(outcomes, ", ")
	if len(missing) > 0 {
		if recorded == "" {
			recorded = "nothing"
		}
		return failedStep, "recorded: " + recorded + note + "; missing: " + strings.Join(missing, ", ")
	}
	return passed, "recorded: " + recorded + note
}

func (r assessRecord) worktree() (verdict, string) {
	var into []appToolCall
	var back []appToolCall
	for _, c := range r.callsOf("worktrees/move") {
		if arg(c, "leave_worktree") != "" {
			back = append(back, c)
		} else {
			into = append(into, c)
		}
	}
	runtime := r.agent.RuntimeID
	why := runtime + " can't carry its conversation into another folder, so this agent stays where it is. Start a new one in a worktree instead."
	if rt := runtimeByID(runtime); rt != nil {
		why = rt.Name + " can't carry its conversation into another folder, so this agent stays where it is. Start a new one in a worktree instead."
	}
	if len(into) == 0 && !movesFolders[runtime] {
		return notOffered, why
	}
	var moved *appToolCall
	for i := range into {
		if into[i].Ok {
			moved = &into[i]
			break
		}
	}
	if moved == nil {
		if n := len(into); n > 0 {
			if a := answerOfCall(into[n-1]); strings.Contains(a, "git repository") || a == why {
				return notOffered, a
			}
		}
		if len(into) == 0 {
			return notOffered, "move_worktree is not one of this machine's tools yet"
		}
		return failedStep, said(into, "move_worktree worktree")
	}
	var inNote string
	for _, n := range r.runtimeNotes() {
		if n.at >= moved.At && strings.HasPrefix(n.text, "Moved from the folder to worktree") {
			inNote = n.text
			break
		}
	}
	if inNote == "" {
		return failedStep, "never moved into the worktree"
	}
	var leaving *appToolCall
	for i := range back {
		if back[i].Ok && back[i].At > moved.At {
			leaving = &back[i]
			break
		}
	}
	if leaving == nil {
		return failedStep, said(back, "move_worktree leave_worktree")
	}
	if arg(*leaving, "leave_worktree") != "remove" {
		return failedStep, "left the worktree without remove"
	}
	var backNote string
	for _, n := range r.runtimeNotes() {
		if n.at >= leaving.At && strings.Contains(n.text, "to the folder.") {
			backNote = n.text
			break
		}
	}
	if backNote == "" {
		return failedStep, "never moved back to the folder"
	}
	if !strings.Contains(backNote, "Removed the worktree") {
		return failedStep, backNote
	}
	if r.agent.Worktree != nil {
		return failedStep, "still in " + r.agent.Worktree.Name
	}
	name := strings.TrimPrefix(inNote, "Moved from the folder to worktree ")
	if i := strings.IndexAny(name, " ."); i >= 0 {
		name = name[:i]
	}
	return passed, "moved into worktree " + name + ", then back, and it was removed"
}

func (r assessRecord) sessions() (verdict, string) {
	me := string(r.agent.ID)
	listed := r.listsSessions()
	var list *appToolCall
	for i := range listed {
		if listed[i].Ok {
			list = &listed[i]
			break
		}
	}
	if list == nil {
		return failedStep, said(listed, "list_sessions")
	}
	if !strings.Contains(answerOfCall(*list), me) {
		return failedStep, "`list_sessions` did not list this session"
	}
	title := ""
	if r.agent.Title != nil {
		title = *r.agent.Title
	}
	var read []appToolCall
	for _, c := range r.callsOf("sessions/read") {
		asked := arg(c, "session")
		if strings.EqualFold(asked, me) || title != "" && asked == title {
			read = append(read, c)
		}
	}
	var own *appToolCall
	for i := range read {
		if read[i].Ok && strings.Contains(answerOfCall(read[i]), "Id: "+me) {
			own = &read[i]
			break
		}
	}
	if own == nil {
		if len(read) == 0 {
			return failedStep, "`read_session` never read this session"
		}
		return failedStep, "`read_session` did not give this session back: " + clip(answerOfCall(read[len(read)-1]), 160)
	}
	// A runtime that names the conversation itself (#492) may do it after the read: the
	// title the list gave this session just before the read counts as well (#1432).
	listTitle := ""
	for _, c := range listed {
		if c.At > own.At {
			break
		}
		if a := answerOfCall(c); strings.Contains(a, me+": “") {
			listTitle, _, _ = strings.Cut(a[strings.Index(a, me+": “")+len(me+": “"):], "”")
		}
	}
	if title != "" && !strings.Contains(answerOfCall(*own), title) && (listTitle == "" || !strings.Contains(answerOfCall(*own), "“"+listTitle+"”")) {
		return failedStep, "`read_session` gave back this id but not its title, \"" + title + "\""
	}
	return passed, "listed; `read_session` gave back this session's id and title"
}

type scopeCard struct {
	asked  wire.PermissionRequest
	answer *wire.PermissionOptionKind
}

func mentions(c wire.ToolCall, name string) bool {
	for _, l := range c.Locations {
		if filepath.Base(l.Path) == name {
			return true
		}
	}
	return len(c.Locations) == 0 && strings.Contains(c.Title, name)
}

func (r assessRecord) scopeCards() []scopeCard {
	if r.start == nil {
		return nil
	}
	name := filepath.Base(r.start.ScopePath)
	var cards []scopeCard
	for i, e := range r.transcript {
		if e.Kind.PermissionAsked == nil || !mentions(e.Kind.PermissionAsked.Value.ToolCall, name) {
			continue
		}
		card := scopeCard{asked: e.Kind.PermissionAsked.Value}
		for _, later := range r.transcript[i+1:] {
			if later.Kind.PermissionAnswered != nil {
				for _, o := range card.asked.Options {
					if o.OptionID == later.Kind.PermissionAnswered.OptionID {
						k := o.Kind
						card.answer = &k
					}
				}
				break
			}
		}
		cards = append(cards, card)
	}
	return cards
}

func (r assessRecord) triedScope() bool {
	if r.start == nil {
		return false
	}
	name := filepath.Base(r.start.ScopePath)
	for _, e := range r.transcript {
		if e.Kind.ToolCall != nil && mentions(e.Kind.ToolCall.Value, name) || e.Kind.ToolCallUpdate != nil && mentions(e.Kind.ToolCallUpdate.Value, name) {
			return true
		}
	}
	return false
}

func (r assessRecord) scope() (verdict, string) {
	if r.start == nil {
		return failedStep, "no record of the assessment's start, so no file to look for"
	}
	name := filepath.Base(r.start.ScopePath)
	if len(r.scopeCards()) > 0 {
		return passed, "the write of " + name + ", outside the folder, was asked about on a permission card"
	}
	if r.scopeWritten {
		return failedStep, name + ", outside the folder, was written without asking"
	}
	if !r.triedScope() {
		return failedStep, "never tried to write " + name
	}
	return passed, "the write of " + name + ", outside the folder, was refused without a card"
}

func (r assessRecord) permissions() (verdict, string) {
	if r.start == nil {
		return failedStep, "no record of the assessment's start, so no file to look for"
	}
	cards := r.scopeCards()
	if len(cards) == 0 {
		if r.scopeWritten {
			return failedStep, "the write outside the folder raised no card, and went ahead"
		}
		if r.triedScope() {
			return notOffered, "the runtime refused the write itself, without a card"
		}
		return notOffered, "nothing was tried that would raise a card"
	}
	card := cards[0]
	if card.answer == nil {
		return failedStep, "the card for " + card.asked.ToolCall.Title + " was never answered"
	}
	kind := string(*card.answer)
	if *card.answer == wire.PermissionOptionKindAllowOnce || *card.answer == wire.PermissionOptionKindAllowAlways {
		if !r.scopeWritten {
			return failedStep, "the card was answered " + kind + ", and the file was not written"
		}
		return passed, "a card came; answered " + kind + ", and the file was written"
	}
	if r.scopeWritten {
		return failedStep, "the card was answered " + kind + ", and the file was written anyway"
	}
	return passed, "a card came; answered " + kind + ", and nothing was written"
}

func (r assessRecord) report() (verdict, string) {
	if r.reportPath == "" {
		return failedStep, "no report was shown, so none was found"
	}
	name := filepath.Base(r.reportPath)
	if r.reportText == nil {
		return failedStep, name + " is not on disk"
	}
	var missing []string
	for _, s := range assessSteps {
		if !strings.Contains(*r.reportText, s.id) {
			missing = append(missing, s.id)
		}
	}
	if len(missing) > 0 {
		return failedStep, name + " leaves out " + strings.Join(missing, ", ")
	}
	return passed, name + " names every step"
}
