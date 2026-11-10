package bitbucketmcp

import (
	"context"
	"fmt"
	"testing"
)

// What lineage asks (#3879), against the fake Bitbucket: a merged and a declined pull request,
// an issue with its kind, component and milestone, a milestone, a release's commits over two
// pages, a commit's pull request, and the cost comment posted, edited and posted again.
func TestLineageAsks(t *testing.T) {
	f := newFake(t)
	f.set(func() {
		f.pulls = []obj{pull(2, "a", alex, obj{"title": "Add a", "state": "MERGED"}), pull(3, "b", alex, obj{"state": "DECLINED"})}
		f.issues = []obj{issue(1, alex, obj{"title": "Lineage asks Bitbucket", "state": "open", "component": obj{"name": "api"},
			"milestone": obj{"id": 7, "name": "0.2 Lineage"}}), issue(4, alex, obj{"state": "resolved"})}
		f.commits["v0.2.0"] = obj{"hash": "961a", "date": "2026-11-07T13:17:47+00:00"}
		f.compares["v0.2.0..v0.1.0"] = []obj{{"hash": "961a", "message": "Merged in a (pull request #2)\n\nAdd a"},
			{"hash": "77b0", "message": "Fix b"}, {"hash": "5c3d", "message": "Start"}}
		f.commitPulls["77b0"] = []obj{{"id": 3, "state": "DECLINED"}, {"id": 5, "state": "MERGED"}}
		f.prComments[2] = []obj{comment(5, alex, "Thanks", at(1), nil), comment(6, alex, "<!-- mark -->\nold", at(2), nil)}
	})
	bb := f.bitbucket()
	ctx := context.Background()

	for _, c := range []struct {
		number int
		pr     bool
		want   string
	}{
		{2, true, "{Add a merged []}"},
		{3, true, "{PR 3 closed []}"},
		{1, false, "{Lineage asks Bitbucket open [bug api]}"},
		{4, false, "{Issue 4 closed [bug]}"},
	} {
		if n, err := bb.Node(ctx, repo, c.number, c.pr); err != nil || fmt.Sprint(n) != c.want {
			t.Errorf("#%d (pr %v): %+v %v, want %s", c.number, c.pr, n, err, c.want)
		}
	}
	if _, err := bb.Node(ctx, repo, 9, false); !IsNotFound(err) {
		t.Errorf("an issue not there: %v", err)
	}
	if at, err := bb.CommitTime(ctx, repo, "v0.2.0"); err != nil || at.UTC().Format("2006-01-02T15:04:05Z") != "2026-11-07T13:17:47Z" {
		t.Errorf("a tag's commit time: %v %v", at, err)
	}
	if c, err := bb.Compare(ctx, repo, "v0.1.0", "v0.2.0"); err != nil || len(c) != 3 || c[0].SHA != "961a" || c[2].SHA != "5c3d" {
		t.Errorf("a release's commits: %+v %v", c, err)
	}
	for sha, want := range map[string]int{"77b0": 5, "5c3d": 0} {
		if n, err := bb.CommitPR(ctx, repo, sha); err != nil || n != want {
			t.Errorf("the pull request of %s: %d %v, want %d", sha, n, err, want)
		}
	}

	// Edits the marked comment; posts on a pull request with none; posts again for one deleted.
	if id, err := bb.CostComment(ctx, repo, 2, "", "<!-- mark -->", "<!-- mark -->\nnew"); err != nil || id != "6" {
		t.Errorf("the edit: %q %v", id, err)
	}
	if id, err := bb.CostComment(ctx, repo, 3, "", "<!-- mark -->", "<!-- mark -->\nfirst"); err != nil || id != "55" {
		t.Errorf("the post: %q %v", id, err)
	}
	f.set(func() { f.prComments[2][1]["deleted"] = true })
	if id, err := bb.CostComment(ctx, repo, 2, "6", "<!-- mark -->", "<!-- mark -->\nagain"); err != nil || id != "55" {
		t.Errorf("the post after a delete: %q %v", id, err)
	}
	var wrote []string
	f.set(func() {
		for _, p := range f.posted {
			wrote = append(wrote, fmt.Sprintf("%s %v", p["_path"], p["content"]))
		}
	})
	want := []string{root + "/pullrequests/2/comments/6 map[raw:<!-- mark -->\nnew]", root + "/pullrequests/3/comments map[raw:<!-- mark -->\nfirst]",
		root + "/pullrequests/2/comments map[raw:<!-- mark -->\nagain]"}
	if fmt.Sprint(wrote) != fmt.Sprint(want) {
		t.Errorf("wrote\n%q\nwant\n%q", wrote, want)
	}
}
