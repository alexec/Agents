package azuredevopsmcp

import (
	"context"
	"fmt"
	"testing"
)

// What lineage asks (#3952), against the fake Azure DevOps: a completed and an abandoned pull
// request, a tag's commit time, a release's commits over two pages, a commit's pull request,
// and the cost comment posted, edited and posted again.
func TestLineageAsks(t *testing.T) {
	f := newFake(t)
	f.set(func() {
		f.pulls = []obj{pull(2, "a", alex, obj{"title": "Add a", "status": "completed", "labels": []any{obj{"name": "ui", "active": true}}}),
			pull(3, "b", alex, obj{"status": "abandoned"}), pull(4, "c", alex, nil)}
		for i := range 130 {
			sha := fmt.Sprintf("%040x", 200-i)
			f.commits = append(f.commits, obj{"commitId": sha, "comment": "Commit " + fmt.Sprint(i), "committer": obj{"date": "2026-11-07T13:17:47Z"}})
		}
		f.commits[0]["comment"] = "Merged PR 2: Add a"
		f.commits[1]["comment"] = "Fix b"
		f.tags["v0.2.0"], f.tags["v0.1.0"] = f.commits[0]["commitId"].(string), f.commits[120]["commitId"].(string)
		f.merged[f.commits[1]["commitId"].(string)] = 5
		f.threads[2] = []obj{{"id": 30, "comments": []any{obj{"id": 1, "content": "Thanks", "parentCommentId": 0}}},
			{"id": 31, "comments": []any{obj{"id": 1, "content": "<!-- mark -->\nold", "parentCommentId": 0}}}}
	})
	ado := f.azureDevOps()
	ctx := context.Background()

	for number, want := range map[int]string{2: "{Add a merged [ui]}", 3: "{PR 3 closed []}", 4: "{PR 4 open []}"} {
		if n, err := ado.Node(ctx, repo, number); err != nil || fmt.Sprint(n) != want {
			t.Errorf("!%d: %+v %v, want %s", number, n, err, want)
		}
	}
	if _, err := ado.Node(ctx, repo, 9); !IsNotFound(err) {
		t.Errorf("a pull request not there: %v", err)
	}
	if at, err := ado.CommitTime(ctx, repo, "v0.2.0"); err != nil || at.UTC().Format("2006-01-02T15:04:05Z") != "2026-11-07T13:17:47Z" {
		t.Errorf("a tag's commit time: %v %v", at, err)
	}
	if c, err := ado.Compare(ctx, repo, "v0.1.0", "v0.2.0"); err != nil || len(c) != 120 || c[0].Message != "Merged PR 2: Add a" ||
		c[119].SHA != f.commits[119]["commitId"] {
		t.Errorf("a release's commits: %d %v", len(c), err)
	}
	for sha, want := range map[string]int{f.commits[1]["commitId"].(string): 5, f.commits[2]["commitId"].(string): 0} {
		if n, err := ado.CommitPR(ctx, repo, sha); err != nil || n != want {
			t.Errorf("the pull request of %s: %d %v, want %d", sha, n, err, want)
		}
	}

	// Edits the marked comment; posts on a pull request with none; posts again for one deleted.
	if id, err := ado.CostComment(ctx, repo, 2, "", "<!-- mark -->", "<!-- mark -->\nnew"); err != nil || id != "31/1" {
		t.Errorf("the edit: %q %v", id, err)
	}
	if id, err := ado.CostComment(ctx, repo, 3, "", "<!-- mark -->", "<!-- mark -->\nfirst"); err != nil || id != "77/1" {
		t.Errorf("the post: %q %v", id, err)
	}
	f.set(func() { f.threads[2][1]["comments"].([]any)[0].(obj)["isDeleted"] = true })
	if id, err := ado.CostComment(ctx, repo, 2, "31/1", "<!-- mark -->", "<!-- mark -->\nagain"); err != nil || id != "77/1" {
		t.Errorf("the post after a delete: %q %v", id, err)
	}
	var wrote []string
	f.set(func() {
		for _, p := range f.posted {
			if p["_path"] == gitRoot+"/pullrequestquery" {
				continue
			}
			wrote = append(wrote, fmt.Sprintf("%s %s %v %v %v", p["_method"], p["_path"], p["status"], p["content"], p["comments"]))
		}
	})
	want := []string{
		"PATCH " + gitRoot + "/pullRequests/2/threads/31/comments/1 <nil> <!-- mark -->\nnew <nil>",
		"POST " + gitRoot + "/pullRequests/3/threads closed <nil> [map[commentType:text content:<!-- mark -->\nfirst parentCommentId:0]]",
		"PATCH " + gitRoot + "/pullRequests/2/threads/31/comments/1 <nil> <!-- mark -->\nagain <nil>",
		"POST " + gitRoot + "/pullRequests/2/threads closed <nil> [map[commentType:text content:<!-- mark -->\nagain parentCommentId:0]]",
	}
	if fmt.Sprint(wrote) != fmt.Sprint(want) {
		t.Errorf("wrote\n%q\nwant\n%q", wrote, want)
	}
}
