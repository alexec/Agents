package gitlabmcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// forgeLab is a GitLab with two projects' issues and merge requests, newest first, that keeps
// each request's path and query.
type forgeLab struct {
	mu    sync.Mutex
	asked []string
	lists map[string][]obj // "group/app issues" → items, newest first
	one   map[string]obj   // a path → its answer
}

func (f *forgeLab) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, r.URL.EscapedPath()+"?"+r.URL.RawQuery)
	path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v4/")
	if v, ok := f.one[path]; ok {
		json.NewEncoder(w).Encode(v)
		return
	}
	parts := strings.Split(path, "/")
	if len(parts) != 3 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	project, _ := url.PathUnescape(parts[1])
	list := []obj{}
	q := r.URL.Query()
	n, _ := strconv.Atoi(q.Get("per_page"))
	for _, i := range f.lists[project+" "+parts[2]] {
		if s := q.Get("state"); s != "all" && i["state"] != s {
			continue
		}
		if b := q.Get("updated_before"); b != "" && i["updated_at"].(string) > b {
			continue
		}
		if len(list) < n {
			list = append(list, i)
		}
	}
	json.NewEncoder(w).Encode(list)
}

func forgeItemJSON(iid int, state, updated string) obj {
	return obj{"iid": iid, "title": "Item " + strconv.Itoa(iid), "state": state, "updated_at": updated, "web_url": "w" + strconv.Itoa(iid),
		"author": obj{"username": "kim"}, "assignees": []obj{{"username": "alex"}}, "labels": []obj{{"name": "bug", "color": "#D9534F"}},
		"milestone": obj{"title": "0.16"}, "user_notes_count": 2, "detailed_merge_status": "not_approved", "draft": true}
}

func newForgeLab(t *testing.T) (*forgeLab, *RealGitLab) {
	f := &forgeLab{lists: map[string][]obj{}, one: map[string]obj{}}
	s := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(s.Close)
	g := NewRealGitLab(s.URL, func() string { return token }, nil)
	g.sharing = 0
	return f, g
}

// #3209: a list asks each project, merges them by updated_at, and goes on from a time: the
// next page asks for what was updated up to the millisecond after the last item, and leaves
// out what it gave in it.
func TestSearchMergesProjectsByTime(t *testing.T) {
	f, g := newForgeLab(t)
	f.lists["group/app issues"] = []obj{forgeItemJSON(3, "opened", "2026-11-01T10:00:00.000Z"),
		forgeItemJSON(2, "opened", "2026-11-01T08:00:00.000Z"), forgeItemJSON(1, "opened", "2026-11-01T06:00:00.000Z")}
	f.lists["group/web issues"] = []obj{forgeItemJSON(9, "opened", "2026-11-01T08:00:00.000Z"),
		forgeItemJSON(8, "opened", "2026-11-01T07:00:00.000Z")}
	p, err := g.Search(context.Background(), []string{"group/app", "group/web"}, SearchFilter{Label: "bug", Query: " flaky "}, "", 2)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range p.Items {
		got = append(got, i.key())
	}
	if !slices.Equal(got, []string{"group/app#3", "group/app#2"}) || len(p.Cursors) != 2 || p.Next != p.Cursors[1] {
		t.Fatalf("page: %v %+v", got, p)
	}
	if !strings.Contains(f.asked[0], "/projects/group%2Fapp/issues?") || !strings.Contains(f.asked[0], "labels=bug") ||
		!strings.Contains(f.asked[0], "search=flaky") || !strings.Contains(f.asked[0], "state=opened") ||
		!strings.Contains(f.asked[0], "with_labels_details=true") || strings.Contains(f.asked[0], "updated_before") {
		t.Fatalf("asked: %q", f.asked)
	}
	i := p.Items[0]
	if i.State != "open" || i.Author != "kim" || i.Milestone != "0.16" || i.Comments != 2 || i.LabelColors["bug"] != "#d9534f" ||
		len(i.Assignees) != 1 || i.MR || i.Review != "" {
		t.Fatalf("item: %+v", i)
	}

	f.asked = nil
	p, err = g.Search(context.Background(), []string{"group/app", "group/web"}, SearchFilter{}, p.Next, 2)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, i := range p.Items {
		got = append(got, i.key())
	}
	// group/web#9 was updated in the same millisecond as group/app#2, which was given.
	if !slices.Equal(got, []string{"group/web#9", "group/web#8"}) || p.Next == "" {
		t.Fatalf("second page: %v", got)
	}
	if !strings.Contains(f.asked[0], "updated_before=2026-11-01T08%3A00%3A00.001Z") || !strings.Contains(f.asked[0], "per_page=3") {
		t.Fatalf("asked: %q", f.asked)
	}
	p, _ = g.Search(context.Background(), []string{"group/app", "group/web"}, SearchFilter{}, p.Next, 2)
	if len(p.Items) != 1 || p.Items[0].key() != "group/app#1" || p.Next != "" {
		t.Fatalf("last page: %+v", p)
	}

	if _, err := g.Search(context.Background(), []string{"group/app"}, SearchFilter{}, "not a cursor", 2); err == nil {
		t.Fatal("a cursor it did not give was taken")
	}
}

// A closed merge request is closed or merged: two lists, merged into one; a merge request's own
// fields come with it.
func TestSearchClosedMergeRequests(t *testing.T) {
	f, g := newForgeLab(t)
	f.lists["group/app merge_requests"] = []obj{forgeItemJSON(5, "merged", "2026-11-01T10:00:00.000Z"),
		forgeItemJSON(4, "closed", "2026-11-01T09:00:00.000Z"), forgeItemJSON(3, "opened", "2026-11-01T08:00:00.000Z")}
	p, err := g.Search(context.Background(), []string{"group/app"}, SearchFilter{MRs: true, State: "closed"}, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.asked) != 2 || !strings.Contains(f.asked[0], "state=closed") || !strings.Contains(f.asked[1], "state=merged") {
		t.Fatalf("asked: %q", f.asked)
	}
	if len(p.Items) != 2 || p.Items[0].State != "merged" || p.Items[1].State != "closed" || p.Next != "" {
		t.Fatalf("page: %+v", p)
	}
	if i := p.Items[0]; !i.MR || i.key() != "group/app!5" || !i.Draft || i.Review != "review_required" || i.Mergeable != "mergeable" || i.Checks != "" {
		t.Fatalf("merge request: %+v", i)
	}
}

// One merge request: its description, a page of its comments (GitLab's own notes and a line's
// left out) oldest first, the page before it, its pipeline's jobs, review threads and files.
func TestItemPageReadsAMergeRequest(t *testing.T) {
	f, g := newForgeLab(t)
	mr := forgeItemJSON(4, "opened", "2026-11-01T10:00:00.000Z")
	mr["labels"], mr["description"], mr["changes_count"] = []string{"bug"}, "The body.", "12"
	mr["head_pipeline"] = obj{"id": 77, "status": "failed"}
	f.one["projects/group%2Fapp/merge_requests/4"] = mr
	notes := []any{}
	for n := 50; n >= 1; n-- {
		note := obj{"id": n, "body": "note " + strconv.Itoa(n), "author": obj{"username": "kim"}, "created_at": "2026-11-01T09:00:00.000Z"}
		switch n {
		case 50:
			note["system"] = true
		case 49:
			note["type"] = "DiffNote"
		case 48:
			note["author"] = obj{"username": "project_7_bot_x", "bot": true}
		}
		notes = append(notes, note)
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch path := strings.TrimPrefix(r.URL.EscapedPath(), "/api/v4/"); path {
		case "projects/group%2Fapp/merge_requests/4/notes":
			if r.URL.Query().Get("page") != "1" || r.URL.Query().Get("sort") != "desc" {
				json.NewEncoder(w).Encode([]any{})
				return
			}
			json.NewEncoder(w).Encode(notes)
		case "projects/group%2Fapp/merge_requests/4/discussions":
			json.NewEncoder(w).Encode([]any{obj{"id": "a", "notes": []any{obj{"type": "DiffNote"}}}, obj{"id": "b", "notes": []any{obj{"type": nil}}}})
		case "projects/group%2Fapp/pipelines/77/jobs":
			json.NewEncoder(w).Encode([]any{obj{"name": "test", "stage": "check", "status": "failed", "web_url": "j"},
				obj{"name": "lint", "stage": "check", "status": "failed", "allow_failure": true}})
		default:
			f.serve(w, r)
		}
	}))
	t.Cleanup(s.Close)
	g.Base = s.URL + "/"
	d, err := g.ItemPage(context.Background(), "group/app", 4, true, "")
	if err != nil {
		t.Fatal(err)
	}
	if d.Body != "The body." || d.Before != "2" || d.Labels[0] != "bug" || d.FilesChanged != 12 || d.ReviewThreads != 1 || d.Checks != "failing" {
		t.Fatalf("detail: %+v", d)
	}
	if len(d.Thread) != 48 || d.Thread[0].Body != "note 1" || d.Thread[47].Body != "note 48" || !d.Thread[47].Bot || d.Thread[0].URL != "w4#note_1" {
		t.Fatalf("thread: %d %+v", len(d.Thread), d.Thread[len(d.Thread)-1])
	}
	if len(d.CheckRuns) != 2 || d.CheckRuns[0].State != "failing" || d.CheckRuns[1].State != "skipped" || d.CheckRuns[0].Name != "check: test" {
		t.Fatalf("checks: %+v", d.CheckRuns)
	}
	older, err := g.ItemPage(context.Background(), "group/app", 4, true, "2")
	if err != nil || len(older.Thread) != 0 || older.Before != "" {
		t.Fatalf("the page before: %v %+v", err, older)
	}
	if _, err := g.ItemPage(context.Background(), "group/app", 5, false, ""); !IsNotFound(err) {
		t.Fatalf("no such issue: %v", err)
	}
}
