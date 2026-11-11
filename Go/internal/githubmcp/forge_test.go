package githubmcp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
)

const searchAnswer = `{"data":{"search":{"issueCount":57,"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29y"},"edges":[
 {"cursor":"YzE=","node":{"__typename":"PullRequest","number":12,"title":"Forge reads","url":"https://github.com/o/r/pull/12","pullState":"MERGED",
  "updatedAt":"2026-11-01T10:00:00Z","author":{"login":"alexec","__typename":"User","avatarUrl":"https://avatars.githubusercontent.com/u/1142830?v=4"},"repository":{"nameWithOwner":"o/r"},
  "labels":{"nodes":[{"name":"enhancement","color":"A2EEEF"},{"name":"odd","color":"red"}]},
  "assignees":{"nodes":[{"login":"alexec"}]},"milestone":{"title":"0.16"},"commentCount":{"totalCount":3},
  "isDraft":true,"mergeable":"CONFLICTING","reviewDecision":"APPROVED","autoMergeRequest":{"enabledAt":"x"},
  "checkState":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}},
 {"cursor":"YzI=","node":{"__typename":"PullRequest","number":13,"title":"Docs","url":"u","pullState":"OPEN","updatedAt":"2026-11-01T09:00:00Z",
  "author":null,"repository":{"nameWithOwner":"o/s"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,
  "commentCount":{"totalCount":0},"isDraft":false,"mergeable":"UNKNOWN","reviewDecision":null,"autoMergeRequest":null,
  "checkState":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}},
 {"cursor":"YzM=","node":{}}]}}}`

const itemAnswer = `{"data":{"repository":{"issueOrPullRequest":{"__typename":"Issue","number":3,"title":"Mean is off by one",
 "url":"https://github.com/o/r/issues/3","issueState":"CLOSED","updatedAt":"2026-11-01T08:00:00Z",
 "createdAt":"2026-10-30T08:00:00Z","closedAt":"2026-11-01T07:00:00Z",
 "children":{"nodes":[{"issueState":"OPEN","number":4,"title":"A child","url":"https://github.com/o/r/issues/4","repository":{"nameWithOwner":"o/r"}},{}]},
 "linkedPulls":{"nodes":[{"pullState":"MERGED","number":12,"title":"Forge reads","url":"u","repository":{"nameWithOwner":"o/r"}}]},
 "events":{"nodes":[
  {"__typename":"LabeledEvent","actor":{"login":"kim"},"createdAt":"2026-10-30T09:00:00Z","label":{"name":"bug","color":"d73a4a"}},
  {"__typename":"AssignedEvent","actor":{"login":"kim"},"createdAt":"2026-10-30T10:00:00Z","assignee":{"login":"alexec"}},
  {"__typename":"CrossReferencedEvent","actor":null,"createdAt":"2026-10-31T10:00:00Z","source":{"__typename":"PullRequest","number":12,"repository":{"nameWithOwner":"o/r"}}},
  {"__typename":"CrossReferencedEvent","actor":{"login":"kim"},"createdAt":"2026-10-31T11:00:00Z","source":{}},
  {"__typename":"ClosedEvent","actor":{"login":"alexec"},"createdAt":"2026-11-01T07:00:00Z","closer":{"__typename":"PullRequest","number":12,"repository":{"nameWithOwner":"o/r"}}},
  {}]},
 "author":{"login":"kim","__typename":"User"},"repository":{"nameWithOwner":"o/r"},"labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},
 "assignees":{"nodes":[]},"milestone":null,"commentCount":{"totalCount":51},"body":"It is off by one.",
 "comments":{"pageInfo":{"hasPreviousPage":true,"startCursor":"b2xkZXI="},"nodes":[
  {"author":{"login":"dependabot","__typename":"Bot","avatarUrl":"https://avatars.githubusercontent.com/in/29110?v=4"},"body":"Bumped.","createdAt":"2026-11-01T08:01:00Z","url":"c1"},
  {"author":null,"body":"Ghost.","createdAt":"2026-11-01T08:02:00Z","url":"c2"}]}}}}}`

const pullAnswer = `{"data":{"repository":{"issueOrPullRequest":{"__typename":"PullRequest","number":12,"title":"Forge reads",
 "url":"u","pullState":"OPEN","updatedAt":"2026-11-01T10:00:00Z","author":{"login":"alexec","__typename":"User"},
 "repository":{"nameWithOwner":"o/r"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,"commentCount":{"totalCount":0},
 "isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":null,
 "checkState":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]},"body":"","comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[]},
 "reviewThreads":{"totalCount":2},"changedFiles":5,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/9/job/1"},
  {"__typename":"StatusContext","context":"CodeRabbit","state":"PENDING","targetUrl":"t"}]}}}}]}}}}}`

// asked is each GraphQL request's variables.
type asked struct {
	mu   sync.Mutex
	vars []map[string]any
}

func (a *asked) all() []map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return slices.Clone(a.vars)
}

// forgeAPI answers the forge reads' GraphQL, and keeps each request's variables.
func forgeAPI(t *testing.T, vars *asked) *RealGitHub {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &req)
		vars.mu.Lock()
		vars.vars = append(vars.vars, req.Variables)
		vars.mu.Unlock()
		switch {
		case strings.Contains(req.Query, "search(query"):
			io.WriteString(w, searchAnswer)
		case req.Variables["number"] == float64(3):
			io.WriteString(w, itemAnswer)
		case req.Variables["number"] == float64(12):
			io.WriteString(w, pullAnswer)
		default:
			io.WriteString(w, `{"data":{"repository":{"issueOrPullRequest":null}}}`)
		}
	}))
	t.Cleanup(s.Close)
	return NewRealGitHub(s.URL, func() string { return "t" }, nil)
}

// #3129: one search for every repo; each item in the model the daemon maps, a pull request's
// own fields with it, and an empty node left out.
func TestSearchListsManyReposInOneCall(t *testing.T) {
	a := &asked{}
	g := forgeAPI(t, a)
	p, err := g.Search(context.Background(), []string{"o/r", "o/s"}, SearchFilter{PRs: true, Label: "enhancement"}, "", 500)
	if err != nil {
		t.Fatal(err)
	}
	if vars := a.all(); len(vars) != 1 || vars[0]["q"] != `is:pr is:open repo:o/r repo:o/s label:"enhancement" sort:updated-desc` || vars[0]["first"] != float64(100) {
		t.Fatalf("asked: %v", vars)
	}
	// The count is the whole search's (#4396), not the page's.
	if p.Next != "Y3Vyc29y" || len(p.Items) != 2 || !slices.Equal(p.Cursors, []string{"YzE=", "YzI="}) || p.Total == nil || *p.Total != 57 {
		t.Fatalf("page: %+v", p)
	}
	first, b := p.Items[0], p.Items[1]
	if first.Repo != "o/r" || first.Number != 12 || !first.PR || first.State != "merged" || first.Author != "alexec" || first.AuthorAvatar != "https://avatars.githubusercontent.com/u/1142830?v=4" || first.Milestone != "0.16" ||
		first.Comments != 3 || len(first.Assignees) != 1 || !first.Draft || !first.AutoMerge || first.Checks != "failing" || first.Review != "approved" ||
		first.Mergeable != "conflicting" || first.LabelColors["enhancement"] != "#a2eeef" || len(first.Labels) != 2 {
		t.Fatalf("first: %+v", first)
	}
	if b.Repo != "o/s" || b.State != "open" || b.Checks != "none" || b.Mergeable != "unknown" || b.Review != "" || b.Assignees == nil {
		t.Fatalf("second: %+v", b)
	}

	if p, err = g.Search(context.Background(), nil, SearchFilter{}, "", 50); err != nil || len(p.Items) != 0 || len(a.all()) != 1 {
		t.Fatalf("no repos asked GitHub: %v %+v %v", err, p, a.all())
	}
}

func TestSearchQuery(t *testing.T) {
	for _, c := range []struct {
		f    SearchFilter
		want string
	}{
		{SearchFilter{}, "is:issue is:open repo:o/r sort:updated-desc"},
		{SearchFilter{State: "closed"}, "is:issue is:closed repo:o/r sort:updated-desc"},
		{SearchFilter{PRs: true, State: "all", Assignee: "kim", Query: " flaky "}, "is:pr repo:o/r assignee:kim flaky sort:updated-desc"},
	} {
		if got := SearchQuery([]string{"o/r"}, c.f); got != c.want {
			t.Errorf("%+v: %q, want %q", c.f, got, c.want)
		}
	}
}

// #3129: an issue with its body and its newest page of comments, the cursor of the page
// before; a pull request with each check; a number GitHub does not have is NotFound.
func TestItemPage(t *testing.T) {
	a := &asked{}
	g := forgeAPI(t, a)
	i, err := g.ItemPage(context.Background(), "o/r", 3, "")
	if err != nil {
		t.Fatal(err)
	}
	if i.PR || i.State != "closed" || i.Body != "It is off by one." || i.Before != "b2xkZXI=" || i.Comments != 51 || i.CheckRuns != nil {
		t.Fatalf("issue: %+v", i)
	}
	if got := i.Thread; len(got) != 2 || !got[0].Bot || got[0].Author != "dependabot" || got[0].Avatar != "https://avatars.githubusercontent.com/in/29110?v=4" || got[1].Author != "" || got[1].Avatar != "" || got[1].Body != "Ghost." {
		t.Fatalf("comments: %+v", got)
	}
	// #4373: its dates, its sub-issues and closing pull requests (an unreadable node left out),
	// and its events in the one model (a reference from what the token cannot read left out).
	if i.CreatedAt != "2026-10-30T08:00:00Z" || i.ClosedAt != "2026-11-01T07:00:00Z" {
		t.Fatalf("dates: %q %q", i.CreatedAt, i.ClosedAt)
	}
	if !slices.Equal(i.Children, []Linked{{Repo: "o/r", Number: 4, Title: "A child", State: "open", URL: "https://github.com/o/r/issues/4"}}) ||
		!slices.Equal(i.LinkedPulls, []Linked{{Repo: "o/r", Number: 12, PR: true, Title: "Forge reads", State: "merged", URL: "u"}}) {
		t.Fatalf("linked: %+v %+v", i.Children, i.LinkedPulls)
	}
	if want := []Event{
		{Kind: "labeled", Actor: "kim", At: "2026-10-30T09:00:00Z", Label: "bug", LabelColor: "#d73a4a"},
		{Kind: "assigned", Actor: "kim", At: "2026-10-30T10:00:00Z", Assignee: "alexec"},
		{Kind: "referenced", At: "2026-10-31T10:00:00Z", SourceRepo: "o/r", SourceNumber: 12, SourcePR: true},
		{Kind: "closed", Actor: "alexec", At: "2026-11-01T07:00:00Z", SourceRepo: "o/r", SourceNumber: 12, SourcePR: true},
	}; !slices.Equal(i.Events, want) {
		t.Fatalf("events: %+v", i.Events)
	}
	if _, ok := a.all()[0]["before"]; ok {
		t.Fatalf("first page sent a cursor: %v", a.all())
	}
	if _, err := g.ItemPage(context.Background(), "o/r", 3, "b2xkZXI="); err != nil || a.all()[1]["before"] != "b2xkZXI=" {
		t.Fatalf("older page: %v %v", err, a.all())
	}

	p, err := g.ItemPage(context.Background(), "o/r", 12, "")
	if err != nil {
		t.Fatal(err)
	}
	if !p.PR || p.Checks != "running" || p.Before != "" || p.Children != nil || p.Events != nil || p.ReviewThreads != 2 || p.FilesChanged != 5 || len(p.Thread) != 0 {
		t.Fatalf("pull: %+v", p)
	}
	if len(p.CheckRuns) != 2 || p.CheckRuns[0] != (Check{"test", "failing", "https://github.com/o/r/actions/runs/9/job/1"}) ||
		p.CheckRuns[1] != (Check{"CodeRabbit", "running", "t"}) {
		t.Fatalf("checks: %+v", p.CheckRuns)
	}

	var ge *GitHubError
	if _, err := g.ItemPage(context.Background(), "o/r", 99, ""); err == nil || !errors.As(err, &ge) || ge.Kind != NotFound {
		t.Fatalf("missing: %v", err)
	}
}

// A closed issue says why it closed in the one model's words; an open one and a PR say none (#4365).
func TestItemStateReason(t *testing.T) {
	for _, c := range []struct {
		typename, issueState, pullState, reason, want string
	}{
		{"Issue", "CLOSED", "", "COMPLETED", "completed"},
		{"Issue", "CLOSED", "", "NOT_PLANNED", "not_planned"},
		{"Issue", "CLOSED", "", "DUPLICATE", "duplicate"},
		{"Issue", "CLOSED", "", "", ""},
		{"Issue", "OPEN", "", "REOPENED", ""},
		{"PullRequest", "", "CLOSED", "", ""},
	} {
		n := gqlItem{Typename: c.typename, IssueState: c.issueState, PullState: c.pullState, StateReason: c.reason}
		if got := n.item().StateReason; got != c.want {
			t.Errorf("%+v: StateReason %q, want %q", c, got, c.want)
		}
	}
}
