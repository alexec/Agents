package sentrymcp

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// A fake Sentry API: an organization's issues, searched as Sentry searches them (only the
// parts the server sends), and each issue's own page.

type fakeIssue struct {
	Details
	regressed bool
}

type fakeSentry struct {
	t       *testing.T
	mu      sync.Mutex
	issues  []fakeIssue
	queries []string
	status  int
	server  *httptest.Server
}

func newFakeSentry(t *testing.T) *fakeSentry {
	f := &fakeSentry{t: t}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeSentry) account() *Account {
	return &Account{Token: "sntryu_test", Org: "acme", URL: f.server.URL}
}

func (f *fakeSentry) add(d Details, regressed bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.issues = append(f.issues, fakeIssue{Details: d, regressed: regressed})
}

func (f *fakeSentry) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer sntryu_test" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	const prefix = "/api/0/organizations/acme/issues/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if id := strings.Trim(strings.TrimPrefix(r.URL.Path, prefix), "/"); id != "" {
		for _, it := range f.issues {
			if it.ID == id {
				_ = json.NewEncoder(w).Encode(it.Details)
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
		return
	}
	query := r.URL.Query().Get("query")
	f.queries = append(f.queries, query)
	out := []Issue{}
	for _, it := range f.issues {
		if f.matches(it, query) {
			out = append(out, it.Issue)
		}
	}
	_ = json.NewEncoder(w).Encode(out)
}

// matches is Sentry's search, for the terms the server sends.
func (f *fakeSentry) matches(it fakeIssue, query string) bool {
	for _, term := range strings.Fields(query) {
		key, value, _ := strings.Cut(term, ":")
		switch key {
		case "is":
			if value == "regressed" && !it.regressed {
				return false
			}
		case "firstSeen", "lastSeen":
			at, err := time.Parse("2006-01-02T15:04:05", strings.TrimPrefix(value, ">="))
			if err != nil {
				f.t.Errorf("query %q: %v", query, err)
				return false
			}
			seen := it.FirstSeen
			if key == "lastSeen" {
				seen = it.LastSeen
			}
			if t, _ := parseTime(seen); t.Before(at) {
				return false
			}
		case "project":
			if it.Project.Slug != value {
				return false
			}
		case "level":
			if it.Level != value {
				return false
			}
		default:
			f.t.Errorf("query %q: unknown term %s", query, term)
		}
	}
	return true
}

func issue(id, project, level string, firstSeen time.Time, release string) Details {
	d := Details{Issue: Issue{ID: id, ShortID: strings.ToUpper(project) + "-" + id, Title: "TypeError: x is undefined",
		Culprit: "app/main.js", Level: level, Permalink: "https://acme.sentry.io/issues/" + id + "/",
		FirstSeen: firstSeen.Format(time.RFC3339Nano), LastSeen: firstSeen.Format(time.RFC3339Nano)}}
	d.Project.Slug = project
	if release != "" {
		d.FirstRelease = &Release{Version: release}
	}
	return d
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

// A new issue is raised once, with its release, and an issue already there at the first
// poll is not.
func TestANewIssueIsRaisedOnce(t *testing.T) {
	f := newFakeSentry(t)
	c := &clock{now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	f.add(issue("1", "web", "error", c.now.Add(-5*time.Minute), "web@1.0.0"), false)
	e := &Events{Account: f.account(), Now: c.Now}

	events, cursor := mustPoll(t, e, IssueNew, nil, nil)
	if len(events) != 0 {
		t.Fatalf("the first poll raised %v", events)
	}
	c.now = c.now.Add(time.Minute)
	f.add(issue("2", "web", "fatal", c.now.Add(-20*time.Second), "web@1.0.1"), false)
	events, cursor = mustPoll(t, e, IssueNew, nil, cursor)
	if len(events) != 1 {
		t.Fatalf("events: %v", events)
	}
	want := map[string]any{"org": "acme", "project": "web", "release": "web@1.0.1", "firstSeen": "2026-11-05T12:00:40Z",
		"issue": map[string]any{"id": "2", "shortId": "WEB-2", "title": "TypeError: x is undefined", "culprit": "app/main.js",
			"level": "fatal", "url": "https://acme.sentry.io/issues/2/"}}
	if got := events[0]["data"]; !reflect.DeepEqual(got, want) || events[0]["eventId"] != "health.issue_new:acme:2" {
		t.Fatalf("event: %v", events[0])
	}
	// Its envelope (#4728): the issue, and no key, as it is new once.
	if events[0]["subject"] != "sentry:issue:acme/web#2" || events[0]["key"] != nil {
		t.Fatalf("envelope: subject %v, key %v", events[0]["subject"], events[0]["key"])
	}
	c.now = c.now.Add(time.Minute)
	if events, _ = mustPoll(t, e, IssueNew, nil, cursor); len(events) != 0 {
		t.Fatalf("raised again: %v", events)
	}
}

// An issue whose first event comes in late, dated before the last poll, is still raised.
func TestALateIssueIsRaised(t *testing.T) {
	f := newFakeSentry(t)
	c := &clock{now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	_, cursor := mustPoll(t, e, IssueNew, nil, nil)
	c.now = c.now.Add(time.Minute)
	_, cursor = mustPoll(t, e, IssueNew, nil, cursor)
	f.add(issue("3", "ios", "error", c.now.Add(-10*time.Minute), ""), false)
	c.now = c.now.Add(time.Minute)
	events, _ := mustPoll(t, e, IssueNew, nil, cursor)
	if len(events) != 1 || events[0]["data"].(map[string]any)["release"] != "" {
		t.Fatalf("events: %v", events)
	}
}

// The filters go into Sentry's search and are checked again on what comes back.
func TestTheFiltersNarrowTheSearch(t *testing.T) {
	f := newFakeSentry(t)
	c := &clock{now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	args := map[string]any{"project": "ios", "level": "Fatal", "environment": "production"}
	_, cursor := mustPoll(t, e, IssueNew, args, nil)
	f.add(issue("4", "web", "fatal", c.now, ""), false)
	f.add(issue("5", "ios", "error", c.now, ""), false)
	f.add(issue("6", "ios", "fatal", c.now, ""), false)
	c.now = c.now.Add(time.Minute)
	events, _ := mustPoll(t, e, IssueNew, args, cursor)
	if len(events) != 1 || events[0]["eventId"] != "health.issue_new:acme:6" {
		t.Fatalf("events: %v", events)
	}
	if q := f.queries[len(f.queries)-1]; q != "firstSeen:>=2026-11-05T11:30:00 project:ios level:fatal" {
		t.Fatalf("query: %s", q)
	}
	for _, bad := range []map[string]any{{"level": "loud"}, {"team": "x"}, {"project": "ios OR web"}, {"project": 3}} {
		if _, err := poll(t, e, IssueNew, bad, nil); err == nil || err.Code != -32602 {
			t.Fatalf("%v: %v", bad, err)
		}
	}
}

// A regression is raised once, with the release it came back in; the same issue coming
// back again is a new event.
func TestARegressionIsRaisedOncePerRegression(t *testing.T) {
	f := newFakeSentry(t)
	c := &clock{now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	old := issue("7", "web", "error", c.now.Add(-48*time.Hour), "web@0.9.0")
	old.LastRelease = &Release{Version: "web@1.0.2"}
	f.add(old, false)
	_, cursor := mustPoll(t, e, IssueRegressed, nil, nil)

	c.now = c.now.Add(time.Minute)
	f.mu.Lock()
	f.issues[0].regressed = true
	f.issues[0].LastSeen = c.now.Format(time.RFC3339)
	f.issues[0].Activity = []Activity{{Type: "set_resolved", DateCreated: c.now.Add(-time.Hour).Format(time.RFC3339)},
		{Type: "set_regression", DateCreated: c.now.Add(-30 * time.Second).Format(time.RFC3339), Data: map[string]any{"version": "web@1.0.1"}}}
	f.mu.Unlock()
	events, cursor := mustPoll(t, e, IssueRegressed, nil, cursor)
	if len(events) != 1 {
		t.Fatalf("events: %v", events)
	}
	data := events[0]["data"].(map[string]any)
	if data["release"] != "web@1.0.1" || data["regressedAt"] != "2026-11-05T12:00:30Z" ||
		events[0]["eventId"] != "health.issue_regressed:acme:7@2026-11-05T12:00:30Z" {
		t.Fatalf("event: %v", events[0])
	}
	if events[0]["subject"] != "sentry:issue:acme/web#7" || events[0]["key"] != "2026-11-05T12:00:30Z" {
		t.Fatalf("envelope: subject %v, key %v", events[0]["subject"], events[0]["key"])
	}
	c.now = c.now.Add(time.Minute)
	if events, cursor = mustPoll(t, e, IssueRegressed, nil, cursor); len(events) != 0 {
		t.Fatalf("raised again: %v", events)
	}

	// Resolved again, then back once more, with no release in the activity: the last one's.
	c.now = c.now.Add(time.Hour)
	f.mu.Lock()
	f.issues[0].LastSeen = c.now.Format(time.RFC3339)
	f.issues[0].Activity = append(f.issues[0].Activity, Activity{Type: "set_regression", DateCreated: c.now.Format(time.RFC3339)})
	f.mu.Unlock()
	events, _ = mustPoll(t, e, IssueRegressed, nil, cursor)
	if len(events) != 1 || events[0]["data"].(map[string]any)["release"] != "web@1.0.2" {
		t.Fatalf("events: %v", events)
	}
}

// More than maxEvents waits for the next poll, and none is lost.
func TestMoreThanOnePollsWorthComesInTurn(t *testing.T) {
	f := newFakeSentry(t)
	c := &clock{now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	e := &Events{Account: f.account(), Now: c.Now}
	_, cursor := mustPoll(t, e, IssueNew, nil, nil)
	for i, id := range []string{"a", "b", "c"} {
		f.add(issue(id, "web", "error", c.now.Add(time.Duration(i)*time.Second), ""), false)
	}
	c.now = c.now.Add(time.Minute)
	params, _ := json.Marshal(map[string]any{"name": IssueNew, "cursor": cursor, "maxEvents": 2})
	answer, err := e.Poll(context.Background(), params)
	if err != nil || len(answer["events"].([]any)) != 2 || answer["hasMore"] != true {
		t.Fatalf("%v %v", answer, err)
	}
	events, _ := mustPoll(t, e, IssueNew, nil, answer["cursor"])
	if len(events) != 1 || events[0]["eventId"] != "health.issue_new:acme:c" {
		t.Fatalf("events: %v", events)
	}
}

// With no token, or one Sentry refuses, the events say not connected; a rate limit says when
// to try again.
func TestNotConnectedAndRefusals(t *testing.T) {
	f := newFakeSentry(t)
	e := &Events{Account: &Account{Org: "acme", URL: f.server.URL}}
	if _, err := poll(t, e, IssueNew, nil, nil); err == nil || err.Code != -32012 {
		t.Fatalf("no token: %v", err)
	}
	e.Account.Token = "wrong"
	if _, err := poll(t, e, IssueNew, nil, nil); err == nil || err.Code != -32012 || strings.Contains(err.Message, "wrong") {
		t.Fatalf("refused: %v", err)
	}
	e.Account = f.account()
	f.status = http.StatusTooManyRequests
	if _, err := poll(t, e, IssueNew, nil, nil); err == nil || err.Code != -32013 {
		t.Fatalf("rate limit: %v", err)
	}
	if _, err := poll(t, e, "health.deploy", nil, nil); err == nil || err.Code != -32011 {
		t.Fatalf("no such event: %v", err)
	}
	if _, err := poll(t, e, IssueNew, nil, "bm90IG91cnM"); err == nil || err.Code != -32602 {
		t.Fatalf("a foreign cursor: %v", err)
	}
}

// The front as the Agents daemon talks to it: initialize carries the events capability, and
// the events are listed and polled.
func TestTheFrontOffersTheEvents(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f := newFakeSentry(t)
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
	if init["capabilities"].(map[string]any)["events"] == nil || !strings.Contains(init["instructions"].(string), IssueRegressed) ||
		init["serverInfo"].(map[string]any)["name"] != "sentry-mcp" {
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
	first := call(3, "events/poll", map[string]any{"name": IssueNew})["result"].(map[string]any)
	f.add(issue("9", "web", "error", time.Now().UTC(), "web@2.0.0"), false)
	next := call(4, "events/poll", map[string]any{"name": IssueNew, "cursor": first["cursor"]})["result"].(map[string]any)
	if events := next["events"].([]any); len(events) != 1 || next["nextPollMs"] != float64(nextPollMs) {
		t.Fatalf("poll: %v", next)
	}
}
