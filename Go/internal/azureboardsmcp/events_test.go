package azureboardsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// The events (#3804) against the fake Azure DevOps over HTTP: each kind read from what Azure
// Boards keeps (a work item's dates, its updates, its comments), trust, the arguments, the
// cursor and the errors.

type poller struct {
	t      *testing.T
	events *Events
	name   string
	args   map[string]any
	cursor any
}

func newPoller(t *testing.T, f *fakeBoards, name string, args map[string]any) *poller {
	return &poller{t: t, events: &Events{Boards: f.boards(), Now: func() time.Time { return start }}, name: name, args: args}
}

// poll polls once and gives the events' ids and the answer.
func (p *poller) poll(maxEvents int) ([]string, map[string]any) {
	p.t.Helper()
	result, err := p.try(maxEvents)
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

func (p *poller) try(maxEvents int) (map[string]any, *rpcError) {
	params := map[string]any{"name": p.name, "arguments": p.args, "cursor": p.cursor}
	if maxEvents > 0 {
		params["maxEvents"] = maxEvents
	}
	raw, _ := json.Marshal(params)
	return p.events.Poll(context.Background(), raw)
}

// data is the data of the poll's events.
func data(result map[string]any) []map[string]any {
	var out []map[string]any
	for _, e := range result["events"].([]any) {
		out = append(out, e.(map[string]any)["data"].(map[string]any))
	}
	return out
}

func same(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestTheFirstPollStartsFromNowAndAsksNothing(t *testing.T) {
	f := newFake(t)
	f.item(1, "Old", "Bug", "New", alex, -5, nil)
	p := newPoller(t, f, "issue.opened", nil)
	ids, result := p.poll(0)
	same(t, ids, nil)
	if result["nextPollMs"] != nextPollMs || f.asked() != 0 {
		t.Fatalf("nextPollMs %v, asked %d", result["nextPollMs"], f.asked())
	}
	f.item(2, "Login fails", "Bug", "New", alex, 1, obj{fieldTags: "ui; urgent"})
	ids, result = p.poll(0)
	same(t, ids, []string{"issue.opened:2"})
	d := data(result)[0]
	issue := d["issue"].(map[string]any)
	if issue["id"] != float64(2) && issue["id"] != 2 || issue["key"] != "2" || issue["title"] != "Login fails" || issue["type"] != "Bug" ||
		issue["author"] != "alex@acme.test" || issue["area"] != `Web App\Team` || issue["url"] != f.server.URL+"/acme/Web%20App/_workitems/edit/2" ||
		strings.Join(issue["labels"].([]string), ",") != "ui,urgent" || d["openedAt"] != "2026-11-06T12:01:00.000Z" {
		t.Fatalf("data %v", d)
	}
	ids, _ = p.poll(0)
	same(t, ids, nil)
	if q := f.query(0); !strings.Contains(q, "[System.TeamProject] = 'Web App'") || !strings.Contains(q, "[System.CreatedDate] >= '2026-11-06T12:00:00.000Z'") {
		t.Fatalf("WIQL %s", q)
	}
}

func TestOnlyPeopleUnlessAnyone(t *testing.T) {
	f := newFake(t)
	own := newPoller(t, f, "issue.opened", nil)
	anyone := newPoller(t, f, "issue.opened", map[string]any{"anyone": true})
	own.poll(0)
	anyone.poll(0)
	f.item(3, "By a person", "Bug", "New", dev, 1, nil)
	f.item(4, "By the build", "Bug", "New", builder, 2, nil)
	ids, _ := own.poll(0)
	same(t, ids, []string{"issue.opened:3"})
	ids, _ = anyone.poll(0)
	same(t, ids, []string{"issue.opened:3", "issue.opened:4"})
}

// issue.labelled is one event per tag an update added, read from the work item's updates.
func TestATagAddedIsLabelledOncePerTag(t *testing.T) {
	f := newFake(t)
	f.item(5, "Story", "User Story", "New", alex, -10, obj{fieldTags: "ui"})
	p := newPoller(t, f, "issue.labelled", nil)
	p.poll(0)
	f.update(5, dev, 1, map[string][2]any{fieldTags: {"ui", "ui; agent; Urgent"}})
	f.update(5, dev, 2, map[string][2]any{fieldTags: {"ui; agent; Urgent", "agent"}}) // removed only
	f.update(5, builder, 3, map[string][2]any{fieldTags: {"agent", "agent; ci"}})     // a bot's
	ids, result := p.poll(0)
	same(t, ids, []string{"issue.labelled:5/2/agent", "issue.labelled:5/2/urgent"})
	if d := data(result)[0]; d["label"] != "agent" || d["by"] != "dev@acme.test" || d["labelledAt"] != "2026-11-06T12:01:00.000Z" {
		t.Fatalf("data %v", d)
	}
	ids, _ = p.poll(0)
	same(t, ids, nil)

	narrow := newPoller(t, f, "issue.labelled", map[string]any{"label": "ci", "anyone": true})
	narrow.events.Now = func() time.Time { return start.Add(10 * time.Minute) }
	narrow.poll(0)
	f.update(5, builder, 11, map[string][2]any{fieldTags: {"agent; ci", "agent; ci; ci2"}})
	f.update(5, builder, 12, map[string][2]any{fieldTags: {"agent; ci; ci2", "agent; ci; ci2; CI"}})
	ids, _ = narrow.poll(0)
	same(t, ids, nil) // ci2 is another tag, and CI was there already
}

// issue.closed is a move into a Completed or Removed state, from one that is not.
func TestAMoveToAClosedStateIsClosed(t *testing.T) {
	f := newFake(t)
	f.item(6, "Bug", "Bug", "Active", alex, -10, nil)
	f.item(7, "Story", "User Story", "Active", alex, -10, nil)
	p := newPoller(t, f, "issue.closed", nil)
	p.poll(0)
	f.update(6, dev, 1, map[string][2]any{fieldState: {"Active", "Resolved"}}) // Resolved is not closed
	f.update(6, dev, 2, map[string][2]any{fieldState: {"Resolved", "Closed"}})
	f.update(7, alex, 3, map[string][2]any{fieldState: {"Active", "Removed"}})
	f.update(7, alex, 4, map[string][2]any{fieldState: {"Removed", "Closed"}}) // closed already
	ids, result := p.poll(0)
	same(t, ids, []string{"issue.closed:6/3", "issue.closed:7/2"})
	if d := data(result)[0]; d["state"] != "Closed" || d["by"] != "dev@acme.test" || d["closedAt"] != "2026-11-06T12:02:00.000Z" {
		t.Fatalf("data %v", d)
	}
	f.update(6, dev, 5, map[string][2]any{fieldState: {"Closed", "Active"}})
	f.update(6, dev, 6, map[string][2]any{fieldState: {"Active", "Closed"}})
	ids, _ = p.poll(0)
	same(t, ids, []string{"issue.closed:6/5"}) // reopened and closed again is a new one
}

func TestACommentIsCommented(t *testing.T) {
	f := newFake(t)
	f.item(8, "Bug", "Bug", "Active", alex, -10, nil)
	f.comment(8, 70, dev, -3, "before")
	p := newPoller(t, f, "issue.commented", nil)
	p.poll(0)
	f.comment(8, 71, dev, 1, "<p>"+strings.Repeat("x", commentChars+10)+"</p>")
	f.comment(8, 72, builder, 2, "a bot's")
	ids, result := p.poll(0)
	same(t, ids, []string{"issue.commented:8/71"})
	d := data(result)[0]
	c := d["comment"].(map[string]any)
	if c["author"] != "dev@acme.test" || len([]rune(c["body"].(string))) != commentChars+1 || d["commentedAt"] != "2026-11-06T12:01:00.000Z" ||
		c["url"] != f.server.URL+"/acme/Web%20App/_workitems/edit/8" {
		t.Fatalf("data %v", d)
	}
}

// issue.assigned (#2034) is the person's own: a bot assigning it counts, and one made already
// assigned to the person counts too.
func TestAssignedToMeIsRaisedWhoeverAssignedIt(t *testing.T) {
	f := newFake(t)
	f.item(9, "Bug", "Bug", "Active", dev, -10, nil)
	p := newPoller(t, f, "issue.assigned", nil)
	p.poll(0)
	f.update(9, builder, 1, map[string][2]any{fieldAssigned: {nil, alex}})
	f.update(9, dev, 2, map[string][2]any{fieldTags: {nil, "x"}}) // no change of assignee
	f.update(9, dev, 3, map[string][2]any{fieldAssigned: {alex, dev}})
	it := f.item(10, "Made mine", "Bug", "New", dev, 4, obj{fieldAssigned: alex})
	f.set(func() { it.updates[0]["fields"].(obj)[fieldAssigned] = obj{"newValue": alex} })
	ids, result := p.poll(0)
	same(t, ids, []string{"issue.assigned:9/2", "issue.assigned:10/1"})
	if d := data(result)[0]; d["by"] != "Project Collection Build Service (acme)" {
		t.Fatalf("data %v", d)
	}
}

func TestAreaTypeLabelAndIssueNarrow(t *testing.T) {
	f := newFake(t)
	area := newPoller(t, f, "issue.opened", map[string]any{"area": `web app\team\`})
	kind := newPoller(t, f, "issue.opened", map[string]any{"type": "user story"})
	label := newPoller(t, f, "issue.opened", map[string]any{"label": "Agent"})
	for _, p := range []*poller{area, kind, label} {
		p.poll(0)
	}
	f.item(11, "In the team", "Bug", "New", alex, 1, obj{fieldArea: `Web App\Team\Mobile`})
	f.item(12, "Next door", "Bug", "New", alex, 2, obj{fieldArea: `Web App\Teams`})
	f.item(13, "A story", "User Story", "New", alex, 3, obj{fieldTags: "agent", fieldArea: "Web App"})
	ids, _ := area.poll(0)
	same(t, ids, []string{"issue.opened:11"})
	ids, _ = kind.poll(0)
	same(t, ids, []string{"issue.opened:13"})
	ids, _ = label.poll(0)
	same(t, ids, []string{"issue.opened:13"})

	one := newPoller(t, f, "issue.commented", map[string]any{"issue": "12"})
	one.poll(0)
	f.comment(11, 80, alex, 5, "on 11")
	f.comment(12, 81, alex, 6, "on 12")
	ids, _ = one.poll(0)
	same(t, ids, []string{"issue.commented:12/81"})
}

// A lead waits on all its open children at once (#3797).
func TestIssueTakesAList(t *testing.T) {
	f := newFake(t)
	both := newPoller(t, f, "issue.commented", map[string]any{"issue": []any{"11", "13"}, "any": true})
	both.poll(0)
	f.item(11, "One", "Bug", "New", alex, 1, nil)
	f.item(12, "Two", "Bug", "New", alex, 2, nil)
	f.item(13, "Three", "Bug", "New", alex, 3, nil)
	f.comment(11, 82, alex, 7, "on 11")
	f.comment(12, 83, alex, 8, "on 12")
	f.comment(13, 84, alex, 9, "on 13")
	ids, _ := both.poll(0)
	same(t, ids, []string{"issue.commented:11/82", "issue.commented:13/84"})
}

// #3797: issue.closed, issue.commented and issue.labelled take any and a list of issues; the
// others take neither.
func TestEventsListGivesWhichArgumentsNameOne(t *testing.T) {
	for _, e := range eventsList()["events"].([]any) {
		e := e.(map[string]any)
		name := e["name"].(string)
		props := e["inputSchema"].(map[string]any)["properties"].(map[string]any)
		named := name == "issue.closed" || name == "issue.commented" || name == "issue.labelled"
		if _, hasAny := props["any"]; hasAny != named {
			t.Fatalf("%s: any %v", name, hasAny)
		}
		if issue, ok := props["issue"].(map[string]any); ok && fmt.Sprint(issue["type"]) != "[string array]" {
			t.Fatalf("%s: issue %v", name, issue)
		}
	}
}

func TestEventsAtOneTimeAreNeitherLostNorRaisedTwice(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	for id := 20; id < 23; id++ {
		f.item(id, "Same minute", "Bug", "New", alex, 1, nil)
	}
	ids, result := p.poll(2)
	same(t, ids, []string{"issue.opened:20", "issue.opened:21"})
	if result["hasMore"] != true {
		t.Fatal("hasMore")
	}
	ids, _ = p.poll(2)
	same(t, ids, []string{"issue.opened:22"})
	ids, _ = p.poll(2)
	same(t, ids, nil)
}

func TestArgumentsAreChecked(t *testing.T) {
	e := &Events{Boards: newFake(t).boards()}
	for _, c := range []struct{ params, want string }{
		{`{"name":"issue.reopened"}`, "no event issue.reopened"},
		{`{"name":"issue.opened","arguments":{"project":"Web"}}`, "unknown argument project; takes area, type, label, anyone"},
		{`{"name":"issue.opened","arguments":{"issue":"1"}}`, "unknown argument issue"},
		{`{"name":"issue.labelled","arguments":{"issue":"ENG-1"}}`, "issue must be a work item's id, as 12, or a list of them"},
		{`{"name":"issue.closed","arguments":{"issue":[]}}`, "issue must be a work item's id, as 12, or a list of them"},
		{`{"name":"issue.closed","arguments":{"issue":12}}`, "issue must be a work item's id, as 12, or a list of them"},
		{`{"name":"issue.closed","arguments":{"any":"yes"}}`, "any must be true or false"},
		{`{"name":"issue.assigned","arguments":{"label":"x"}}`, "unknown argument label"},
		{`{"name":"issue.closed","arguments":{"anyone":"yes"}}`, "anyone must be true or false"},
		{`{"name":"issue.closed","cursor":"nope"}`, "cursor is not one this server gave"},
	} {
		_, err := e.Poll(context.Background(), json.RawMessage(c.params))
		if err == nil || !strings.Contains(err.Message, c.want) {
			t.Errorf("%s: got %v, want %q", c.params, err, c.want)
		}
	}
}

func TestNoTokenASignInPageAndALimitAreTheDraftsCodes(t *testing.T) {
	f := newFake(t)
	e := &Events{Boards: f.boards(), SignedIn: func() bool { return false }}
	if _, err := e.Poll(context.Background(), json.RawMessage(`{"name":"issue.opened"}`)); err == nil || err.Code != -32012 {
		t.Fatalf("no token: %v", err)
	}
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	f.set(func() { f.signIn = true })
	if _, err := p.try(0); err == nil || err.Code != -32012 || !strings.Contains(err.Message, "Work Items (read and write)") {
		t.Fatalf("sign-in page: %v", err)
	}
	f.set(func() { f.signIn, f.status = false, 429 })
	if _, err := p.try(0); err == nil || err.Code != -32013 || err.Data["retryAfterMs"] != 7000 {
		t.Fatalf("rate limited: %v", err)
	}
}

func TestEventsListOffersTheFive(t *testing.T) {
	var names []string
	for _, e := range eventsList()["events"].([]any) {
		m := e.(map[string]any)
		names = append(names, m["name"].(string))
		if _, err := json.Marshal(m); err != nil {
			t.Fatal(err)
		}
	}
	same(t, names, []string{"issue.opened", "issue.labelled", "issue.commented", "issue.closed", "issue.assigned"})
	same(t, EventNames(), names)
}

// Each poll's reads are bounded: the maxChecked work items changed last, and a work item's
// updates at most maxPages pages.
func TestAPollReadsTheWorkItemsChangedLastOnly(t *testing.T) {
	f := newFake(t)
	p := newPoller(t, f, "issue.opened", nil)
	p.poll(0)
	for id := 100; id < 100+maxChecked+3; id++ {
		f.item(id, "Many", "Bug", "New", alex, 1+id-100, nil)
	}
	ids, result := p.poll(100)
	if len(ids) != maxChecked || result["truncated"] != true || ids[0] != "issue.opened:103" {
		t.Fatalf("%d events, truncated %v, first %v", len(ids), result["truncated"], ids[0])
	}
}

func TestProjectIsOrganizationAndProject(t *testing.T) {
	ctx := context.Background()
	if got, err := ProjectOf("", " acme/Web App/ ")(ctx); err != nil || got != "acme/Web App" {
		t.Fatalf("%q %v", got, err)
	}
	for _, bad := range []string{"acme", "acme/Web/app", "/Web"} {
		if _, err := ProjectOf("", bad)(ctx); err == nil || !strings.Contains(err.Error(), "organization/project") {
			t.Errorf("%s: %v", bad, err)
		}
	}
}

// Each event names its work item as its subject, and a comment by its own id (#4728).
func TestAnEventSaysItsSubjectAndKey(t *testing.T) {
	f := newFake(t)
	opened := newPoller(t, f, "issue.opened", nil)
	opened.poll(0)
	f.item(8, "Bug", "Bug", "Active", alex, 1, nil)
	_, result := opened.poll(0)
	e := result["events"].([]any)[0].(map[string]any)
	if e["subject"] != "azureboards:issue:acme/web app#8" || e["key"] != nil {
		t.Fatalf("opened: subject %v, key %v", e["subject"], e["key"])
	}
	commented := newPoller(t, f, "issue.commented", nil)
	commented.poll(0)
	f.comment(8, 71, dev, 2, "hello")
	_, result = commented.poll(0)
	e = result["events"].([]any)[0].(map[string]any)
	if e["subject"] != "azureboards:issue:acme/web app#8" || e["key"] != "8/71" {
		t.Fatalf("commented: subject %v, key %v", e["subject"], e["key"])
	}
}
