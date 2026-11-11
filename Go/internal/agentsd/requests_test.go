package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// #3863: a form an agent shows is a request, kept on disk; answering or dropping it ends it
// once, and its end wakes every session that waits on it.

func listedRequests(t *testing.T, c *conn, id int, state string) []wire.Request {
	t.Helper()
	var out wire.RequestsListResult
	json.Unmarshal(c.call(t, id, "requests/list", map[string]any{"state": state}), &out)
	return out.Requests
}

func TestARequestIsOpenedKeptAndAnswered(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "a form please"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a form", asked(&form))
	open := listedRequests(t, c, 2, "open")
	if len(open) != 1 || open[0].ID != form.ID || open[0].Kind != wire.RequestKindDecide || open[0].Source != wire.RequestSourceQuestion ||
		open[0].Title != "Which colour?" || open[0].AskedBy == nil || *open[0].AskedBy != id || len(open[0].Waiters) != 1 {
		t.Fatalf("%+v", open)
	}
	if _, err := os.Stat(filepath.Join(root, "requests", string(form.ID)+".json")); err != nil {
		t.Fatal(err)
	}
	c.call(t, 3, "requests/answer", map[string]any{"id": form.ID, "answer": map[string]any{"form": map[string]any{
		"action": "accept", "content": map[string]any{"colour": "blue"}}}})
	c.until(t, "the end", ended(id, wire.AgentStateFinished))
	r := d.request(form.ID)
	if r.State != wire.RequestStateAnswered || r.Answer == nil || !strings.HasSuffix(*r.Answer, ": blue") || r.AnsweredAt == nil {
		t.Fatalf("%+v", r)
	}
	if n := names(d); !contains(n, "request.opened") || !contains(n, "request.answered") {
		t.Fatalf("%v", n)
	}
	if len(listedRequests(t, c, 4, "open")) != 0 || len(listedRequests(t, c, 5, "ended")) != 1 {
		t.Fatal("not ended")
	}
	// Ended once: a late answer is refused, with the record.
	e := c.callError(t, 6, "requests/answer", map[string]any{"id": form.ID, "answer": map[string]any{"form": map[string]any{"action": "decline"}}})
	if e.Code != wire.FailureNoSuchAgent || e.Data == nil {
		t.Fatalf("%+v", e)
	}
	// A restart keeps it.
	d.Shutdown()
	d2, c2 := start(t, root)
	defer d2.Shutdown()
	if got := listedRequests(t, c2, 1, "all"); len(got) != 1 || got[0].State != wire.RequestStateAnswered {
		t.Fatalf("%+v", got)
	}
}

func TestADroppedRequestTakesItsFormDown(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var id wire.UUID
	json.Unmarshal(c.call(t, 1, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + t.TempDir(),
		"prompt": "a form please"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a form", asked(&form))
	c.in <- `{"jsonrpc":"2.0","id":2,"method":"requests/drop","params":{"id":"` + string(form.ID) + `"}}`
	c.until(t, "the form taken down", takenDown(form.ID))
	r := d.request(form.ID)
	if r.State != wire.RequestStateDropped || r.DroppedWhy == nil || *r.DroppedWhy != wire.RequestDroppedWhyByPerson {
		t.Fatalf("%+v", r)
	}
	if n := names(d); !contains(n, "request.dropped") {
		t.Fatalf("%v", n)
	}
}

func TestTwoSessionsThatWaitOnOneRequestBothWake(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	asker := seeded(t, d, dir, nil)
	msg := "Which port?"
	req := wire.ElicitationRequest{ID: store.NewUUID(), AgentID: asker.ID, Message: &msg, AskedAt: now()}
	// Its held call went with a restart: only the record is left.
	d.openFormRequest(req)
	woke := make(chan string, 2)
	var waiters []wire.UUID
	for i := 0; i < 2; i++ {
		w := seeded(t, d, dir, nil)
		waiters = append(waiters, w.ID)
		m := appClient(t, d, w.ID)
		m.post("initialize", map[string]any{}, 1)
		go func() {
			text, _ := m.tool(2, "wait_for_event", map[string]any{"events": []string{"request.answered", "request.dropped"},
				"where": map[string]any{"request": string(req.ID)}, "until_minutes": 10})
			woke <- text
		}()
	}
	waitFor(t, "both waiting", func() bool {
		r := d.request(req.ID)
		return r != nil && len(r.Waiters) == 3
	})
	// Waiting only on a request holds no running place.
	for _, w := range waiters {
		waitFor(t, "the wait on the record", func() bool { return d.Store.Agent(w).EventWait != nil })
	}
	c.call(t, 3, "requests/answer", map[string]any{"id": req.ID, "answer": map[string]any{"form": map[string]any{"action": "decline"}}})
	for i := 0; i < 2; i++ {
		select {
		case text := <-woke:
			if !strings.HasPrefix(text, "request.answered happened at ") {
				t.Fatal(text)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("a waiter did not wake")
		}
	}
	waitFor(t, "the asker prompted", func() bool {
		for _, u := range userMessages(d, asker.ID) {
			if strings.HasPrefix(u, "The person replied to your form \"Which port?\"") {
				return true
			}
		}
		return false
	})
}

func TestAWaitHoldsNoRunningPlace(t *testing.T) {
	yes := true
	cases := []struct {
		state   wire.AgentState
		wait    *wire.EventWait
		holding bool
	}{
		{wire.AgentStateFinished, &wire.EventWait{Patterns: []wire.EventPattern{{Name: "request.answered"}, {Name: "request.dropped"}}}, false},
		{wire.AgentStateFinished, &wire.EventWait{Patterns: []wire.EventPattern{{Name: "review.requested"}}, ForPerson: &yes}, false},
		// A wait on CI or a merge holds none either (#4377).
		{wire.AgentStateFinished, &wire.EventWait{Patterns: []wire.EventPattern{{Name: "request.answered"}, {Name: "branch.moved"}}}, false},
		{wire.AgentStateFinished, &wire.EventWait{ServerEvents: []wire.WaitServerEvent{{Servers: []string{"github"}}}}, false},
		{wire.AgentStateRunning, &wire.EventWait{Patterns: []wire.EventPattern{{Name: "request.answered"}}}, true},
		{wire.AgentStateRunning, nil, true},
	}
	for i, tc := range cases {
		a := wire.Agent{State: tc.state, EventWait: tc.wait}
		if got := helperRunning(&a); got != tc.holding {
			t.Errorf("case %d: holds a place = %v, want %v", i, got, tc.holding)
		}
		if tc.wait != nil && !helperBusy(&a) {
			t.Errorf("case %d: a waiting helper is not archived at once", i)
		}
	}
}

func TestRequestsAreBounded(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	at := time.Now()
	put := func(state wire.RequestState, endedAgo time.Duration) wire.UUID {
		ended := wire.DateOf(at.Add(-endedAgo))
		r := &wire.Request{ID: store.NewUUID(), State: state, Title: "t", Folder: "file:///x", Waiters: []wire.RequestWaiter{}, AskedAt: ended}
		if state != wire.RequestStateOpen {
			r.AnsweredAt = &ended
		}
		d.requests.mu.Lock()
		d.requests.byID[r.ID] = r
		d.saveRequestLocked(r)
		d.requests.mu.Unlock()
		return r.ID
	}
	old := put(wire.RequestStateAnswered, 15*24*time.Hour)
	recent := put(wire.RequestStateDropped, time.Hour)
	stillOpen := put(wire.RequestStateOpen, 30*24*time.Hour)
	d.pruneRequests(at)
	if d.request(old) != nil || d.request(recent) == nil || d.request(stillOpen) == nil {
		t.Fatal("not pruned by age")
	}
	if _, err := os.Stat(filepath.Join(d.requestsDir(), string(old)+".json")); !os.IsNotExist(err) {
		t.Fatalf("file kept: %v", err)
	}
	was := requestFileLimit
	requestFileLimit = 3
	defer func() { requestFileLimit = was }()
	older := put(wire.RequestStateAnswered, 2*time.Hour)
	put(wire.RequestStateAnswered, time.Minute)
	d.pruneRequests(at)
	if d.request(older) != nil || d.request(recent) == nil || d.request(stillOpen) == nil || len(d.listRequests(wire.RequestsListStateAll, "")) != 3 {
		t.Fatalf("not pruned to the limit: %+v", d.listRequests(wire.RequestsListStateAll, ""))
	}
}

// #4233: Later. A deferred request stays open but is no need until it comes back, at its
// time or when the person is next at the Mac.

func formRequest(t *testing.T, d *Daemon, c *conn, root string) wire.UUID {
	t.Helper()
	var id wire.UUID
	json.Unmarshal(c.call(t, 100, "agents/start", map[string]any{"runtimeID": "claude", "cwd": "file://" + root,
		"prompt": "a form please"}), &id)
	var form wire.ElicitationRequest
	c.until(t, "a form", asked(&form))
	return form.ID
}

func isNeed(d *Daemon, id wire.UUID) bool {
	for _, n := range d.attentionPending().Needs {
		if n.ID.Elicitation != nil && *n.ID.Elicitation == id {
			return true
		}
	}
	return false
}

func TestARequestDeferredToATimeComesBack(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := formRequest(t, d, c, t.TempDir())
	if !isNeed(d, id) {
		t.Fatal("not a need")
	}
	if e := c.callError(t, 1, "requests/defer", map[string]any{"id": id}); e.Code != CodeInvalidParams {
		t.Fatalf("no when: %+v", e)
	}
	if e := c.callError(t, 2, "requests/defer", map[string]any{"id": id, "until": wire.DateOf(time.Now().Add(-time.Minute))}); e.Code != CodeInvalidParams {
		t.Fatalf("a past time: %+v", e)
	}
	var got wire.RequestUpdate
	// An hour, so a slow runner cannot see it come back before it looks (#4389).
	json.Unmarshal(c.call(t, 3, "requests/defer", map[string]any{"id": id, "until": wire.DateOf(time.Now().Add(time.Hour))}), &got)
	if got.Request.Deferred == nil || got.Request.Deferred.Until == nil || got.Request.State != wire.RequestStateOpen {
		t.Fatalf("%+v", got.Request)
	}
	if isNeed(d, id) || !contains(names(d), "request.deferred") {
		t.Fatalf("still a need, or no event: %v", names(d))
	}
	// Its time comes: the timer, aimed again, brings it back.
	past := wire.DateOf(time.Now().Add(-time.Millisecond))
	d.requests.mu.Lock()
	d.requests.byID[id].Deferred.Until = &past
	d.requests.mu.Unlock()
	d.armRequestTimer()
	waitFor(t, "it comes back", func() bool { r := d.request(id); return r.Deferred == nil && isNeed(d, id) })
	// request.opened is raised after the deferral is cleared, so wait for it too.
	waitFor(t, "request.opened again", func() bool { return countEvents(d, "request.opened") >= 2 })
	if n := countEvents(d, "request.opened"); n != 2 {
		t.Fatalf("request.opened %d times", n)
	}
	// Bring back now.
	c.call(t, 4, "requests/defer", map[string]any{"id": id, "until": wire.DateOf(time.Now().Add(time.Hour))})
	c.call(t, 5, "requests/undefer", map[string]any{"id": id})
	if r := d.request(id); r.Deferred != nil || !isNeed(d, id) {
		t.Fatalf("%+v", r)
	}
}

func TestARequestDeferredAtTheMacComesBackWhenThePersonDoes(t *testing.T) {
	fakeRuntimes(t)
	was := macIdle
	macIdle = 300 * time.Millisecond
	defer func() { macIdle = was }()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := formRequest(t, d, c, t.TempDir())
	c.call(t, 1, "presence/report", map[string]any{"active": true})
	c.call(t, 2, "requests/defer", map[string]any{"id": id, "atMac": true})
	// Here at the time it was deferred: another report while here does not bring it back.
	c.call(t, 3, "presence/report", map[string]any{"active": true})
	if r := d.request(id); r.Deferred == nil || isNeed(d, id) {
		t.Fatalf("back while the person never left: %+v", r)
	}
	// Away, then here again.
	time.Sleep(2 * macIdle)
	c.call(t, 4, "presence/report", map[string]any{"active": true})
	waitFor(t, "it comes back", func() bool { return d.request(id).Deferred == nil })
	if !isNeed(d, id) {
		t.Fatal("not a need again")
	}
}

func TestADeferralSurvivesARestart(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	asker := seeded(t, d, t.TempDir(), nil)
	msg := "Which port?"
	req := wire.ElicitationRequest{ID: store.NewUUID(), AgentID: asker.ID, Message: &msg, AskedAt: now()}
	d.openFormRequest(req)
	c.call(t, 1, "requests/defer", map[string]any{"id": req.ID, "until": wire.DateOf(time.Now().Add(time.Second)), "atMac": true})
	d.Shutdown()
	d2, _ := start(t, root)
	defer d2.Shutdown()
	r := d2.request(req.ID)
	if r == nil || r.State != wire.RequestStateOpen || r.Deferred == nil || r.Deferred.AtMac == nil || !*r.Deferred.AtMac {
		t.Fatalf("%+v", r)
	}
	waitFor(t, "it comes back at its time", func() bool { return d2.request(req.ID).Deferred == nil })
}

func TestAnAnswerWhileDeferredClearsIt(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	id := formRequest(t, d, c, t.TempDir())
	c.call(t, 1, "requests/defer", map[string]any{"id": id, "until": wire.DateOf(time.Now().Add(time.Hour))})
	c.call(t, 2, "requests/answer", map[string]any{"id": id, "answer": map[string]any{"form": map[string]any{
		"action": "accept", "content": map[string]any{"colour": "blue"}}}})
	r := d.request(id)
	if r.State != wire.RequestStateAnswered || r.Deferred != nil {
		t.Fatalf("%+v", r)
	}
	if e := c.callError(t, 3, "requests/defer", map[string]any{"id": id, "atMac": true}); e.Code != wire.FailureNoSuchAgent {
		t.Fatalf("deferred once ended: %+v", e)
	}
}
