package forgejomcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"testing"
)

// The forge reads and writes (#3753) against a stand-in Forgejo over HTTP: the repository
// issues list, one issue, its comments, a pull request with its statuses and reviews, its diff,
// labels, a close, a merge and an approval.

type forgeFake struct {
	mu     sync.Mutex
	lists  []url.Values // the queries of the issue lists
	issues map[string][]obj
	sent   []string // method path body of each write
	server *httptest.Server
}

func newForgeFake(t *testing.T) (*forgeFake, *RealForgejo) {
	f := &forgeFake{issues: map[string][]obj{}}
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	fj := NewRealForgejo(f.server.URL, func() string { return token }, nil)
	fj.sharing = 0
	return f, fj
}

func (f *forgeFake) write(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (f *forgeFake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	p := strings.TrimPrefix(r.URL.Path, "/api/v1/")
	if r.Method != http.MethodGet {
		body, _ := io.ReadAll(r.Body)
		f.sent = append(f.sent, r.Method+" "+p+" "+strings.TrimSpace(string(body)))
	}
	switch {
	case r.Method == http.MethodGet && strings.HasSuffix(p, "/issues") && strings.HasPrefix(p, "repos/"):
		q := r.URL.Query()
		f.lists = append(f.lists, q)
		repo := strings.TrimSuffix(strings.TrimPrefix(p, "repos/"), "/issues")
		var out []obj
		for _, i := range f.issues[repo] {
			if b := q.Get("before"); b != "" && i["updated_at"].(string) > b {
				continue
			}
			if (q.Get("type") == "pulls") != (i["pull_request"] != nil) {
				continue
			}
			out = append(out, i)
		}
		slices.SortStableFunc(out, func(a, b obj) int { return strings.Compare(b["updated_at"].(string), a["updated_at"].(string)) })
		if n := q.Get("limit"); n == "1" && len(out) > 1 {
			out = out[:1]
		}
		f.write(w, orEmpty(out))
	case p == "repos/acme/app/issues/7":
		f.write(w, obj{"number": 7, "title": "Export", "body": "As **Markdown**", "state": "open", "html_url": "https://fj.test/acme/app/issues/7",
			"user": alex, "labels": []obj{{"id": 11, "name": "bug", "color": "EE0701"}}, "updated_at": at(5), "comments": 51})
	case p == "repos/acme/app/issues/7/comments" && r.Method == http.MethodGet:
		page := r.URL.Query().Get("page")
		f.write(w, []obj{{"id": 100, "user": renovate, "body": "page " + page, "created_at": at(1), "html_url": "https://fj.test/c/100"}})
	case p == "repos/acme/app/issues/7/timeline":
		pull := obj{"number": 8, "title": "WIP: Add hello", "state": "closed", "html_url": "https://fj.test/acme/app/pulls/8",
			"pull_request": obj{"merged": true}, "repository": obj{"full_name": "acme/app"}}
		f.write(w, []obj{
			{"type": "label", "body": "1", "user": alex, "created_at": at(1), "label": obj{"name": "bug", "color": "EE0701"}},
			{"type": "label", "body": "", "user": alex, "created_at": at(2), "label": obj{"name": "docs", "color": "0075ca"}},
			{"type": "assignees", "user": alex, "created_at": at(2), "assignee": dev},
			{"type": "assignees", "user": alex, "created_at": at(2), "assignee": dev, "removed_assignee": true},
			{"type": "comment", "user": dev, "created_at": at(3), "body": "a comment is not an event"},
			{"type": "pull_ref", "user": dev, "created_at": at(3), "ref_issue": pull},
			{"type": "comment_ref", "user": dev, "created_at": at(3), "ref_issue": pull},
			{"type": "issue_ref", "user": dev, "created_at": at(4), "ref_issue": obj{"number": 3, "title": "Other", "state": "open", "repository": obj{"full_name": "acme/lib"}}},
			{"type": "close", "user": alex, "created_at": at(4)},
			{"type": "reopen", "user": alex, "created_at": at(5)}})
	case p == "repos/acme/app/issues/8":
		f.write(w, obj{"number": 8, "title": "WIP: Add hello", "body": "Fixes #7", "state": "open", "html_url": "https://fj.test/acme/app/pulls/8",
			"user": dev, "updated_at": at(6), "comments": 0, "pull_request": obj{"merged": false, "draft": false}})
	case p == "repos/acme/app/issues/8/comments":
		f.write(w, []obj{})
	case p == "repos/acme/app/pulls/8":
		f.write(w, obj{"number": 8, "title": "WIP: Add hello", "state": "open", "html_url": "https://fj.test/acme/app/pulls/8", "mergeable": false,
			"changed_files": 2, "head": obj{"sha": "abc123", "ref": "hello"}, "base": obj{"ref": "main"}})
	case p == "repos/acme/app/commits/abc123/status":
		f.write(w, obj{"state": "failure", "sha": "abc123", "statuses": []obj{
			{"context": "ci / test", "status": "failure", "target_url": "https://fj.test/acme/app/actions/runs/3/jobs/0"},
			{"context": "ci / lint", "status": "success"}}})
	case p == "repos/acme/app/pulls/8/reviews" && r.Method == http.MethodGet:
		f.write(w, []obj{{"id": 1, "user": alex, "state": "APPROVED", "comments_count": 1}, {"id": 2, "user": dev, "state": "REQUEST_CHANGES", "comments_count": 2}})
	case p == "repos/acme/app/pulls/8/reviews":
		f.write(w, obj{"id": 3, "html_url": "https://fj.test/acme/app/pulls/8#issuecomment-3"})
	case p == "repos/acme/app/pulls/8.diff":
		_, _ = io.WriteString(w, "diff --git a/hello.txt b/hello.txt\nnew file mode 100644\nindex 0000000..ce01362\n--- /dev/null\n+++ b/hello.txt\n@@ -0,0 +1,2 @@\n+hello\n+there\n"+
			"diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n"+
			"diff --git a/README.md b/README.md\nindex 1..2 100644\n--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n # app\n-old\n+new\n\\ No newline at end of file\n")
	case p == "repos/acme/app":
		f.write(w, obj{"allow_merge_commits": true, "allow_squash_merge": true, "allow_rebase": false, "default_merge_style": "squash"})
	case p == "repos/acme/app/labels":
		f.write(w, []obj{{"id": 11, "name": "bug", "color": "ee0701"}, {"id": 12, "name": "docs", "color": "#0075CA"}})
	case p == "repos/acme/app/issues/7/labels" && r.Method == http.MethodGet:
		f.write(w, []obj{{"id": 11, "name": "bug"}, {"id": 12, "name": "docs"}})
	case strings.HasPrefix(p, "repos/acme/app/issues/7/"):
		f.write(w, obj{"id": 101, "html_url": "https://fj.test/acme/app/issues/7#issuecomment-101"})
	case r.Method != http.MethodGet:
		f.write(w, obj{"id": 1})
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"message":"not found"}`)
	}
}

func listed(n int, updated string, extra obj) obj {
	i := obj{"number": n, "title": "Item " + string(rune('A'+n)), "state": "open", "html_url": "https://fj.test/i/" + string(rune('0'+n)),
		"user": alex, "updated_at": updated, "comments": n, "labels": []obj{}}
	for k, v := range extra {
		i[k] = v
	}
	return i
}

func TestTheForgeListMergesReposByUpdatedAndGoesOnFromItsCursor(t *testing.T) {
	f, fj := newForgeFake(t)
	f.issues["acme/app"] = []obj{listed(1, at(3), nil), listed(2, at(1), obj{"labels": []obj{{"name": "bug", "color": "EE0701"}},
		"assignees": []obj{dev}, "milestone": obj{"title": "v1"}})}
	f.issues["acme/web"] = []obj{listed(3, at(2), nil), listed(4, at(2), nil), listed(5, at(9), obj{"pull_request": obj{"merged": true}})}
	ctx := context.Background()
	page, err := fj.Search(ctx, []string{"acme/app", "acme/web"}, SearchFilter{}, "", 2)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range page.Items {
		got = append(got, i.key())
	}
	same(t, got, []string{"acme/app#1", "acme/web#3"})
	if page.Next == "" || len(page.Cursors) != 2 {
		t.Fatalf("a page with more says where it goes on: %+v", page)
	}
	q := f.lists[0]
	if q.Get("type") != "issues" || q.Get("sort") != "recentupdate" || q.Get("state") != "open" || q.Get("limit") != "2" {
		t.Fatalf("the list's query: %v", q)
	}
	next, err := fj.Search(ctx, []string{"acme/app", "acme/web"}, SearchFilter{}, page.Next, 2)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, i := range next.Items {
		got = append(got, i.key())
	}
	// #4 was updated in the same second as #3, which the first page gave: it is not lost.
	same(t, got, []string{"acme/web#4", "acme/app#2"})
	if f.lists[len(f.lists)-1].Get("before") != at(2) {
		t.Fatalf("the next page is at or before the last one's time: %v", f.lists[len(f.lists)-1])
	}
	two := next.Items[1]
	if two.Labels[0] != "bug" || two.LabelColors["bug"] != "#ee0701" || two.Assignees[0] != "dev" || two.Milestone != "v1" || two.State != "open" {
		t.Fatalf("an item's fields: %+v", two)
	}
	prs, err := fj.Search(ctx, []string{"acme/web"}, SearchFilter{PRs: true, State: "all"}, "", 10)
	if err != nil || len(prs.Items) != 1 || !prs.Items[0].PR || prs.Items[0].State != "merged" || prs.Items[0].Mergeable != "unknown" || prs.Next != "" {
		t.Fatalf("a merged pull request: %+v %v", prs, err)
	}
	if _, err := fj.Search(ctx, []string{"acme/app"}, SearchFilter{}, "not a cursor", 2); err == nil {
		t.Fatal("a cursor no list gave is refused")
	}
}

func TestTheForgeListsFilterAsksForOneLabelAndKeepsItemsWithAll(t *testing.T) {
	f, fj := newForgeFake(t)
	f.issues["acme/app"] = []obj{
		listed(1, at(3), obj{"labels": []obj{{"name": "bug"}}}),
		listed(2, at(2), obj{"labels": []obj{{"name": "bug"}, {"name": "feature:export"}}}),
	}
	page, err := fj.Search(context.Background(), []string{"acme/app"}, SearchFilter{Label: "bug", Feature: "export", Assignee: "dev", Query: " words "}, "", 10)
	if err != nil || len(page.Items) != 1 || page.Items[0].Number != 2 {
		t.Fatalf("only the item with both labels: %+v %v", page, err)
	}
	q := f.lists[0]
	if q.Get("labels") != "bug" || q.Get("assigned_by") != "dev" || q.Get("q") != "words" {
		t.Fatalf("the filter's query: %v", q)
	}
}

func TestTheForgeItemPageReadsAnIssueAndAPullRequest(t *testing.T) {
	_, fj := newForgeFake(t)
	ctx := context.Background()
	d, err := fj.ItemPage(ctx, "acme/app", 7, false, "")
	if err != nil {
		t.Fatal(err)
	}
	// 51 comments are two pages; the newest is the second, and the one before it the first.
	if d.Body != "As **Markdown**" || len(d.Thread) != 1 || d.Thread[0].Body != "page 2" || !d.Thread[0].Bot || d.Before != "1" {
		t.Fatalf("an issue's page: %+v", d)
	}
	if d.AuthorAvatar != "https://fj.test/avatars/a1" || d.Thread[0].Avatar != "" {
		t.Fatalf("avatars: %q %q", d.AuthorAvatar, d.Thread[0].Avatar)
	}
	first, err := fj.ItemPage(ctx, "acme/app", 7, false, d.Before)
	if err != nil || first.Thread[0].Body != "page 1" || first.Before != "" {
		t.Fatalf("the first page of comments: %+v %v", first, err)
	}
	if _, err := fj.ItemPage(ctx, "acme/app", 7, false, "3"); err == nil {
		t.Fatal("a page past the last is refused")
	}
	if _, err := fj.ItemPage(ctx, "acme/app", 7, true, ""); !IsNotFound(err) {
		t.Fatalf("an issue read as a pull request is not found: %v", err)
	}
	p, err := fj.ItemPage(ctx, "acme/app", 8, true, "")
	if err != nil {
		t.Fatal(err)
	}
	if !p.PR || !p.Draft || p.Head != "abc123" || p.FilesChanged != 2 || p.Mergeable != "conflicting" || p.Checks != "failing" ||
		p.Review != "changes_requested" || p.ReviewThreads != 3 || len(p.CheckRuns) != 2 || p.CheckRuns[0].State != "failing" || p.CheckRuns[1].State != "passing" {
		t.Fatalf("a pull request's page: %+v", p)
	}
}

// #4626: an issue's timeline gives its events, oldest first, and the pull requests that name
// it, each once; an entry the wire has no word for is left out.
func TestTheForgeItemPageReadsAnIssuesTimeline(t *testing.T) {
	_, fj := newForgeFake(t)
	d, err := fj.ItemPage(context.Background(), "acme/app", 7, false, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(d.LinkedPulls) != 1 || d.LinkedPulls[0] != (Linked{Repo: "acme/app", Number: 8, Title: "WIP: Add hello", State: "merged", URL: "https://fj.test/acme/app/pulls/8"}) {
		t.Fatalf("linked pulls: %+v", d.LinkedPulls)
	}
	var kinds []string
	for _, e := range d.Events {
		kinds = append(kinds, e.Kind)
	}
	if !slices.Equal(kinds, []string{"labeled", "unlabeled", "assigned", "unassigned", "referenced", "referenced", "referenced", "closed", "reopened"}) {
		t.Fatalf("kinds: %v", kinds)
	}
	if e := d.Events[0]; e.Label != "bug" || e.LabelColor != "#ee0701" || e.Actor != "alex" {
		t.Errorf("labeled: %+v", e)
	}
	if e := d.Events[2]; e.Assignee != "dev" {
		t.Errorf("assigned: %+v", e)
	}
	if e := d.Events[6]; e.SourceRepo != "acme/lib" || e.SourceNumber != 3 || e.SourcePR {
		t.Errorf("an issue that named it: %+v", e)
	}
	if e := d.Events[4]; e.SourceRepo != "acme/app" || e.SourceNumber != 8 || !e.SourcePR {
		t.Errorf("a pull request that named it: %+v", e)
	}
	// A pull request's read has no timeline.
	if p, err := fj.ItemPage(context.Background(), "acme/app", 8, true, ""); err != nil || p.LinkedPulls != nil || p.Events != nil {
		t.Fatalf("a pull request's page: %+v %v", p, err)
	}
}

func TestTheForgeWrites(t *testing.T) {
	f, fj := newForgeFake(t)
	ctx := context.Background()
	if u, err := fj.Comment(ctx, "acme/app", 7, "Done"); err != nil || u != "https://fj.test/acme/app/issues/7#issuecomment-101" {
		t.Fatalf("a comment: %q %v", u, err)
	}
	if err := fj.SetLabels(ctx, "acme/app", 7, []string{"docs"}, []string{"BUG"}); err != nil {
		t.Fatal(err)
	}
	if err := fj.SetState(ctx, "acme/app", 7, true); err != nil {
		t.Fatal(err)
	}
	if err := fj.Merge(ctx, "acme/app", 8, "abc123", "squash", true); err != nil {
		t.Fatal(err)
	}
	if err := fj.Merge(ctx, "acme/app", 8, " ", "squash", false); err == nil {
		t.Fatal("a merge names the head the person saw")
	}
	if u, err := fj.Approve(ctx, "acme/app", 8, "abc123"); err != nil || !strings.Contains(u, "pulls/8") {
		t.Fatalf("an approval: %q %v", u, err)
	}
	same(t, f.sent, []string{
		`POST repos/acme/app/issues/7/comments {"body":"Done"}`,
		`POST repos/acme/app/issues/7/labels {"labels":["docs"]}`,
		`DELETE repos/acme/app/issues/7/labels/11 `,
		`PATCH repos/acme/app/issues/7 {"state":"closed"}`,
		`POST repos/acme/app/pulls/8/merge {"Do":"squash","delete_branch_after_merge":true,"head_commit_id":"abc123","merge_when_checks_succeed":true}`,
		`POST repos/acme/app/pulls/8/reviews {"commit_id":"abc123","event":"APPROVED"}`,
	})
	methods, err := fj.MergeMethods(ctx, "acme/app")
	if err != nil {
		t.Fatal(err)
	}
	same(t, methods, []string{"squash", "merge"})
	names, colors, err := fj.RepoLabels(ctx, "acme/app")
	if err != nil || len(names) != 2 || colors["docs"] != "#0075ca" {
		t.Fatalf("the repository's labels: %v %v %v", names, colors, err)
	}
}

func TestThePullRequestsDiff(t *testing.T) {
	_, fj := newForgeFake(t)
	out, err := fj.PRDiff(context.Background(), "acme/app", 8)
	if err != nil {
		t.Fatal(err)
	}
	files := out["files"].([]any)
	if len(files) != 3 || out["sha"] != "abc123" || out["cut"] != false {
		t.Fatalf("the diff: %+v", out)
	}
	added, renamed, changed := files[0].(map[string]any), files[1].(map[string]any), files[2].(map[string]any)
	if added["change"] != "added" || added["additions"] != 2 || len(added["hunks"].([]Hunk)[0].Lines) != 2 {
		t.Fatalf("an added file: %+v", added)
	}
	if renamed["change"] != "renamed" || renamed["previousPath"] != "old.txt" || renamed["path"] != "new.txt" || renamed["note"] == nil {
		t.Fatalf("a renamed file: %+v", renamed)
	}
	h := changed["hunks"].([]Hunk)[0]
	if changed["change"] != "modified" || changed["additions"] != 1 || changed["deletions"] != 1 || h.OldStart != 1 || len(h.Lines) != 3 {
		t.Fatalf("a changed file: %+v", changed)
	}
}

// #4373: an item says when it opened, and a closed or merged one when it closed.
func TestItemDates(t *testing.T) {
	for _, c := range []struct {
		json, created, closed string
	}{
		{`{"state":"open","created_at":"2026-10-01T10:00:00Z","closed_at":null}`, "2026-10-01T10:00:00Z", ""},
		{`{"state":"closed","created_at":"2026-10-01T10:00:00Z","closed_at":"2026-10-02T10:00:00Z"}`, "2026-10-01T10:00:00Z", "2026-10-02T10:00:00Z"},
		{`{"state":"closed","created_at":"2026-10-01T10:00:00Z","closed_at":"2026-10-02T10:00:00Z",
		  "pull_request":{"merged":true,"merged_at":"2026-10-03T10:00:00Z"}}`, "2026-10-01T10:00:00Z", "2026-10-03T10:00:00Z"},
	} {
		var j forgeJSON
		if err := json.Unmarshal([]byte(c.json), &j); err != nil {
			t.Fatal(err)
		}
		if i := j.item("o/r"); i.CreatedAt != c.created || i.ClosedAt != c.closed {
			t.Errorf("%s: %q %q", c.json, i.CreatedAt, i.ClosedAt)
		}
	}
}
