package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Requests (#3863, spec 3862): what an agent asks a person for, kept on disk so a restart
// does not lose it. One file a record, <root>/requests/<id>.json. ask_question, ask_secret
// and hand_to_person open one in showForm; the answer or the form taken down ends it, and
// the end raises request.answered or request.dropped, which wakes every session that waits
// on it (wait_for_event with where: {request: <id>}).

// The bound (spec 3862 §1): an ended record goes after requestKeepFor, and at most
// requestFileLimit records are kept, the oldest ended ones going first.
var (
	requestKeepFor   = 14 * 24 * time.Hour
	requestFileLimit = 1000
)

type requestStore struct {
	mu   sync.Mutex
	byID map[wire.UUID]*wire.Request
}

func (d *Daemon) requestsDir() string { return filepath.Join(d.Store.Loc.Root, "requests") }

// loadRequests reads the records at start, prunes them, and prunes again once an hour.
func (d *Daemon) loadRequests() {
	d.requests.mu.Lock()
	d.requests.byID = map[wire.UUID]*wire.Request{}
	entries, _ := os.ReadDir(d.requestsDir())
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(d.requestsDir(), e.Name()))
		var r wire.Request
		if err != nil || json.Unmarshal(b, &r) != nil || r.ID == "" {
			log.Printf("requests: skipped unreadable %s", e.Name())
			continue
		}
		d.requests.byID[r.ID] = &r
	}
	d.requests.mu.Unlock()
	d.pruneRequests(time.Now())
	t := time.NewTicker(time.Hour)
	d.goLoop("request pruner", func(ctx context.Context) {
		defer t.Stop()
		for {
			select {
			case <-t.C:
				d.pruneRequests(time.Now())
			case <-ctx.Done():
				return
			}
		}
	})
}

// pruneRequests drops the open requests whose asker has gone, then keeps the bound.
func (d *Daemon) pruneRequests(at time.Time) {
	for _, r := range d.listRequests(wire.RequestsListStateOpen, "") {
		if r.AskedBy == nil {
			continue
		}
		switch a := d.Store.Agent(*r.AskedBy); {
		case a == nil:
			d.endRequest(r.ID, wire.RequestStateDropped, nil, wire.RequestDroppedWhyAskerEnded, nil)
		case a.State == wire.AgentStateArchived:
			d.endRequest(r.ID, wire.RequestStateDropped, nil, wire.RequestDroppedWhyFolderArchived, nil)
		}
	}
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	var ended []*wire.Request
	for _, r := range d.requests.byID {
		if r.State != wire.RequestStateOpen {
			ended = append(ended, r)
		}
	}
	sort.Slice(ended, func(i, j int) bool { return endedAt(ended[i]) < endedAt(ended[j]) })
	over := len(d.requests.byID) - requestFileLimit
	for _, r := range ended {
		if over <= 0 && at.Sub(endedAt(r).Time()) < requestKeepFor {
			continue
		}
		d.removeRequestLocked(r.ID)
		over--
	}
}

func endedAt(r *wire.Request) wire.Date {
	if r.AnsweredAt != nil {
		return *r.AnsweredAt
	}
	return r.AskedAt
}

func (d *Daemon) removeRequestLocked(id wire.UUID) {
	delete(d.requests.byID, id)
	if err := os.Remove(filepath.Join(d.requestsDir(), string(id)+".json")); err != nil && !os.IsNotExist(err) {
		log.Printf("requests: %v", err)
	}
}

func (d *Daemon) saveRequestLocked(r *wire.Request) {
	b, _ := json.Marshal(r)
	if err := store.WriteAtomically(filepath.Join(d.requestsDir(), string(r.ID)+".json"), b, 0o600); err != nil {
		log.Printf("requests: %s: %v", r.ID, err)
	}
}

// listRequests is requests/list: oldest first.
func (d *Daemon) listRequests(state wire.RequestsListState, folder string) []wire.Request {
	d.requests.mu.Lock()
	out := []wire.Request{}
	for _, r := range d.requests.byID {
		open := r.State == wire.RequestStateOpen
		if state == wire.RequestsListStateOpen && !open || state == wire.RequestsListStateEnded && open {
			continue
		}
		if folder != "" && r.Folder != folder {
			continue
		}
		out = append(out, copyRequest(r))
	}
	d.requests.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].AskedAt < out[j].AskedAt })
	return out
}

func copyRequest(r *wire.Request) wire.Request {
	c := *r
	c.Waiters = append([]wire.RequestWaiter{}, r.Waiters...)
	if r.Forge != nil {
		f := *r.Forge
		f.Checklist = append([]wire.RequestChecklistLine{}, r.Forge.Checklist...)
		c.Forge = &f
	}
	return c
}

func (d *Daemon) request(id wire.UUID) *wire.Request {
	d.requests.mu.Lock()
	defer d.requests.mu.Unlock()
	if r := d.requests.byID[id]; r != nil {
		c := copyRequest(r)
		return &c
	}
	return nil
}

// openFormRequest is the record for a form an agent shows: a question, a secret or a step.
func (d *Daemon) openFormRequest(req wire.ElicitationRequest) {
	a := d.Store.Agent(req.AgentID)
	if a == nil || a.Purpose != nil {
		return
	}
	kind, source, title := wire.RequestKindDecide, wire.RequestSourceQuestion, "A question"
	if req.Message != nil && strings.TrimSpace(*req.Message) != "" {
		title = strings.TrimSpace(*req.Message)
	}
	switch {
	case req.Secret != nil:
		kind, source, title = wire.RequestKindSecret, wire.RequestSourceSecret, "The secret "+req.Secret.Name
	case req.HandOff != nil:
		kind, source, title = wire.RequestKindStep, wire.RequestSourceHandOff, req.HandOff.Step
	}
	if i := strings.IndexByte(title, '\n'); i >= 0 {
		title = title[:i]
	}
	at := now()
	asker := req.AgentID
	r := &wire.Request{ID: req.ID, Kind: kind, Source: source, State: wire.RequestStateOpen, Title: title,
		Detail: wire.RequestDetail{Elicitation: &req}, Folder: string(store.FolderURL(folderPath(a))), AskedBy: &asker,
		Waiters: []wire.RequestWaiter{{Agent: asker, Since: at}}, AskedAt: at}
	d.requests.mu.Lock()
	if d.requests.byID == nil {
		d.requests.byID = map[wire.UUID]*wire.Request{}
	}
	d.requests.byID[r.ID] = r
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	d.raiseRequestEvent("request.opened", c, nil, nil)
}

// addRequestWaiter is a session that joins an open request with wait_for_event.
func (d *Daemon) addRequestWaiter(id, agent wire.UUID) {
	d.requests.mu.Lock()
	r := d.requests.byID[id]
	if r == nil || r.State != wire.RequestStateOpen {
		d.requests.mu.Unlock()
		return
	}
	for _, w := range r.Waiters {
		if w.Agent == agent {
			d.requests.mu.Unlock()
			return
		}
	}
	r.Waiters = append(r.Waiters, wire.RequestWaiter{Agent: agent, Since: now()})
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
}

// endRequest answers or drops an open request, once: its end raises the event that wakes
// its waiters. It is false when the request had ended already, or is not here.
func (d *Daemon) endRequest(id wire.UUID, state wire.RequestState, answer *string, why wire.RequestDroppedWhy, by *wire.AuditActor) bool {
	d.requests.mu.Lock()
	r := d.requests.byID[id]
	if r == nil || r.State != wire.RequestStateOpen {
		d.requests.mu.Unlock()
		return false
	}
	at := now()
	r.State, r.AnsweredAt, r.AnsweredBy = state, &at, by
	if state == wire.RequestStateAnswered {
		r.Answer = answer
	} else {
		r.DroppedWhy = &why
	}
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	if state == wire.RequestStateAnswered {
		d.raiseRequestEvent("request.answered", c, map[string]string{"answer": deref(answer), "answered_by": actorName(by)}, by)
	} else {
		d.raiseRequestEvent("request.dropped", c, map[string]string{"why": string(why)}, by)
	}
	return true
}

func actorName(a *wire.AuditActor) string {
	switch {
	case a == nil:
		return ""
	case a.UserName != nil && *a.UserName != "":
		return *a.UserName
	}
	return a.User
}

func (d *Daemon) raiseRequestEvent(name string, r wire.Request, extra map[string]string, by *wire.AuditActor) {
	details := map[string]string{"request": string(r.ID), "kind": string(r.Kind), "source": string(r.Source), "title": r.Title}
	if r.AskedBy != nil {
		details["agent"] = string(*r.AskedBy)
	}
	forgeRequestDetails(r, details)
	for k, v := range extra {
		if v != "" {
			details[k] = v
		}
	}
	sentence := map[string]string{"request.opened": "A request was opened: ", "request.answered": "A request was answered: ",
		"request.dropped": "A request was dropped: "}[name] + r.Title
	d.raiseAs(wire.EventDraft{Name: name, At: now(), Scope: folderScope(store.FolderPath(wire.URL(r.Folder))), Sentence: sentence, Details: details}, by)
}

// formAnswerSummary is the answer's summary on the record: never a secret's value.
func formAnswerSummary(action wire.AnswerElicitationRequestAction, said []wire.ElicitationAnswer) *string {
	s := outcomeSummary(action)
	if len(said) > 0 {
		var parts []string
		for _, a := range said {
			parts = append(parts, a.Answer)
		}
		s += ": " + strings.Join(parts, "; ")
	}
	return &s
}

// answerRequest is requests/answer. A form still held goes the way elicitations/answer
// goes; one whose call went with a restart starts its session again with the answer.
func (d *Daemon) answerRequest(r wire.RequestsAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	rec := d.request(r.ID)
	if rec == nil {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "There is no such request."}
	}
	if rec.State != wire.RequestStateOpen {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already.", Data: wire.RequestUpdate{Request: *rec}}
	}
	form := r.Answer.Form
	if form == nil || rec.Detail.Elicitation == nil {
		return wire.RequestUpdate{}, Invalid("This request takes a form answer.")
	}
	d.answeredBy(r.ID, by)
	err := d.answerElicitation(wire.AnswerElicitationRequest{RequestID: r.ID, Action: form.Action, Content: form.Content})
	if e, ok := err.(*Error); ok && e.Code == wire.FailureNoSuchAgent && d.liveFormOf(r.ID) == nil {
		err = d.answerLostForm(*rec.Detail.Elicitation, form.Action, form.Content, by)
	}
	if err != nil {
		return wire.RequestUpdate{}, err
	}
	if after := d.request(r.ID); after != nil {
		return wire.RequestUpdate{Request: *after}, nil
	}
	return wire.RequestUpdate{Request: *rec}, nil
}

// answeredBy notes who answers a request, for the record the answer path ends.
func (d *Daemon) answeredBy(id wire.UUID, by *wire.AuditActor) {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	if d.requestActors == nil {
		d.requestActors = map[wire.UUID]*wire.AuditActor{}
	}
	d.requestActors[id] = by
}

func (d *Daemon) takeAnsweredBy(id wire.UUID) *wire.AuditActor {
	d.actorMu.Lock()
	defer d.actorMu.Unlock()
	a := d.requestActors[id]
	delete(d.requestActors, id)
	return a
}

func (d *Daemon) liveFormOf(id wire.UUID) *pendingElicitation {
	for _, l := range d.everyLive() {
		if pe := l.elicitationFor(id); pe != nil {
			return pe
		}
	}
	return nil
}

// answerLostForm answers a form whose held call a restart took: as for a form left open
// (#1641), the answer starts the session again with a prompt.
func (d *Daemon) answerLostForm(req wire.ElicitationRequest, action wire.AnswerElicitationRequestAction, content map[string]wire.JSONValue, by *wire.AuditActor) error {
	if action == "" {
		action = wire.AnswerElicitationRequestActionCancel
	}
	if content == nil {
		content = map[string]wire.JSONValue{}
	}
	var said []wire.ElicitationAnswer
	switch {
	case req.Secret != nil:
		sessionOnly := askedSessionOnly(content)
		if action == wire.AnswerElicitationRequestActionAccept {
			if err := d.saveAskedSecret(req.AgentID, *req.Secret, content); err != nil {
				return err
			}
		}
		content = map[string]wire.JSONValue{}
		said = secretAnswered(*req.Secret, action, sessionOnly)
	case action == wire.AnswerElicitationRequestActionAccept && req.Mode.Form != nil:
		if why := problems(req.Mode.Form.Value, content); len(why) > 0 {
			return Invalid("%s", strings.Join(why, ". "))
		}
		said = answers(req.Mode.Form.Value, content, req.Message)
	}
	if !d.endRequest(req.ID, wire.RequestStateAnswered, formAnswerSummary(action, said), "", by) {
		return &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	d.takeAnsweredBy(req.ID)
	d.record(req.AgentID, wire.TranscriptEntryKind{ElicitationAnswered: &wire.TranscriptEntryKindElicitationAnswered{ID: req.ID,
		Summary: outcomeSummary(action), Answers: said}})
	if err := d.promptFromApp(req.AgentID, d.formAnsweredWords(req, action, content, said)); err != nil {
		log.Printf("agent %s: request answer: %v", req.AgentID, err)
	}
	return nil
}

// dropRequest is requests/drop: a form still held is taken down, and its agent hears cancel.
func (d *Daemon) dropRequest(r wire.RequestsDrop, by *wire.AuditActor) (wire.RequestUpdate, error) {
	rec := d.request(r.ID)
	if rec == nil {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "There is no such request."}
	}
	why := wire.RequestDroppedWhyByPerson
	if r.Why != nil {
		why = *r.Why
	}
	if !d.endRequest(r.ID, wire.RequestStateDropped, nil, why, by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already.", Data: wire.RequestUpdate{Request: *rec}}
	}
	if d.liveFormOf(r.ID) != nil {
		d.answerElicitation(wire.AnswerElicitationRequest{RequestID: r.ID, Action: wire.AnswerElicitationRequestActionCancel})
	}
	after := d.request(r.ID)
	return wire.RequestUpdate{Request: *after}, nil
}

// waitsOnlyOnPeople is a session whose turn has ended and whose wait only a person can
// settle: every pattern a request.* event, or a wait for the person (#3051). It holds no
// running place (#3863).
func waitsOnlyOnPeople(a *wire.Agent) bool {
	w := a.EventWait
	if w == nil || w.Ending != nil || inFlight(a.State) {
		return false
	}
	if w.ForPerson != nil && *w.ForPerson {
		return true
	}
	if len(w.Patterns) == 0 || len(w.ServerEvents) > 0 {
		return false
	}
	for _, p := range w.Patterns {
		if !strings.HasPrefix(p.Name, "request.") {
			return false
		}
	}
	return true
}

func (d *Daemon) registerRequests() {
	On(d, wire.CallRequestsList, func(ctx context.Context, c *Client, r wire.RequestsList) (wire.RequestsListResult, error) {
		state := wire.RequestsListStateOpen
		if r.State != nil {
			state = *r.State
		}
		return wire.RequestsListResult{Requests: d.listRequests(state, deref(r.Folder))}, nil
	})
	On(d, wire.CallRequestsAnswer, func(ctx context.Context, c *Client, r wire.RequestsAnswer) (wire.RequestUpdate, error) {
		if rec := d.request(r.ID); rec != nil && rec.Forge != nil && rec.State == wire.RequestStateOpen {
			return d.answerForgeRequest(ctx, *rec, r.Answer, c.actor())
		}
		return d.answerRequest(r, c.actor())
	})
	On(d, wire.CallRequestsDrop, func(ctx context.Context, c *Client, r wire.RequestsDrop) (wire.RequestUpdate, error) {
		return d.dropRequest(r, c.actor())
	})
}
