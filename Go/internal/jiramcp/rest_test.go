package jiramcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// RealJira over a fake site: Jira Cloud's answers (accountId, /search/jql) and Data Center's
// (name, /search), in the shapes Jira's REST API version 2 gives.

type fakeSite struct {
	mu     sync.Mutex
	asked  []string         // method and path of each request
	bodies []map[string]any // each request's body, or nil
	auth   []string
	status int
	header http.Header
	answer func(path string, body map[string]any) any
}

func (f *fakeSite) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	_ = json.Unmarshal(raw, &body)
	path := strings.TrimPrefix(r.URL.Path, "/rest/api/2")
	if r.URL.RawQuery != "" {
		path += "?" + r.URL.RawQuery
	}
	f.mu.Lock()
	f.asked = append(f.asked, r.Method+" "+path)
	f.bodies = append(f.bodies, body)
	f.auth = append(f.auth, r.Header.Get("Authorization"))
	status, header := f.status, f.header
	f.mu.Unlock()
	for k, v := range header {
		w.Header()[k] = v
	}
	if status != 0 {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"errorMessages":["The value 'NOPE' does not exist for the field 'project'."],"errors":{}}`))
		return
	}
	_ = json.NewEncoder(w).Encode(f.answer(path, body))
}

func newSite(t *testing.T, cloud bool, answer func(path string, body map[string]any) any) (*fakeSite, *RealJira) {
	t.Helper()
	f := &fakeSite{answer: answer}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	email := ""
	if cloud {
		email = "alex@example.com"
	}
	j := NewRealJira(func() Auth { return TokenAuth(srv.URL+"/", email, "tok") })
	j.sharing = 0
	return f, j
}

var (
	alexUser = map[string]any{"accountId": "u1", "displayName": "Alex", "emailAddress": "alex@example.com", "accountType": "atlassian",
		"avatarUrls": map[string]any{"16x16": "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/u1/16", "48x48": "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/u1/48"}}
	appUser = map[string]any{"accountId": "app1", "displayName": "Automation for Jira", "accountType": "app"}
)

func restIssueJSON(key, created string, extra map[string]any) map[string]any {
	f := map[string]any{"summary": "Issue " + key, "status": map[string]any{"name": "To Do", "statusCategory": map[string]any{"key": "new"}},
		"labels": []any{"bug"}, "creator": alexUser, "created": created, "updated": created, "project": map[string]any{"key": "ENG"},
		"priority": map[string]any{"name": "High"}}
	for k, v := range extra {
		f[k] = v
	}
	return map[string]any{"id": "1" + strings.TrimPrefix(key, "ENG-"), "key": key, "fields": f}
}

func TestTokenAuthIsBasicOnCloudAndBearerOnDataCenter(t *testing.T) {
	cloud := TokenAuth(" https://example.atlassian.net/ ", "alex@example.com", "tok")
	if !cloud.Cloud || cloud.Site != "https://example.atlassian.net" || cloud.Header != "Basic YWxleEBleGFtcGxlLmNvbTp0b2s=" {
		t.Fatalf("cloud %+v", cloud)
	}
	dc := TokenAuth("https://jira.example.com", "", "pat")
	if dc.Cloud || dc.Header != "Bearer pat" {
		t.Fatalf("data center %+v", dc)
	}
	if TokenAuth("https://jira.example.com", "", "").signedIn() || TokenAuth("", "a", "b").signedIn() {
		t.Fatal("no site or no token is not signed in")
	}
}

func TestOpenedIsReadByMinutesAgoAndCheckedToTheMillisecond(t *testing.T) {
	since := time.Now().Add(-9*time.Minute - 30*time.Second)
	f, j := newSite(t, true, func(string, map[string]any) any {
		return map[string]any{"issues": []any{
			restIssueJSON("ENG-1", since.Add(-time.Second).UTC().Format(jiraTime), nil),
			restIssueJSON("ENG-2", since.Add(time.Minute).Format(jiraTime), nil),
		}, "isLast": true}
	})
	items, more, err := j.Activity(context.Background(), Opened, "ENG", mcpevents.TimeString(since))
	if err != nil || more || len(items) != 2 {
		t.Fatalf("%v %v %v", items, more, err)
	}
	if f.asked[0] != "POST /search/jql" || f.auth[0] != "Basic YWxleEBleGFtcGxlLmNvbTp0b2s=" {
		t.Fatalf("Jira Cloud searches /search/jql: %v %v", f.asked, f.auth)
	}
	if jql := f.bodies[0]["jql"]; jql != `created >= -11m AND project = "ENG" ORDER BY created ASC` {
		t.Fatalf("jql %v", jql)
	}
	i := items[1].Issue
	if i.Key != "ENG-2" || i.Project != "ENG" || i.Status != "To Do" || i.StatusCategory != "new" || i.Creator.Name != "Alex" ||
		!strings.HasSuffix(i.URL, "/browse/ENG-2") || strings.Contains(i.URL, "//browse") {
		t.Fatalf("issue %+v", i)
	}
	// RealJira gives what JQL found, to the minute; the poll drops what is before since, by
	// the times in mcpevents.TimeLayout, which sort as text.
	e := &Events{Jira: j}
	cand, _, _ := e.candidates(context.Background(), events[0], args{}, mcpevents.TimeString(since))
	if len(cand) != 2 || cand[1].eventID != "issue.opened:12" || !(cand[0].time < mcpevents.TimeString(since) && mcpevents.TimeString(since) < cand[1].time) {
		t.Fatalf("candidates %+v", cand)
	}
}

func TestCommentsSinceAreCommented(t *testing.T) {
	since := time.Now().Add(-5 * time.Minute)
	_, j := newSite(t, true, func(string, map[string]any) any {
		return map[string]any{"issues": []any{restIssueJSON("ENG-3", since.Add(-time.Hour).Format(jiraTime), map[string]any{
			"comment": map[string]any{"total": 2, "comments": []any{
				map[string]any{"id": "100", "body": "old", "created": since.Add(-time.Minute).Format(jiraTime), "author": alexUser},
				map[string]any{"id": "101", "body": "new *one*", "created": since.Add(time.Minute).Format(jiraTime), "author": appUser},
			}}})}}
	})
	items, _, err := j.Activity(context.Background(), Commented, "", mcpevents.TimeString(since))
	if err != nil || len(items) != 1 {
		t.Fatalf("%v %v", items, err)
	}
	c := items[0]
	if c.ID != "101" || c.CommentBody != "new *one*" || !c.By.App || !strings.HasSuffix(c.CommentURL, "/browse/ENG-3?focusedCommentId=101") {
		t.Fatalf("comment %+v", c)
	}
}

func TestTheChangelogGivesLabelsAddedAndAssignedToMe(t *testing.T) {
	since := time.Now().Add(-5 * time.Minute)
	at := since.Add(time.Minute).Format(jiraTime)
	f, j := newSite(t, false, func(path string, _ map[string]any) any {
		if path == "/myself" {
			return map[string]any{"name": "alex", "displayName": "Alex"}
		}
		return map[string]any{"total": 1, "issues": []any{func() map[string]any {
			i := restIssueJSON("ENG-4", at, nil)
			i["changelog"] = map[string]any{"histories": []any{
				map[string]any{"id": "500", "created": at, "author": map[string]any{"name": "sam", "displayName": "Sam"}, "items": []any{
					map[string]any{"field": "labels", "fromString": "bug", "toString": "bug agent docs"},
					map[string]any{"field": "assignee", "from": "sam", "to": "alex", "toString": "Alex"},
				}},
				map[string]any{"id": "499", "created": since.Add(-time.Minute).Format(jiraTime), "items": []any{
					map[string]any{"field": "labels", "fromString": "", "toString": "bug"},
				}},
			}}
			return i
		}()}}
	})
	labelled, more, err := j.Activity(context.Background(), Labelled, "", mcpevents.TimeString(since))
	if err != nil || more || len(labelled) != 2 || labelled[0].Label != "agent" || labelled[1].Label != "docs" || labelled[0].ID != "500:agent" {
		t.Fatalf("labelled %+v %v %v", labelled, more, err)
	}
	if f.asked[0] != "POST /search" || f.auth[0] != "Bearer tok" {
		t.Fatalf("Data Center searches /search: %v %v", f.asked, f.auth)
	}
	if expand, _ := json.Marshal(f.bodies[0]["expand"]); string(expand) != `["changelog"]` {
		t.Fatalf("Data Center's expand is a list: %s", expand)
	}
	assigned, _, err := j.Activity(context.Background(), Assigned, "", mcpevents.TimeString(since))
	if err != nil || len(assigned) != 1 || assigned[0].By.Name != "Sam" || assigned[0].Issue.Key != "ENG-4" {
		t.Fatalf("assigned %+v %v", assigned, err)
	}
}

func TestJirasFailures(t *testing.T) {
	f, j := newSite(t, true, nil)
	for _, c := range []struct {
		status int
		header http.Header
		kind   ErrorKind
		retry  int
	}{
		{http.StatusTooManyRequests, http.Header{"Retry-After": {"7"}}, RateLimited, 7000},
		{http.StatusUnauthorized, nil, NotSignedIn, 0},
		{http.StatusBadRequest, nil, NotFound, 0},
		{http.StatusInternalServerError, nil, Failed, 0},
	} {
		f.status, f.header = c.status, c.header
		_, _, err := j.Activity(context.Background(), Opened, "NOPE", mcpevents.TimeString(time.Now()))
		je, ok := err.(*JiraError)
		if !ok || je.Kind != c.kind || je.RetryAfterMs != c.retry {
			t.Errorf("%d: %#v", c.status, err)
		}
	}
	none := NewRealJira(func() Auth { return Auth{} })
	if _, err := none.Myself(context.Background()); err == nil || err.(*JiraError).Kind != NotSignedIn {
		t.Fatalf("no token: %v", err)
	}
}

func TestTheViewReadsOpenIssuesProjectsAndADescription(t *testing.T) {
	f, j := newSite(t, true, func(path string, _ map[string]any) any {
		switch {
		case path == "/myself":
			return alexUser
		case strings.HasPrefix(path, "/project/search"):
			return map[string]any{"values": []any{map[string]any{"key": "OPS", "name": "Operations"}, map[string]any{"key": "ENG", "name": "Engineering"}}}
		case strings.HasPrefix(path, "/issue/ENG-1"):
			return map[string]any{"key": "ENG-1", "fields": map[string]any{"description": "h2. Work"},
				"renderedFields": map[string]any{"description": `<h2>Work</h2><script>alert(1)</script>`}}
		}
		return map[string]any{"issues": []any{
			restIssueJSON("ENG-1", "2026-11-01T09:00:00.000+0000", map[string]any{"updated": "2026-11-01T09:00:00.000+0000", "assignee": alexUser}),
			restIssueJSON("ENG-2", "2026-11-01T08:00:00.000-0800", map[string]any{"updated": "2026-11-01T08:00:00.000-0800"}),
		}}
	})
	list, viewer, err := j.OpenIssues(context.Background(), "ENG", "indeterminate", `say "hi"`)
	if err != nil || len(list) != 2 || viewer.ID != "u1" {
		t.Fatalf("%v %v %v", list, viewer, err)
	}
	if jql := f.bodies[1]["jql"]; jql != `statusCategory = 4 AND project = "ENG" AND labels = "say \"hi\"" ORDER BY updated DESC` {
		t.Fatalf("jql %v", jql)
	}
	if list[0].Key != "ENG-2" || list[0].Priority != "High" || list[1].AssigneeID != "u1" {
		t.Fatalf("newest updated first, by the time and not the text: %+v", list)
	}
	if issueSection(list[1].Issue, viewer, nil) != sectionNeedsYou || list[0].json()["updatedAt"] != "2026-11-01T16:00:00.000Z" {
		t.Fatalf("ENG-1 is assigned to the viewer: %v", list[0].json())
	}
	projects, err := j.Projects(context.Background())
	if err != nil || len(projects) != 2 || projects[0].Key != "ENG" {
		t.Fatalf("%v %v", projects, err)
	}
	details, err := j.IssueDetails(context.Background(), "ENG-1")
	if err != nil || details["descriptionHTML"] != "<h2>Work</h2>" || details["description"] != "h2. Work" {
		t.Fatalf("%v %v", details, err)
	}
	if last := f.asked[len(f.asked)-1]; last != "GET /issue/ENG-1?fields=description&expand=renderedFields" {
		t.Fatalf("asked %s", last)
	}
}

func TestDataCenterListsEveryProject(t *testing.T) {
	f, j := newSite(t, false, func(string, map[string]any) any {
		return []any{map[string]any{"key": "ENG", "name": "Engineering"}}
	})
	projects, err := j.Projects(context.Background())
	if err != nil || len(projects) != 1 || f.asked[0] != "GET /project" {
		t.Fatalf("%v %v %v", projects, err, f.asked)
	}
}

func TestLabelsAdded(t *testing.T) {
	if got := strings.Join(added("a b", "b c a d"), ","); got != "c,d" {
		t.Fatal(got)
	}
	if added("a", "") != nil {
		t.Fatal("a label removed is not added")
	}
}
