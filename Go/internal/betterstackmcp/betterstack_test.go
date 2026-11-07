package betterstackmcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// A fake Better Stack incidents API: a team's incidents, found as Better Stack finds them
// (by the day they started, resolved or all, by monitor), a page of per_page at a time.

type fakeIncident struct {
	id, monitor, name string
	started           time.Time
	resolved          *time.Time
}

type fakeBetterStack struct {
	mu        sync.Mutex
	incidents []fakeIncident
	asked     []string
	status    int
	server    *httptest.Server
}

func newFakeBetterStack(t *testing.T) *fakeBetterStack {
	f := &fakeBetterStack{}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeBetterStack) account() *Account {
	return &Account{Token: "bs_test", URL: f.server.URL}
}

func (f *fakeBetterStack) add(it fakeIncident) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.incidents = append(f.incidents, it)
}

func (f *fakeBetterStack) resolve(id string, at time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.incidents {
		if f.incidents[i].id == id {
			f.incidents[i].resolved = &at
		}
	}
}

func (f *fakeBetterStack) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer bs_test" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	if r.URL.Path != "/api/v3/incidents" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	q := r.URL.Query()
	f.asked = append(f.asked, q.Encode())
	from, _ := time.Parse("2006-01-02", q.Get("from"))
	per, _ := strconv.Atoi(q.Get("per_page"))
	pageNo, _ := strconv.Atoi(q.Get("page"))
	pageNo = max(pageNo, 1)
	all := []map[string]any{}
	for _, it := range f.incidents {
		if it.started.Before(from) || q.Get("monitor_id") != "" && q.Get("monitor_id") != it.monitor ||
			q.Get("resolved") == "true" && it.resolved == nil {
			continue
		}
		var resolved any
		if it.resolved != nil {
			resolved = it.resolved.Format(time.RFC3339Nano)
		}
		all = append(all, map[string]any{"id": it.id, "type": "incident",
			"attributes": map[string]any{"name": it.name, "url": "https://app.example.com/health", "cause": "Status 503",
				"started_at": it.started.Format(time.RFC3339Nano), "resolved_at": resolved, "team_name": "Acme"},
			"relationships": map[string]any{"monitor": map[string]any{"data": map[string]any{"id": it.monitor, "type": "monitor"}}}})
	}
	lo, hi := min((pageNo-1)*per, len(all)), min(pageNo*per, len(all))
	var next any
	if hi < len(all) {
		q.Set("page", strconv.Itoa(pageNo+1))
		next = f.server.URL + "/api/v3/incidents?" + q.Encode()
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": all[lo:hi], "pagination": map[string]any{"next": next}})
}

type clock struct{ now time.Time }

func (c *clock) Now() time.Time { return c.now }

func poll(t *testing.T, e *Events, name string, arguments map[string]any, cursor any) (map[string]any, *rpcError) {
	t.Helper()
	params, _ := json.Marshal(map[string]any{"name": name, "arguments": arguments, "cursor": cursor})
	return e.Poll(context.Background(), params)
}

func mustPoll(t *testing.T, e *Events, name string, arguments map[string]any, cursor any) ([]map[string]any, string) {
	t.Helper()
	answer, err := poll(t, e, name, arguments, cursor)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	events := []map[string]any{}
	for _, ev := range answer["events"].([]any) {
		events = append(events, ev.(map[string]any))
	}
	return events, answer["cursor"].(string)
}

// An incident is raised once when it starts, and once when it is resolved; one already
// there at the first poll is not.
func TestAnIncidentIsRaisedOnceWhenItStartsAndWhenItEnds(t *testing.T) {
	f := newFakeBetterStack(t)
	c := &clock{now: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	f.add(fakeIncident{id: "1", monitor: "7", name: "web", started: c.now.Add(-5 * time.Minute)})
	e := &Events{Account: f.account(), Now: c.Now}

	events, started := mustPoll(t, e, IncidentStarted, nil, nil)
	if len(events) != 0 {
		t.Fatalf("the first poll raised %v", events)
	}
	_, resolved := mustPoll(t, e, IncidentResolved, nil, nil)
	c.now = c.now.Add(time.Minute)
	f.add(fakeIncident{id: "2", monitor: "7", name: "web", started: c.now.Add(-20 * time.Second)})
	events, started = mustPoll(t, e, IncidentStarted, nil, started)
	want := map[string]any{"team": "Acme", "startedAt": "2026-11-06T12:00:40Z",
		"incident": map[string]any{"id": "2", "name": "web", "cause": "Status 503", "url": "https://app.example.com/health", "monitor": "7"}}
	if len(events) != 1 || !reflect.DeepEqual(events[0]["data"], want) || events[0]["eventId"] != "health.incident_started:2" {
		t.Fatalf("events: %v", events)
	}
	c.now = c.now.Add(time.Minute)
	if events, _ = mustPoll(t, e, IncidentStarted, nil, started); len(events) != 0 {
		t.Fatalf("raised again: %v", events)
	}

	// The incident from before the first poll, and the new one, both end now.
	f.resolve("1", c.now.Add(-10*time.Second))
	f.resolve("2", c.now.Add(-5*time.Second))
	events, resolved = mustPoll(t, e, IncidentResolved, nil, resolved)
	if len(events) != 2 || events[0]["eventId"] != "health.incident_resolved:1" ||
		events[1]["data"].(map[string]any)["resolvedAt"] != "2026-11-06T12:01:55Z" {
		t.Fatalf("events: %v", events)
	}
	c.now = c.now.Add(time.Minute)
	if events, _ = mustPoll(t, e, IncidentResolved, nil, resolved); len(events) != 0 {
		t.Fatalf("resolved again: %v", events)
	}
}

// A resolved incident is found from the day 7 days before: one that started days ago and
// ends now is raised.
func TestALongIncidentIsRaisedWhenResolved(t *testing.T) {
	f := newFakeBetterStack(t)
	c := &clock{now: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	f.add(fakeIncident{id: "3", monitor: "7", name: "api", started: c.now.Add(-3 * 24 * time.Hour)})
	e := &Events{Account: f.account(), Now: c.Now}
	_, cursor := mustPoll(t, e, IncidentResolved, nil, nil)
	c.now = c.now.Add(time.Minute)
	f.resolve("3", c.now)
	events, _ := mustPoll(t, e, IncidentResolved, nil, cursor)
	if len(events) != 1 {
		t.Fatalf("events: %v", events)
	}
	if asked := f.asked[len(f.asked)-1]; !strings.Contains(asked, "from=2026-10-30") || !strings.Contains(asked, "resolved=true") {
		t.Fatalf("asked: %s", asked)
	}
}

// The monitor filter goes to Better Stack, and an argument it does not know is refused.
func TestTheMonitorFilter(t *testing.T) {
	f := newFakeBetterStack(t)
	c := &clock{now: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	args := map[string]any{"monitor": "8"}
	_, cursor := mustPoll(t, e, IncidentStarted, args, nil)
	f.add(fakeIncident{id: "4", monitor: "7", name: "web", started: c.now})
	f.add(fakeIncident{id: "5", monitor: "8", name: "api", started: c.now})
	c.now = c.now.Add(time.Minute)
	events, _ := mustPoll(t, e, IncidentStarted, args, cursor)
	if len(events) != 1 || events[0]["eventId"] != "health.incident_started:5" {
		t.Fatalf("events: %v", events)
	}
	if asked := f.asked[len(f.asked)-1]; !strings.Contains(asked, "monitor_id=8") || !strings.Contains(asked, "from=2026-11-06") {
		t.Fatalf("asked: %s", asked)
	}
	for _, bad := range []map[string]any{{"team": "x"}, {"monitor": "8&x=1"}, {"monitor": 8}} {
		if _, err := poll(t, e, IncidentStarted, bad, nil); err == nil || err.Code != -32602 {
			t.Fatalf("%v: %v", bad, err)
		}
	}
}

// More pages than one read follows is truncated; more than maxEvents waits for the next poll.
func TestPagesAndMoreThanOnePollsWorth(t *testing.T) {
	f := newFakeBetterStack(t)
	c := &clock{now: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	_, cursor := mustPoll(t, e, IncidentStarted, nil, nil)
	for i := range 60 {
		f.add(fakeIncident{id: strconv.Itoa(100 + i), monitor: "7", name: "web", started: c.now.Add(time.Duration(i) * time.Second)})
	}
	c.now = c.now.Add(2 * time.Minute)
	params, _ := json.Marshal(map[string]any{"name": IncidentStarted, "cursor": cursor, "maxEvents": 55})
	answer, err := e.Poll(context.Background(), params)
	if err != nil || len(answer["events"].([]any)) != 55 || answer["hasMore"] != true || answer["truncated"] != false {
		t.Fatalf("%v %v", answer, err)
	}
	events, _ := mustPoll(t, e, IncidentStarted, nil, answer["cursor"])
	if len(events) != 5 || events[4]["eventId"] != "health.incident_started:159" {
		t.Fatalf("events: %d", len(events))
	}
	for i := range maxPages * perPage {
		f.add(fakeIncident{id: strconv.Itoa(1000 + i), monitor: "7", name: "web", started: c.now})
	}
	if answer, err = poll(t, e, IncidentStarted, nil, nil); err != nil || answer["truncated"] != true {
		t.Fatalf("%v %v", answer["truncated"], err)
	}
}

// A next page on another host is not followed: the token stays with Better Stack.
func TestANextPageElsewhereIsNotFollowed(t *testing.T) {
	asked := 0
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { asked++ }))
	defer elsewhere.Close()
	bs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{}, "pagination": map[string]any{"next": elsewhere.URL + "/api/v3/incidents?page=2"}})
	}))
	defer bs.Close()
	a := &Account{Token: "bs_test", URL: bs.URL}
	if _, truncated, err := a.Incidents(context.Background(), time.Now(), "", false); err != nil || !truncated || asked != 0 {
		t.Fatalf("%v %v %d", truncated, err, asked)
	}
}

// With no token, or one Better Stack refuses, the events say not connected; a rate limit
// says when to try again.
func TestNotConnectedAndRefusals(t *testing.T) {
	f := newFakeBetterStack(t)
	e := &Events{Account: &Account{URL: f.server.URL}}
	if _, err := poll(t, e, IncidentStarted, nil, nil); err == nil || err.Code != -32012 {
		t.Fatalf("no token: %v", err)
	}
	e.Account.Token = "wrong"
	if _, err := poll(t, e, IncidentStarted, nil, nil); err == nil || err.Code != -32012 || strings.Contains(err.Message, "wrong") {
		t.Fatalf("refused: %v", err)
	}
	e.Account = f.account()
	f.status = http.StatusTooManyRequests
	if _, err := poll(t, e, IncidentStarted, nil, nil); err == nil || err.Code != -32013 {
		t.Fatalf("rate limit: %v", err)
	}
	if _, err := poll(t, e, "health.issue_new", nil, nil); err == nil || err.Code != -32011 {
		t.Fatalf("no such event: %v", err)
	}
	if _, err := poll(t, e, IncidentStarted, nil, "bm90IG91cnM"); err == nil || err.Code != -32602 {
		t.Fatalf("a foreign cursor: %v", err)
	}
}

// The front as the Agents daemon talks to it: initialize carries the events capability, and
// the events are listed and polled.
func TestTheFrontOffersTheEvents(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := newFakeBetterStack(t)
	front := &Front{Events: &Events{Account: f.account()}, Upstream: NewServer("test"), Version: "test",
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	clientIn, frontOut := io.Pipe()
	frontIn, clientOut := io.Pipe()
	go func() { _ = front.Serve(ctx, frontIn, frontOut); _ = frontOut.Close() }()
	defer clientOut.Close()
	lines := bufio.NewScanner(clientIn)
	lines.Buffer(nil, 16<<20)
	call := func(id int, method string, params any) map[string]any {
		t.Helper()
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		if _, err := clientOut.Write(append(data, '\n')); err != nil {
			t.Fatal(err)
		}
		for lines.Scan() {
			var reply map[string]any
			if err := json.Unmarshal(lines.Bytes(), &reply); err != nil {
				t.Fatalf("%s: %v", lines.Text(), err)
			}
			if reply["id"] == float64(id) {
				return reply
			}
		}
		t.Fatalf("%s: no answer (%v)", method, lines.Err())
		return nil
	}
	init := call(1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "test", "version": "1"}})["result"].(map[string]any)
	if init["capabilities"].(map[string]any)["events"] == nil || !strings.Contains(init["instructions"].(string), IncidentResolved) ||
		init["serverInfo"].(map[string]any)["name"] != "betterstack-mcp" {
		t.Fatalf("initialize: %v", init)
	}
	listed := call(2, "events/list", map[string]any{})["result"].(map[string]any)["events"].([]any)
	names := []string{}
	for _, ev := range listed {
		names = append(names, ev.(map[string]any)["name"].(string))
	}
	if !reflect.DeepEqual(names, EventNames()) {
		t.Fatalf("events/list: %v", names)
	}
	first := call(3, "events/poll", map[string]any{"name": IncidentStarted})["result"].(map[string]any)
	f.add(fakeIncident{id: "9", monitor: "7", name: "web", started: time.Now().UTC()})
	next := call(4, "events/poll", map[string]any{"name": IncidentStarted, "cursor": first["cursor"]})["result"].(map[string]any)
	if events := next["events"].([]any); len(events) != 1 || next["nextPollMs"] != float64(nextPollMs) {
		t.Fatalf("poll: %v", next)
	}
}
