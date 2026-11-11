package azuredevopsmcp

import (
	"context"
	"strings"
	"testing"
)

// #3803: a list is the repository's pull requests of a state, the newest first, filtered by a
// tag and by words, and goes on from its cursor.
func TestSearchListsPullRequestsByState(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{
		pull(3, "three", alex, obj{"creationDate": at(30), "labels": []any{obj{"name": "ui", "active": true}}, "description": "Fix the sheet"}),
		pull(2, "two", dev, obj{"creationDate": at(20), "isDraft": true, "mergeStatus": "conflicts",
			"reviewers": []any{obj{"id": "a1", "displayName": "Alex", "vote": -5}}}),
		pull(1, "one", alex, obj{"status": "completed", "creationDate": at(5), "closedDate": at(40)}),
		pull(4, "four", alex, obj{"status": "abandoned", "creationDate": at(1), "closedDate": at(10)}),
	}
	ado := f.azureDevOps()
	ctx := context.Background()

	open, err := ado.Search(ctx, []string{repo}, SearchFilter{}, "", 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(open.Items) != 2 || open.Items[0].Number != 3 || open.Items[1].Number != 2 || open.Next != "" {
		t.Fatalf("open: %+v", open)
	}
	three, two := open.Items[0], open.Items[1]
	same(t, three.Labels, []string{"ui"})
	same(t, []any{three.State, three.Mergeable, three.Review, three.Author}, []any{"open", "mergeable", "", "alex@acme.test"})
	if !strings.HasSuffix(three.URL, web+"/pullrequest/3") {
		t.Errorf("url %s", three.URL)
	}
	same(t, []any{two.Draft, two.Mergeable, two.Review, two.Author}, []any{true, "conflicting", "changes_requested", "dev@acme.test"})
	same(t, []any{two.AuthorAvatar, three.AuthorAvatar}, []any{"https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2", ""})

	closed, err := ado.Search(ctx, []string{repo}, SearchFilter{State: "closed"}, "", 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(closed.Items) != 2 || closed.Items[0].Number != 1 || closed.Items[0].State != "merged" || closed.Items[1].State != "closed" {
		t.Fatalf("closed: %+v", closed.Items)
	}
	// #4373: when each opened, and when a completed or abandoned one closed.
	same(t, []any{three.CreatedAt, three.ClosedAt, closed.Items[0].CreatedAt, closed.Items[0].ClosedAt, closed.Items[1].ClosedAt},
		[]any{at(30), "", at(5), at(40), at(10)})

	byTag, _ := ado.Search(ctx, []string{repo}, SearchFilter{Label: "UI"}, "", 50)
	byWords, _ := ado.Search(ctx, []string{repo}, SearchFilter{Query: "sheet"}, "", 50)
	byAssignee, _ := ado.Search(ctx, []string{repo}, SearchFilter{Assignee: "alex"}, "", 50)
	if len(byTag.Items) != 1 || len(byWords.Items) != 1 || byWords.Items[0].Number != 3 || len(byAssignee.Items) != 0 {
		t.Fatalf("by tag %+v, by words %+v, by assignee %+v", byTag.Items, byWords.Items, byAssignee.Items)
	}

	// A page of one goes on from its cursor.
	first, _ := ado.Search(ctx, []string{repo}, SearchFilter{State: "all"}, "", 1)
	if len(first.Items) != 1 || first.Next == "" {
		t.Fatalf("first page %+v", first)
	}
	second, err := ado.Search(ctx, []string{repo}, SearchFilter{State: "all"}, first.Next, 1)
	if err != nil || len(second.Items) != 1 || second.Items[0].Number == first.Items[0].Number {
		t.Fatalf("second page %+v %v", second, err)
	}
	if _, err := ado.Search(ctx, []string{repo}, SearchFilter{}, "nonsense!", 1); err == nil {
		t.Fatal("a cursor no list gave")
	}
}

// #3803: a pull request's page is its description, its comments not on a line (no system
// comment), its builds' and statuses' checks, the line threads not resolved, and its files.
func TestItemPageReadsAPullRequest(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(3, "three", alex, obj{"description": "Fixes #12", "autoCompleteSetBy": alex})}
	f.threads[3] = []obj{
		{"id": 1, "comments": []any{obj{"id": 1, "author": dev, "content": "Looks good", "publishedDate": at(2), "commentType": "text"}}},
		{"id": 2, "comments": []any{obj{"id": 1, "author": builder, "content": "Policy set", "publishedDate": at(1), "commentType": "system"}}},
		{"id": 3, "status": "active", "threadContext": obj{"filePath": "/a.go", "rightFileStart": obj{"line": 4}},
			"comments": []any{obj{"id": 1, "author": dev, "content": "Here", "publishedDate": at(3)}}},
		{"id": 4, "status": "fixed", "threadContext": obj{"filePath": "/a.go", "rightFileStart": obj{"line": 9}},
			"comments": []any{obj{"id": 1, "author": dev, "content": "Done", "publishedDate": at(3)}}},
		{"id": 5, "comments": []any{obj{"id": 1, "author": renovate, "content": "Bump", "publishedDate": at(1), "commentType": "text"}}},
	}
	f.builds = []obj{build(70, 3, "sha3", "ci", "failed", 4)}
	f.statuses[3] = []obj{prStatus(1, "scan", "secrets", "succeeded", 2, 0), prStatus(2, "scan", "na", "notApplicable", 2, 0)}
	f.iterations[3] = []obj{{"id": 1}, {"id": 2, "sourceRefCommit": obj{"commitId": "sha3"}}}
	f.changes[3] = []obj{{"changeType": "edit", "item": obj{"path": "/a.go"}}, {"changeType": "add", "item": obj{"path": "/dir", "isFolder": true}}}

	d, err := f.azureDevOps().ItemPage(context.Background(), repo, 3, "")
	if err != nil {
		t.Fatal(err)
	}
	same(t, d.Body, "Fixes #12")
	if len(d.Thread) != 2 || d.Thread[0].Author != "renovate@acme.test" || !d.Thread[0].Bot || d.Thread[1].Body != "Looks good" ||
		d.Thread[1].Avatar != "https://dev.azure.com/acme/_apis/GraphProfile/MemberAvatars/aad.ZGV2" {
		t.Fatalf("thread %+v", d.Thread)
	}
	same(t, []any{d.ReviewThreads, d.FilesChanged, d.Head, d.Checks, d.AutoMerge, d.Comments, d.Before}, []any{1, 1, "sha3", "failing", true, 2, ""})
	same(t, d.CheckRuns, []CheckRun{{Name: "ci", State: "failing", URL: "https://ado.test/acme/Web%20App/_build/results?buildId=70", Build: 70},
		{Name: "scan/secrets", State: "passing", URL: "https://scan.test/1"}})

	if _, err := f.azureDevOps().ItemPage(context.Background(), repo, 404, ""); !IsNotFound(err) {
		t.Fatalf("a pull request not there: %v", err)
	}
}

// #3803: the writes are the person's: a comment in a thread of its own, tags added and taken
// off, abandon, merge at the head the person saw (now, or on its own once its policies pass),
// a vote of approved, and a build's failed jobs run again.
func TestForgeWritesAreThePersons(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(3, "three", alex, obj{})}
	ado := f.azureDevOps()
	ctx := context.Background()

	if url, err := ado.Comment(ctx, repo, 3, "Thanks"); err != nil || !strings.HasSuffix(url, web+"/pullrequest/3?discussionId=77") {
		t.Fatalf("comment %s %v", url, err)
	}
	if err := ado.SetLabels(ctx, repo, 3, []string{"ui"}, []string{"old tag"}); err != nil {
		t.Fatal(err)
	}
	if err := ado.SetState(ctx, repo, 3, true); err != nil {
		t.Fatal(err)
	}
	if err := ado.Merge(ctx, repo, 3, "sha2", "squash", false); err == nil || !strings.Contains(err.Error(), "newer commit") {
		t.Fatalf("a merge at an old head: %v", err)
	}
	if err := ado.Merge(ctx, repo, 3, "sha3", "squash", false); err != nil {
		t.Fatal(err)
	}
	if err := ado.Merge(ctx, repo, 3, "sha3", "rebase", true); err != nil {
		t.Fatal(err)
	}
	if err := ado.Merge(ctx, repo, 3, "sha3", "fast-forward", false); err == nil {
		t.Fatal("a method Azure DevOps has not")
	}
	if url, err := ado.Approve(ctx, repo, 3, "sha3"); err != nil || !strings.HasSuffix(url, "/pullrequest/3") {
		t.Fatalf("approve %s %v", url, err)
	}
	if url, err := ado.RetryBuild(ctx, repo, 70); err != nil || url != "https://ado.test/build" {
		t.Fatalf("retry %s %v", url, err)
	}
	var said []string
	for _, b := range f.posted {
		said = append(said, b["_method"].(string)+" "+strings.TrimPrefix(b["_path"].(string), gitRoot))
	}
	same(t, said, []string{
		"POST /pullRequests/3/threads",
		"POST /pullRequests/3/labels", "DELETE /pullRequests/3/labels/old tag",
		"PATCH /pullrequests/3",
		"PATCH /pullrequests/3", "PATCH /pullrequests/3",
		"PUT /pullrequests/3/reviewers/a1",
		"PATCH /acme/Web App/_apis/build/builds/70",
	})
	same(t, f.posted[1]["name"], "ui")
	same(t, f.posted[3]["status"], "abandoned")
	same(t, f.posted[4]["status"], "completed")
	same(t, f.posted[4]["completionOptions"], map[string]any{"mergeStrategy": "squash", "deleteSourceBranch": true})
	same(t, f.posted[4]["lastMergeSourceCommit"], map[string]any{"commitId": "sha3"})
	same(t, f.posted[5]["autoCompleteSetBy"], map[string]any{"id": "a1"})
	if _, completes := f.posted[5]["status"]; completes {
		t.Error("auto-complete completed it now")
	}
	same(t, f.posted[6]["vote"], float64(10))
}

// #3803: the merge methods are what the target branch's "Limit merge types" allows, every one
// with none; the tags offered are those of the repository's pull requests.
func TestMergeMethodsAndTags(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(3, "three", alex, obj{"labels": []any{obj{"name": "ui"}, obj{"name": "Docs"}, obj{"name": "gone", "active": false}}}),
		pull(2, "two", alex, obj{"labels": []any{obj{"name": "UI"}}})}
	ado := f.azureDevOps()
	ctx := context.Background()
	methods, err := ado.MergeMethods(ctx, repo, 3)
	if err != nil {
		t.Fatal(err)
	}
	same(t, methods, []string{"merge", "squash", "rebase"})
	f.set(func() {
		f.policies = []obj{{"isEnabled": true, "settings": obj{"allowSquash": true, "allowRebase": true, "allowNoFastForward": false}},
			{"isEnabled": false, "settings": obj{"allowNoFastForward": true}}}
	})
	methods, _ = ado.MergeMethods(ctx, repo, 3)
	same(t, methods, []string{"squash", "rebase"})
	tags, err := ado.RepoLabels(ctx, repo)
	if err != nil {
		t.Fatal(err)
	}
	same(t, tags, []string{"Docs", "ui"})
}

// #3803: the diff is each file's hunks, made of Azure DevOps's ranges of changed lines and the
// two commits' lines: an edit with its context, a file added and one removed.
func TestPRDiffMakesHunksOfRanges(t *testing.T) {
	f := newFake(t)
	f.pulls = []obj{pull(3, "three", alex, obj{})}
	f.iterations[3] = []obj{{"id": 1, "sourceRefCommit": obj{"commitId": "head"}, "commonRefCommit": obj{"commitId": "base"}}}
	f.changes[3] = []obj{
		{"changeType": "edit", "item": obj{"path": "/a.txt"}},
		{"changeType": "add", "item": obj{"path": "/new.txt"}},
		{"changeType": "delete", "item": obj{"path": "/gone.txt"}},
	}
	f.files["base:/a.txt"] = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n"
	f.files["head:/a.txt"] = "1\n2\n3\n4\nfive\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n"
	f.files["head:/new.txt"] = "hello\n"
	f.files["base:/gone.txt"] = "bye\n"
	f.fileDiffs = []obj{{"path": "/a.txt", "lineDiffBlocks": []any{
		obj{"changeType": "none", "originalLineNumberStart": 1, "originalLinesCount": 4, "modifiedLineNumberStart": 1, "modifiedLinesCount": 4},
		obj{"changeType": "edit", "originalLineNumberStart": 5, "originalLinesCount": 1, "modifiedLineNumberStart": 5, "modifiedLinesCount": 1},
		obj{"changeType": 1, "originalLineNumberStart": 17, "originalLinesCount": 0, "modifiedLineNumberStart": 17, "modifiedLinesCount": 1},
	}}}
	out, err := f.azureDevOps().PRDiff(context.Background(), repo, 3)
	if err != nil {
		t.Fatal(err)
	}
	files := out["files"].([]any)
	if len(files) != 3 || out["sha"] != "head" || out["cut"] != false {
		t.Fatalf("diff %+v", out)
	}
	a := files[0].(map[string]any)
	same(t, []any{a["path"], a["change"], a["additions"], a["deletions"]}, []any{"a.txt", "modified", 2, 1})
	hunks := a["hunks"].([]Hunk)
	if len(hunks) != 2 {
		t.Fatalf("hunks %+v", hunks)
	}
	same(t, hunks[0], Hunk{OldStart: 2, NewStart: 2, Lines: []DiffLine{{"context", "2"}, {"context", "3"}, {"context", "4"},
		{"removed", "5"}, {"added", "five"}, {"context", "6"}, {"context", "7"}, {"context", "8"}}})
	same(t, hunks[1], Hunk{OldStart: 14, NewStart: 14, Lines: []DiffLine{{"context", "14"}, {"context", "15"}, {"context", "16"}, {"added", "17"}}})
	added, removed := files[1].(map[string]any), files[2].(map[string]any)
	same(t, []any{added["change"], added["additions"], added["hunks"]}, []any{"added", 1, []Hunk{{OldStart: 1, NewStart: 1, Lines: []DiffLine{{"added", "hello"}}}}})
	same(t, []any{removed["change"], removed["deletions"], removed["hunks"]}, []any{"removed", 1, []Hunk{{OldStart: 1, NewStart: 1, Lines: []DiffLine{{"removed", "bye"}}}}})
}
