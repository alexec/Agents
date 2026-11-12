package jiramcp

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The events over a fake Jira held in memory: the linear server's cases, for Jira.

type fakeJira struct {
	mu       sync.Mutex
	activity []Activity
	err      error
	asked    []string // project of each Activity call
}

func (f *fakeJira) add(a Activity) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.activity = append(f.activity, a)
}

func (f *fakeJira) Activity(_ context.Context, kind Kind, project, since string) ([]Activity, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, project)
	if f.err != nil {
		return nil, false, f.err
	}
	var out []Activity
	for _, a := range f.activity {
		if a.Kind == kind && !before(a.At, since) {
			out = append(out, a)
		}
	}
	return out, false, nil
}

var (
	member = &Person{Name: "Alex"}
	guest  = &Person{Name: "Visitor", Customer: true}
	bot    = &Person{Name: "Slack", App: true}
)

func issue(key, project string, labels ...string) Issue {
	return Issue{ID: "id-" + key, Key: key, Title: "Issue " + key, Project: project, Status: "To Do",
		StatusCategory: "new", Labels: labels, URL: "https://example.atlassian.net/browse/" + key, Creator: member}
}

var start = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)

func at(minutes int) string {
	return mcpevents.TimeString(start.Add(time.Duration(minutes) * time.Minute))
}

type poller struct {
	t      *testing.T
	events *Events
	name   string
	args   map[string]any
	cursor any
}

func newPoller(t *testing.T, f *fakeJira, name string, args map[string]any) *poller {
	return &poller{t: t, events: &Events{Jira: f, Now: func() time.Time { return start }}, name: name, args: args}
}

// poll polls once and gives the events' ids and the answer.
func (p *poller) poll(maxEvents int) ([]string, map[string]any) {
	p.t.Helper()
	params := map[string]any{"name": p.name, "arguments": p.args, "cursor": p.cursor}
	if maxEvents > 0 {
		params["maxEvents"] = maxEvents
	}
	raw, _ := json.Marshal(params)
	result, err := p.events.Poll(context.Background(), raw)
	if err != nil {
		p.t.Fatalf("poll %s: %v", p.name, err)
	}
	p.cursor = result["cursor"]
	var ids []string
	for _, e := range result["events"].([]any) {
		ids = append(ids, e.(map[string]any)["eventId"].(string))
	}
	return ids, result
}

func same(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestTheFirstPollStartsFromNow(t *testing.T) {
	f := &fakeJira{}
	f.add(Activity{ID: "id-ENG-1", At: at(-5), Issue: issue("ENG-1", "ENG"), Kind: Opened})
	p := newPoller(t, f, "issue.opened", nil)
	ids, result := p.poll(0)
	same(t, ids, nil)
	if result["nextPollMs"] != nextPollMs {
		t.Fatalf("nextPollMs %v", result["nextPollMs"])
	}
	if len(f.asked) != 0 {
		t.Fatal("a first poll asks Jira nothing")
	}
	f.add(Activity{ID: "id-ENG-2", At: at(1), Issue: issue("ENG-2", "ENG"), Kind: Opened})
	ids, _ = p.poll(0)
	same(t, ids, []string{"issue.opened:id-ENG-2"})
	ids, _ = p.poll(0)
	same(t, ids, nil)
}

func TestOnlyTheSitesOwnUnlessAnyone(t *testing.T) {
	f := &fakeJira{}
	byGuest, byBot := issue("ENG-3", "ENG"), issue("ENG-4", "ENG")
	byGuest.Creator, byBot.Creator = guest, bot
	own := newPoller(t, f, "issue.opened", nil)
	anyone := newPoller(t, f, "issue.opened", map[string]any{"anyone": true})
	own.poll(0)
	anyone.poll(0)
	f.add(Activity{ID: "id-ENG-2", At: at(1), Issue: issue("ENG-2", "ENG"), Kind: Opened})
	f.add(Activity{ID: "id-ENG-3", At: at(2), Issue: byGuest, Kind: Opened})
	f.add(Activity{ID: "id-ENG-4", At: at(3), Issue: byBot, Kind: Opened})
	ids, _ := own.poll(0)
	same(t, ids, []string{"issue.opened:id-ENG-2"})
	ids, _ = anyone.poll(0)
	same(t, ids, []string{"issue.opened:id-ENG-2", "issue.opened:id-ENG-3", "issue.opened:id-ENG-4"})

	commented := newPoller(t, f, "issue.commented", nil)
	commented.poll(0)
	f.add(Activity{ID: "c1", At: at(4), Issue: issue("ENG-2", "ENG"), Kind: Commented, By: bot, CommentBody: "bot"})
	f.add(Activity{ID: "c2", At: at(5), Issue: issue("ENG-2", "ENG"), Kind: Commented, By: member, CommentBody: "hi"})
	ids, result := commented.poll(0)
	same(t, ids, []string{"issue.commented:c2"})
	data := result["events"].([]any)[0].(map[string]any)["data"].(map[string]any)
	if data["comment"].(map[string]any)["author"] != "Alex" || data["commentedAt"] != at(5) {
		t.Fatalf("data %v", data)
	}
}

func TestProjectLabelAndIssueNarrow(t *testing.T) {
	f := &fakeJira{}
	p := newPoller(t, f, "issue.labelled", map[string]any{"project": "eng", "label": "bug"})
	one := newPoller(t, f, "issue.commented", map[string]any{"issue": "eng-2", "label": "Bug"})
	p.poll(0)
	one.poll(0)
	f.add(Activity{ID: "h1:bug", At: at(1), Issue: issue("ENG-2", "ENG", "bug"), Kind: Labelled, By: member, Label: "bug"})
	f.add(Activity{ID: "h2:docs", At: at(2), Issue: issue("ENG-2", "ENG", "bug", "docs"), Kind: Labelled, By: member, Label: "docs"})
	f.add(Activity{ID: "h3:bug", At: at(3), Issue: issue("OPS-1", "OPS", "bug"), Kind: Labelled, By: member, Label: "bug"})
	f.add(Activity{ID: "c4", At: at(4), Issue: issue("ENG-2", "ENG", "bug"), Kind: Commented, By: member, CommentBody: "on it"})
	f.add(Activity{ID: "c5", At: at(5), Issue: issue("ENG-3", "ENG", "bug"), Kind: Commented, By: member, CommentBody: "not this one"})
	ids, _ := p.poll(0)
	same(t, ids, []string{"issue.labelled:h1:bug"})
	if f.asked[len(f.asked)-1] != "ENG" {
		t.Fatalf("project asked of Jira: %v", f.asked)
	}
	ids, result := one.poll(0)
	same(t, ids, []string{"issue.commented:c4"})
	data := result["events"].([]any)[0].(map[string]any)["data"].(map[string]any)
	if data["comment"].(map[string]any)["body"] != "on it" || data["commentedAt"] != at(4) || data["issue"].(map[string]any)["key"] != "ENG-2" {
		t.Fatalf("data %v", data)
	}
}

func TestEventsAtOneTimeAreNeitherLostNorRaisedTwice(t *testing.T) {
	f := &fakeJira{}
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	for _, id := range []string{"ENG-1", "ENG-2", "ENG-3"} {
		f.add(Activity{ID: "id-" + id, At: at(1), Issue: issue(id, "ENG"), Kind: Opened})
	}
	ids, result := p.poll(2)
	same(t, ids, []string{"issue.opened:id-ENG-1", "issue.opened:id-ENG-2"})
	if result["hasMore"] != true {
		t.Fatal("hasMore")
	}
	ids, result = p.poll(2)
	same(t, ids, []string{"issue.opened:id-ENG-3"})
	if result["hasMore"] != false {
		t.Fatal("no more")
	}
	ids, _ = p.poll(2)
	same(t, ids, nil)
}

func TestArgumentsAreChecked(t *testing.T) {
	e := &Events{Jira: &fakeJira{}}
	for _, c := range []struct{ params, want string }{
		{`{"name":"issue.reopened"}`, "no event issue.reopened"},
		{`{"name":"issue.closed"}`, "no event issue.closed"},
		{`{"name":"issue.opened","arguments":{"team":"ENG"}}`, "unknown argument team; takes project, label, anyone"},
		{`{"name":"issue.opened","arguments":{"issue":"ENG-1"}}`, "unknown argument issue"},
		{`{"name":"issue.labelled","arguments":{"issue":"12"}}`, "issue must look like an issue key"},
		{`{"name":"issue.labelled","arguments":{"project":"E N G"}}`, "project must look like a project key"},
		{`{"name":"issue.labelled","arguments":{"anyone":"yes"}}`, "anyone must be true or false"},
		{`{"name":"issue.labelled","cursor":"nope"}`, "cursor is not one this server gave"},
	} {
		_, err := e.Poll(context.Background(), json.RawMessage(c.params))
		if err == nil || !strings.Contains(err.Message, c.want) {
			t.Errorf("%s: got %v, want %q", c.params, err, c.want)
		}
	}
}

func TestNoTokenAndJirasFailuresAreTheDraftsCodes(t *testing.T) {
	e := &Events{Jira: &fakeJira{}, SignedIn: func() bool { return false }}
	_, err := e.Poll(context.Background(), json.RawMessage(`{"name":"issue.opened"}`))
	if err == nil || err.Code != -32012 {
		t.Fatalf("no key: %v", err)
	}
	f := &fakeJira{}
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	f.err = &JiraError{Kind: RateLimited, Message: "slow down", RetryAfterMs: 1234}
	raw, _ := json.Marshal(map[string]any{"name": "issue.opened", "cursor": p.cursor})
	_, err = p.events.Poll(context.Background(), raw)
	if err == nil || err.Code != -32013 || err.Data["retryAfterMs"] != 1234 {
		t.Fatalf("rate limited: %v", err)
	}
}

func TestEventsListOffersTheFour(t *testing.T) {
	list := eventsList()["events"].([]any)
	var names []string
	for _, e := range list {
		m := e.(map[string]any)
		names = append(names, m["name"].(string))
		if _, err := json.Marshal(m); err != nil {
			t.Fatal(err)
		}
	}
	same(t, names, []string{"issue.opened", "issue.labelled", "issue.commented", "issue.assigned"})
}

// issue.assigned (#2034) is the person's own: a customer or an app assigning it counts.
func TestAssignedToMeIsRaisedWhoeverAssignedIt(t *testing.T) {
	f := &fakeJira{}
	p := newPoller(t, f, "issue.assigned", nil)
	p.poll(0)
	f.add(Activity{ID: "h9", At: at(1), Issue: issue("ENG-9", "ENG"), Kind: Assigned, By: bot})
	ids, _ := p.poll(0)
	same(t, ids, []string{"issue.assigned:h9"})
}

// Each event names its issue as its subject, and a comment by its own id (#4728).
func TestAnEventSaysItsSubjectAndKey(t *testing.T) {
	f := &fakeJira{}
	opened := newPoller(t, f, "issue.opened", nil)
	commented := newPoller(t, f, "issue.commented", nil)
	opened.poll(0)
	commented.poll(0)
	f.add(Activity{ID: "id-ENG-2", At: at(1), Issue: issue("ENG-2", "ENG"), Kind: Opened})
	f.add(Activity{ID: "c2", At: at(2), Issue: issue("ENG-2", "ENG"), Kind: Commented, By: member, CommentBody: "hi"})
	_, result := opened.poll(0)
	e := result["events"].([]any)[0].(map[string]any)
	if e["subject"] != "jira:issue:eng#ENG-2" || e["key"] != nil {
		t.Fatalf("opened: subject %v, key %v", e["subject"], e["key"])
	}
	_, result = commented.poll(0)
	e = result["events"].([]any)[0].(map[string]any)
	if e["subject"] != "jira:issue:eng#ENG-2" || e["key"] != "c2" {
		t.Fatalf("commented: subject %v, key %v", e["subject"], e["key"])
	}
}
