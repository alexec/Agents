package linearmcp

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

// The events over a fake Linear held in memory: the github server's cases, for Linear.

type fakeLinear struct {
	mu       sync.Mutex
	activity []Activity
	err      error
	asked    []string // team of each Activity call
}

func (f *fakeLinear) add(a Activity) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.activity = append(f.activity, a)
}

func (f *fakeLinear) Activity(_ context.Context, kind Kind, team, since string) ([]Activity, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, team)
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
	guest  = &Person{Name: "Visitor", Guest: true}
	bot    = &Person{Name: "Slack", App: true}
)

func issue(identifier, team string, labels ...string) Issue {
	return Issue{ID: "id-" + identifier, Identifier: identifier, Title: "Issue " + identifier, Team: team, State: "Todo",
		StateType: "unstarted", Labels: labels, URL: "https://linear.app/alexec-agents/issue/" + identifier, Creator: member}
}

var start = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)

func at(minutes int) string { return timeString(start.Add(time.Duration(minutes) * time.Minute)) }

type poller struct {
	t      *testing.T
	events *Events
	name   string
	args   map[string]any
	cursor any
}

func newPoller(t *testing.T, f *fakeLinear, name string, args map[string]any) *poller {
	return &poller{t: t, events: &Events{Linear: f, Now: func() time.Time { return start }}, name: name, args: args}
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
	f := &fakeLinear{}
	f.add(Activity{ID: "id-ENG-1", At: at(-5), Issue: issue("ENG-1", "ENG"), Kind: Opened})
	p := newPoller(t, f, "issue.opened", nil)
	ids, result := p.poll(0)
	same(t, ids, nil)
	if result["nextPollMs"] != nextPollMs {
		t.Fatalf("nextPollMs %v", result["nextPollMs"])
	}
	if len(f.asked) != 0 {
		t.Fatal("a first poll asks Linear nothing")
	}
	f.add(Activity{ID: "id-ENG-2", At: at(1), Issue: issue("ENG-2", "ENG"), Kind: Opened})
	ids, _ = p.poll(0)
	same(t, ids, []string{"issue.opened:id-ENG-2"})
	ids, _ = p.poll(0)
	same(t, ids, nil)
}

func TestOnlyTheWorkspacesOwnUnlessAnyone(t *testing.T) {
	f := &fakeLinear{}
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

func TestTeamLabelAndIssueNarrow(t *testing.T) {
	f := &fakeLinear{}
	p := newPoller(t, f, "issue.labelled", map[string]any{"team": "eng", "label": "bug"})
	one := newPoller(t, f, "issue.closed", map[string]any{"issue": "eng-2", "label": "Bug"})
	p.poll(0)
	one.poll(0)
	f.add(Activity{ID: "h1:bug", At: at(1), Issue: issue("ENG-2", "ENG", "bug"), Kind: Labelled, By: member, Label: "bug"})
	f.add(Activity{ID: "h2:docs", At: at(2), Issue: issue("ENG-2", "ENG", "bug", "docs"), Kind: Labelled, By: member, Label: "docs"})
	f.add(Activity{ID: "h3:bug", At: at(3), Issue: issue("OPS-1", "OPS", "bug"), Kind: Labelled, By: member, Label: "bug"})
	f.add(Activity{ID: "h4", At: at(4), Issue: issue("ENG-2", "ENG", "bug"), Kind: Closed, By: member, Reason: "completed"})
	f.add(Activity{ID: "h5", At: at(5), Issue: issue("ENG-3", "ENG", "bug"), Kind: Closed, By: member, Reason: "canceled"})
	ids, _ := p.poll(0)
	same(t, ids, []string{"issue.labelled:h1:bug"})
	if f.asked[len(f.asked)-1] != "ENG" {
		t.Fatalf("team asked of Linear: %v", f.asked)
	}
	ids, result := one.poll(0)
	same(t, ids, []string{"issue.closed:h4"})
	data := result["events"].([]any)[0].(map[string]any)["data"].(map[string]any)
	if data["reason"] != "completed" || data["by"] != "Alex" || data["closedAt"] != at(4) {
		t.Fatalf("data %v", data)
	}
}

func TestEventsAtOneTimeAreNeitherLostNorRaisedTwice(t *testing.T) {
	f := &fakeLinear{}
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
	e := &Events{Linear: &fakeLinear{}}
	for _, c := range []struct{ params, want string }{
		{`{"name":"issue.reopened"}`, "no event issue.reopened"},
		{`{"name":"issue.opened","arguments":{"repo":"a/b"}}`, "unknown argument repo; takes team, label, anyone"},
		{`{"name":"issue.opened","arguments":{"issue":"ENG-1"}}`, "unknown argument issue"},
		{`{"name":"issue.closed","arguments":{"issue":"12"}}`, "issue must look like an issue identifier"},
		{`{"name":"issue.closed","arguments":{"team":"E N G"}}`, "team must look like a team key"},
		{`{"name":"issue.closed","arguments":{"anyone":"yes"}}`, "anyone must be true or false"},
		{`{"name":"issue.closed","cursor":"nope"}`, "cursor is not one this server gave"},
	} {
		_, err := e.Poll(context.Background(), json.RawMessage(c.params))
		if err == nil || !strings.Contains(err.Message, c.want) {
			t.Errorf("%s: got %v, want %q", c.params, err, c.want)
		}
	}
}

func TestNoKeyAndLinearsFailuresAreTheDraftsCodes(t *testing.T) {
	e := &Events{Linear: &fakeLinear{}, SignedIn: func() bool { return false }}
	_, err := e.Poll(context.Background(), json.RawMessage(`{"name":"issue.opened"}`))
	if err == nil || err.Code != -32012 {
		t.Fatalf("no key: %v", err)
	}
	f := &fakeLinear{}
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	f.err = &LinearError{Kind: RateLimited, Message: "slow down", RetryAfterMs: 1234}
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
	same(t, names, []string{"issue.opened", "issue.labelled", "issue.commented", "issue.closed", "issue.assigned"})
}

// issue.assigned (#2034) is the person's own: a guest or an app assigning it counts.
func TestAssignedToMeIsRaisedWhoeverAssignedIt(t *testing.T) {
	f := &fakeLinear{}
	p := newPoller(t, f, "issue.assigned", nil)
	p.poll(0)
	f.add(Activity{ID: "h9", At: at(1), Issue: issue("ENG-9", "ENG"), Kind: Assigned, By: bot})
	ids, _ := p.poll(0)
	same(t, ids, []string{"issue.assigned:h9"})
}
