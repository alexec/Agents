package bitbucketmcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// The forge reads and writes (#3786) against a stand-in Bitbucket Cloud over HTTP: the issues
// and pull requests lists of two repositories, one issue, its comments, a pull request with its
// statuses, participants and diffstat, its diff, kinds and components, a decline, a merge and
// an approval.

type forgeFake struct {
	mu     sync.Mutex
	lists  []string // the path and query of each list
	items  map[string][]obj
	pulls  map[string][]obj
	sent   []string // method path body of each write
	server *httptest.Server
}

func newForgeFake(t *testing.T) (*forgeFake, *RealBitbucket) {
	f := &forgeFake{items: map[string][]obj{}, pulls: map[string][]obj{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	bb := NewRealBitbucket(f.server.URL, func() string { return token }, nil, nil)
	bb.sharing = 0
	return f, bb
}

func (f *forgeFake) write(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// bbqlBefore is the time a list's BBQL asks for at or before, "" for none.
func bbqlBefore(q string) string {
	_, after, ok := strings.Cut(q, "updated_on<=")
	if !ok {
		return ""
	}
	return strings.Fields(after)[0]
}

func (f *forgeFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := strings.TrimPrefix(r.URL.Path, "/repositories/")
	if r.Method != http.MethodGet {
		body, _ := io.ReadAll(r.Body)
		f.sent = append(f.sent, strings.TrimSpace(r.Method+" "+p+" "+string(body)))
	}
	page := func(list []obj, next bool) {
		if list == nil {
			list = []obj{}
		}
		out := obj{"values": list, "size": 51}
		if next {
			out["next"] = "more"
		}
		f.write(w, out)
	}
	list := func(of map[string][]obj, suffix string) {
		q := r.URL.Query()
		f.lists = append(f.lists, p+"?"+q.Get("q"))
		var out []obj
		for _, i := range of[strings.TrimSuffix(p, suffix)] {
			if b := bbqlBefore(q.Get("q")); b != "" && mcpevents.Before(b, i["updated_on"].(string)) {
				continue
			}
			out = append(out, i)
		}
		slices.SortStableFunc(out, func(a, b obj) int { return strings.Compare(b["updated_on"].(string), a["updated_on"].(string)) })
		if n := q.Get("pagelen"); n == "1" && len(out) > 1 {
			out = out[:1]
		}
		page(out, false)
	}
	switch {
	case r.Method == http.MethodGet && strings.HasSuffix(p, "/issues"):
		list(f.items, "/issues")
	case r.Method == http.MethodGet && strings.HasSuffix(p, "/pullrequests"):
		list(f.pulls, "/pullrequests")
	case p == "acme/app/issues/7" && r.Method == http.MethodGet:
		f.write(w, obj{"id": 7, "title": "Export", "content": obj{"raw": "As **Markdown**"}, "state": "open", "kind": "bug",
			"component": obj{"name": "ui"}, "milestone": obj{"name": "v1"}, "reporter": alex, "assignee": dev,
			"links": obj{"html": obj{"href": "https://bitbucket.org/acme/app/issues/7"}}, "updated_on": at(5)})
	case p == "acme/app/issues/7/comments" && r.Method == http.MethodGet:
		pg := r.URL.Query().Get("page")
		page([]obj{
			comment(101, dev, "newer on page "+pg, at(3), nil),
			comment(100, alex, "", at(2), nil),
			comment(99, renovate, "older on page "+pg, at(1), nil),
		}, pg == "1")
	case p == "acme/app/issues/7/changes" && r.Method == http.MethodGet:
		page([]obj{
			{"created_on": at(3), "user": dev, "changes": obj{"state": obj{"old": "open", "new": "resolved"}}},
			{"created_on": at(1), "user": alex, "changes": obj{"kind": obj{"old": "task", "new": "bug"}, "assignee": obj{"old": "", "new": "dev"}, "title": obj{"old": "a", "new": "b"}}},
			{"created_on": at(4), "user": alex, "changes": obj{"state": obj{"old": "resolved", "new": "open"}, "component": obj{"old": "", "new": "ui"}}},
		}, false)
	case p == "acme/app/pullrequests/8" && r.Method == http.MethodGet:
		f.write(w, pull(8, "hello", dev, obj{"title": "Add hello", "description": "Fixes #7", "updated_on": at(6), "comment_count": 2,
			"source":       obj{"branch": obj{"name": "hello"}, "commit": obj{"hash": "abc123def456"}, "repository": obj{"full_name": repo}},
			"reviewers":    []obj{alex, person(3, "kim")},
			"participants": []obj{{"user": alex, "role": "REVIEWER", "approved": true, "state": "approved"}, {"user": dev, "role": "PARTICIPANT"}}}))
	case p == "acme/app/pullrequests/8/comments" && r.Method == http.MethodGet:
		page([]obj{
			comment(201, alex, "Looks good", at(4), nil),
			comment(200, alex, "Rename this", at(3), obj{"inline": obj{"path": "hello.txt", "to": 1}}),
		}, false)
	case p == "acme/app/pullrequests/8/diffstat":
		page([]obj{{"status": "added", "lines_added": 2}, {"status": "merge conflict", "lines_added": 1, "lines_removed": 4}}, false)
	case p == "acme/app/pullrequests/8/commits":
		page([]obj{{"hash": "c1"}, {"hash": "c2"}, {"hash": "c3"}}, false)
	case p == "acme/app/commit/abc123def456/statuses":
		page([]obj{
			{"key": "test", "name": "Pipeline #12", "state": "FAILED", "url": "https://bitbucket.org/acme/app/pipelines/results/12", "created_on": at(1), "updated_on": at(3)},
			{"key": "lint", "name": "lint", "state": "SUCCESSFUL", "url": "https://ci.example/lint"},
		}, false)
	case p == "acme/app/refs/branches/main":
		f.write(w, obj{"name": "main", "merge_strategies": []string{"merge_commit", "squash", "fast_forward"}, "default_merge_strategy": "squash"})
	case p == "acme/app/pullrequests/8/diff":
		_, _ = io.WriteString(w, "diff --git a/hello.txt b/hello.txt\nnew file mode 100644\nindex 0000000..ce01362\n--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1,2 @@\n+hello\n+there\n"+
			"diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n"+
			"diff --git a/README.md b/README.md\nindex 1..2 100644\n--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n # app\n-old\n+new\n\\ No newline at end of file\n")
	case p == "acme/app/components":
		page([]obj{{"name": "ui"}, {"name": "feature:Export"}}, false)
	case strings.HasSuffix(p, "/comments"):
		f.write(w, obj{"id": 55, "links": obj{"html": obj{"href": "https://bitbucket.org/c/55"}}})
	case r.Method != http.MethodGet:
		f.write(w, obj{})
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"type":"error","error":{"message":"not here"}}`)
	}
}

func listedIssue(n int, updated string, extra obj) obj {
	i := issue(n, alex, obj{"updated_on": updated})
	for k, v := range extra {
		i[k] = v
	}
	return i
}

// A list asks each repository with its filter, merges them by time, and goes on from a cursor
// in the same instant without giving an item twice.
func TestSearchMergesRepositoriesByTime(t *testing.T) {
	f, bb := newForgeFake(t)
	f.items["acme/app"] = []obj{listedIssue(1, at(3), nil), listedIssue(2, at(1), nil)}
	f.items["kim/notes"] = []obj{listedIssue(5, at(3), nil), listedIssue(6, at(2), obj{"assignee": dev, "component": obj{"name": "ui"}})}
	ctx := context.Background()
	page, err := bb.Search(ctx, []string{"acme/app", "kim/notes"}, SearchFilter{}, "", 2)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range page.Items {
		got = append(got, i.key())
	}
	same(t, got, []string{"acme/app#1", "kim/notes#5"})
	if page.Next == "" || page.Items[0].State != "open" || page.Items[0].Labels[0] != "bug" || page.Items[0].PR {
		t.Fatalf("page: %+v", page)
	}
	if !strings.Contains(f.lists[0], openIssues) {
		t.Fatalf("an open list asks for open issues: %v", f.lists)
	}
	next, err := bb.Search(ctx, []string{"acme/app", "kim/notes"}, SearchFilter{}, page.Next, 2)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, i := range next.Items {
		got = append(got, i.key())
	}
	same(t, got, []string{"kim/notes#6", "acme/app#2"})
	if !strings.Contains(f.lists[2], "updated_on<=2026-11-06T12:03:00Z") {
		t.Fatalf("the cursor asks at or before its time: %v", f.lists)
	}

	f.lists = nil
	mine, err := bb.Search(ctx, []string{"kim/notes"}, SearchFilter{Label: "ui", Assignee: "DEV", Query: `say "hi"`, State: "closed"}, "", 10)
	if err != nil || len(mine.Items) != 1 || mine.Items[0].Number != 6 || mine.Items[0].Assignees[0] != "dev" {
		t.Fatalf("by label and assignee: %+v %v", mine, err)
	}
	if q := f.lists[0]; !strings.Contains(q, closedIssues) || !strings.Contains(q, `(kind="ui" OR component.name="ui")`) ||
		!strings.Contains(q, `title ~ "say \"hi\""`) {
		t.Fatalf("the filter's BBQL: %s", q)
	}
	if _, err := bb.Search(ctx, []string{"acme/app"}, SearchFilter{}, "not a cursor", 2); err == nil {
		t.Fatal("a bad cursor is refused")
	}
}

// A pull requests list asks for its states; a label, a feature or an assignee has none, as
// Bitbucket's pull requests have none of them.
func TestSearchListsPullRequests(t *testing.T) {
	f, bb := newForgeFake(t)
	f.pulls["acme/app"] = []obj{
		pull(3, "a", dev, obj{"state": "MERGED", "updated_on": at(2)}),
		pull(4, "b", dev, obj{"updated_on": at(1), "draft": true, "reviewers": []obj{alex},
			"participants": []obj{{"user": alex, "role": "REVIEWER", "state": "changes_requested"}}}),
	}
	ctx := context.Background()
	page, err := bb.Search(ctx, []string{"acme/app"}, SearchFilter{PRs: true, State: "all", Query: "x"}, "", 10)
	if err != nil || len(page.Items) != 2 {
		t.Fatalf("%+v %v", page, err)
	}
	if a, b := page.Items[0], page.Items[1]; a.State != "merged" || !a.PR || b.Review != "changes_requested" || !b.Draft || b.Mergeable != "unknown" {
		t.Fatalf("items: %+v", page.Items)
	}
	if q := f.lists[0]; !strings.Contains(q, `(title ~ "x" OR description ~ "x")`) {
		t.Fatalf("the filter's BBQL: %s", q)
	}
	for _, filter := range []SearchFilter{{PRs: true, Label: "bug"}, {PRs: true, Feature: "Export"}, {PRs: true, Assignee: "dev"}} {
		if page, err := bb.Search(ctx, []string{"acme/app"}, filter, "", 10); err != nil || len(page.Items) != 0 {
			t.Fatalf("%+v: %+v %v", filter, page, err)
		}
	}
	if len(f.lists) != 1 {
		t.Fatalf("a filter no pull request matches asks nothing: %v", f.lists)
	}
	if !strings.Contains(listPath("acme/app", SearchFilter{PRs: true, State: "closed"}, "", 5), "state=MERGED&state=DECLINED&state=SUPERSEDED") {
		t.Fatal("closed pull requests are merged, declined and superseded")
	}
}

// An issue's page is its body and the newest page of its comments, oldest first, without the
// changes that have no words; the cursor goes to the older page.
func TestItemPageReadsAnIssue(t *testing.T) {
	_, bb := newForgeFake(t)
	d, err := bb.ItemPage(context.Background(), "acme/app", 7, false, "")
	if err != nil {
		t.Fatal(err)
	}
	if d.Body != "As **Markdown**" || d.Before != "2" || d.Comments != 51 || d.Milestone != "v1" || d.Assignees[0] != "dev" ||
		!slices.Equal(d.Labels, []string{"bug", "ui"}) || len(d.Thread) != 2 || d.Thread[0].Body != "older on page 1" || !d.Thread[0].Bot ||
		d.Thread[1].Author != "dev" || d.Thread[1].Avatar != "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/a-dev/48" {
		t.Fatalf("issue: %+v", d)
	}
	// Its changes are its events, oldest first; a title's change is none (#4626).
	if !slices.Equal(d.Events, []Event{{Kind: "unlabeled", Actor: "alex", At: at(1), Label: "task"}, {Kind: "labeled", Actor: "alex", At: at(1), Label: "bug"},
		{Kind: "assigned", Actor: "alex", At: at(1), Assignee: "dev"}, {Kind: "closed", Actor: "dev", At: at(3)},
		{Kind: "labeled", Actor: "alex", At: at(4), Label: "ui"}, {Kind: "reopened", Actor: "alex", At: at(4)}}) {
		t.Fatalf("events: %+v", d.Events)
	}
	older, err := bb.ItemPage(context.Background(), "acme/app", 7, false, d.Before)
	if err != nil || older.Before != "" || older.Thread[0].Body != "older on page 2" {
		t.Fatalf("older: %+v %v", older, err)
	}
	if _, err := bb.ItemPage(context.Background(), "acme/app", 7, false, "x"); err == nil {
		t.Fatal("a bad cursor is refused")
	}
	if _, err := bb.ItemPage(context.Background(), "acme/app", 404, false, ""); !IsNotFound(err) {
		t.Fatalf("not found: %v", err)
	}
}

// A pull request's page has its head's statuses as checks, each with its Pipelines run, its
// review, files changed, a conflict, and its line comments as threads.
func TestItemPageReadsAPullRequest(t *testing.T) {
	_, bb := newForgeFake(t)
	d, err := bb.ItemPage(context.Background(), "acme/app", 8, true, "")
	if err != nil {
		t.Fatal(err)
	}
	if d.Head != "abc123def456" || d.Checks != "failing" || len(d.CheckRuns) != 2 || d.CheckRuns[0].Run != 12 || d.CheckRuns[1].Run != 0 ||
		d.CheckRuns[1].State != "passing" || d.Review != "approved" || d.FilesChanged != 2 || d.Mergeable != "conflicting" ||
		d.ReviewThreads != 1 || len(d.Thread) != 1 || d.Thread[0].Body != "Looks good" || d.Body != "Fixes #7" || d.Comments != 2 {
		t.Fatalf("pull request: %+v", d)
	}
	// #4682: its size from the diffstat and its commits, its reviewers by their part, and a
	// status's times.
	if d.Size == nil || *d.Size != (Size{Additions: 3, Deletions: 4, Commits: 3}) {
		t.Fatalf("size: %+v", d.Size)
	}
	if !slices.Equal(d.Reviewers, []Reviewer{{Login: "alex", Avatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/a-alex/48", State: "approved"},
		{Login: "kim", Avatar: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/a-kim/48", State: "pending"}}) {
		t.Fatalf("reviewers: %+v", d.Reviewers)
	}
	if c := d.CheckRuns[0]; c.StartedAt != at(1) || c.FinishedAt != at(3) || d.CheckRuns[1].StartedAt != "" || d.CheckRuns[1].FinishedAt != "" {
		t.Fatalf("times: %+v", d.CheckRuns)
	}
}

// Each write is the request Bitbucket's API takes; a merge and an approval read the head first.
func TestForgeWrites(t *testing.T) {
	f, bb := newForgeFake(t)
	ctx := context.Background()
	if link, err := bb.Comment(ctx, "acme/app", 7, false, "Done"); err != nil || link != "https://bitbucket.org/c/55" {
		t.Fatalf("comment: %q %v", link, err)
	}
	if _, err := bb.Comment(ctx, "acme/app", 8, true, "LGTM"); err != nil {
		t.Fatal(err)
	}
	if err := bb.SetLabels(ctx, "acme/app", 7, []string{"Enhancement"}, []string{"ui", "bug"}); err != nil {
		t.Fatal(err)
	}
	if err := bb.SetLabels(ctx, "acme/app", 7, nil, []string{"bug"}); err == nil || !strings.Contains(err.Error(), "always has a kind") {
		t.Fatalf("a kind taken off: %v", err)
	}
	if err := bb.SetLabels(ctx, "acme/app", 7, []string{"a", "b"}, nil); err == nil {
		t.Fatal("two components")
	}
	if err := bb.SetState(ctx, "acme/app", 7, false, true); err != nil {
		t.Fatal(err)
	}
	if err := bb.SetState(ctx, "acme/app", 8, true, true); err != nil {
		t.Fatal(err)
	}
	if err := bb.SetState(ctx, "acme/app", 8, true, false); err == nil || !strings.Contains(err.Error(), "cannot reopen") {
		t.Fatalf("reopen a pull request: %v", err)
	}
	if err := bb.Merge(ctx, "acme/app", 8, "abc123def4567890", "squash"); err != nil {
		t.Fatal(err)
	}
	if err := bb.Merge(ctx, "acme/app", 8, "0000000", "squash"); err == nil || !strings.Contains(err.Error(), "newer commit") {
		t.Fatalf("an old head: %v", err)
	}
	if link, err := bb.Approve(ctx, "acme/app", 8, "abc123def456"); err != nil || link != "https://bitbucket.org/acme/app/pull-requests/8" {
		t.Fatalf("approve: %q %v", link, err)
	}
	want := []string{
		`POST acme/app/issues/7/comments {"content":{"raw":"Done"}}`,
		`POST acme/app/pullrequests/8/comments {"content":{"raw":"LGTM"}}`,
		`PUT acme/app/issues/7 {"component":null,"kind":"enhancement"}`,
		`PUT acme/app/issues/7 {"state":"resolved"}`,
		`POST acme/app/pullrequests/8/decline`,
		`POST acme/app/pullrequests/8/merge {"close_source_branch":true,"merge_strategy":"squash"}`,
		`POST acme/app/pullrequests/8/approve`,
	}
	same(t, f.sent, want)

	methods, err := bb.MergeMethods(ctx, "acme/app", 8)
	if err != nil || !slices.Equal(methods, []string{"squash", "merge"}) {
		t.Fatalf("methods: %v %v", methods, err)
	}
	labels, err := bb.RepoLabels(ctx, "acme/app")
	if err != nil || !slices.Equal(labels, []string{"bug", "enhancement", "proposal", "task", "ui", "feature:Export"}) {
		t.Fatalf("labels: %v %v", labels, err)
	}
}

// The diff is git's, a file at a time: added, renamed and changed.
func TestPRDiff(t *testing.T) {
	_, bb := newForgeFake(t)
	d, err := bb.PRDiff(context.Background(), "acme/app", 8)
	if err != nil {
		t.Fatal(err)
	}
	files := d["files"].([]any)
	if len(files) != 3 || d["url"] != "https://bitbucket.org/acme/app/pull-requests/8/diff" || d["sha"] != "abc123def456" {
		t.Fatalf("diff: %+v", d)
	}
	added, renamed, changed := files[0].(map[string]any), files[1].(map[string]any), files[2].(map[string]any)
	if added["change"] != "added" || added["additions"] != 2 || renamed["previousPath"] != "old.txt" || changed["deletions"] != 1 ||
		len(changed["hunks"].([]Hunk)[0].Lines) != 3 {
		t.Fatalf("files: %+v", files)
	}
}

func TestPipelineRun(t *testing.T) {
	for link, want := range map[string]int{
		"https://bitbucket.org/acme/app/pipelines/results/12":           12,
		"https://bitbucket.org/acme/app/pipelines/results/12/steps/{x}": 12,
		"https://ci.example/build/3":                                    0,
		"":                                                              0,
	} {
		if got := PipelineRun(link); got != want {
			t.Errorf("%s: %d, want %d", link, got, want)
		}
	}
}

// A closed issue's state says why it closed; an open one says none (#4365).
func TestIssueStateReason(t *testing.T) {
	for state, want := range map[string]string{"resolved": "completed", "closed": "completed", "wontfix": "not_planned",
		"invalid": "not_planned", "duplicate": "duplicate", "open": "", "on hold": ""} {
		if got := (issueJSON{State: state}).forgeItem("w/r").StateReason; got != want {
			t.Errorf("%s: %q, want %q", state, got, want)
		}
	}
}

// #4373: an issue and a pull request say when they opened; Bitbucket says no time that one closed.
func TestItemDates(t *testing.T) {
	var p forgePullJSON
	var i issueJSON
	if err := json.Unmarshal([]byte(`{"state":"MERGED","created_on":"2026-10-01T10:00:00Z","updated_on":"2026-10-02T10:00:00Z"}`), &p); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(`{"state":"resolved","created_on":"2026-10-01T11:00:00Z","updated_on":"2026-10-02T10:00:00Z"}`), &i); err != nil {
		t.Fatal(err)
	}
	if pr, issue := p.item("o/r"), i.forgeItem("o/r"); pr.CreatedAt != "2026-10-01T10:00:00Z" || issue.CreatedAt != "2026-10-01T11:00:00Z" ||
		pr.ClosedAt != "" || issue.ClosedAt != "" {
		t.Fatalf("pull %+v, issue %+v", pr, issue)
	}
}
