package githubmcp

import (
	"context"
	"strings"
	"testing"
)

// CodeRabbit (#1344): its two events over the fake GitHub, what RealGitHub reads for them,
// and its tools and marks through the views' fake API.

func (f *fakeGitHub) CodeRabbitPRs(context.Context, string) ([]ReviewedPR, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]ReviewedPR(nil), f.reviewed...), f.err
}

func (f *fakeGitHub) CodeRabbitComments(_ context.Context, _, since string) ([]CodeRabbitComment, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []CodeRabbitComment
	for _, c := range f.rabbit {
		if !before(c.At, since) {
			out = append(out, c)
		}
	}
	return out, false, f.err
}

func (f *fakeGitHub) setReviewed(prs ...ReviewedPR) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reviewed = prs
}

func TestReviewPostedIsRaisedOncePerReview(t *testing.T) {
	h := newHarness(t)
	all := map[string]any{"repo": repo}
	pr := PR{Number: 1, Title: "Average", Branch: "walk/coderabbit-check", URL: "https://github.com/alexec/agents/pull/1"}
	stranger := ReviewedPR{PR: PR{Number: 2, Branch: "fork"}, HeadSHA: "f1", Reviewed: true}
	h.fake.setReviewed(ReviewedPR{PR: pr, HeadSHA: "a1", Reviewed: true, Trusted: true}, stranger)
	first := h.poll("review.posted", all, nil)
	equal(t, ids(first), []string{}, "a commit already reviewed is known")
	again := h.poll("review.posted", all, first["cursor"])
	equal(t, ids(again), []string{}, "and not raised later")

	// A push: its status pending, then at success with its review; as on alexec/agents-walk.
	reviewed := func(status string, done bool, review int) ReviewedPR {
		r := ReviewedPR{PR: pr, HeadSHA: "b2", Reviewed: done, StatusAt: status, Trusted: true, URL: pr.URL}
		if review != 0 {
			r.Review, r.ReviewID = "commented", review
		}
		return r
	}
	h.fake.setReviewed(reviewed("t1", false, 0), stranger)
	pushed := h.poll("review.posted", all, again["cursor"])
	equal(t, ids(pushed), []string{}, "a commit it is reviewing")
	h.fake.setReviewed(reviewed("t1", false, 7), stranger)
	early := h.poll("review.posted", all, pushed["cursor"])
	equal(t, ids(early), []string{}, "its review before its status: still reviewing")
	h.fake.setReviewed(reviewed("t2", true, 7), stranger)
	raised := h.poll("review.posted", all, early["cursor"])
	e := eventsOf(raised)
	if len(e) != 1 || !strings.HasPrefix(e[0]["eventId"].(string), "review.posted:"+repo+":1:b2:t2:") {
		t.Fatalf("raised %v", ids(raised))
	}
	data := e[0]["data"].(map[string]any)
	equal(t, []any{data["headSha"], data["state"], data["pr"].(map[string]any)["branch"]}, []any{"b2", "commented", "walk/coderabbit-check"}, "data")
	equal(t, ids(h.poll("review.posted", all, raised["cursor"])), []string{}, "a review is raised once")

	// A full review of the same commit posts no review, only its status again.
	h.fake.setReviewed(reviewed("t3", false, 7), stranger)
	full := h.poll("review.posted", all, raised["cursor"])
	equal(t, ids(full), []string{}, "a full review running")
	h.fake.setReviewed(reviewed("t4", true, 7), stranger)
	equal(t, len(ids(h.poll("review.posted", all, full["cursor"]))), 1, "a full review finished")

	// With no status, its review says so.
	h.fake.setReviewed(ReviewedPR{PR: pr, HeadSHA: "c3", Reviewed: true, Review: "commented", ReviewID: 9, Trusted: true}, stranger)
	if got := ids(h.poll("review.posted", all, full["cursor"])); len(got) != 1 || !strings.HasPrefix(got[0], "review.posted:"+repo+":1:c3:9:") {
		t.Fatalf("no status: %v", got)
	}

	// A fork's PR, or a stranger's, only with anyone.
	everyone := h.poll("review.posted", map[string]any{"repo": repo, "anyone": true}, first["cursor"])
	equal(t, len(ids(everyone)), 2, "anyone: the new commit and the fork's")
}

func TestReviewCommentIsEachOfItsCommentsOnTheRepoOwnPRs(t *testing.T) {
	h := newHarness(t)
	first := h.poll("review.comment", map[string]any{"repo": repo}, nil)
	pr := PR{Number: 1, Title: "Average", Branch: "walk/coderabbit-check"}
	h.fake.mu.Lock()
	h.fake.rabbit = []CodeRabbitComment{
		{ID: 41, PR: pr, Path: "average.py", Line: 6, Body: "Return the mean without subtracting one.", At: h.at(1), Trusted: true},
		{ID: 42, PR: pr, Path: "average.py", Line: 6, InReplyTo: 41, Body: "Thanks: fixed.", At: h.at(2), Trusted: true},
		{ID: 43, PR: PR{Number: 2, Branch: "fork"}, Path: "x.py", At: h.at(3)},
	}
	h.fake.mu.Unlock()
	got := h.poll("review.comment", map[string]any{"repo": repo}, first["cursor"])
	equal(t, ids(got), []string{"review.comment:" + repo + ":41", "review.comment:" + repo + ":42"}, "the repo's own PRs")
	c := eventsOf(got)[1]["data"].(map[string]any)["comment"].(map[string]any)
	equal(t, []any{c["id"], c["inReplyTo"], c["line"]}, []any{42.0, 41.0, 6.0}, "an answer in a thread")
	equal(t, ids(h.poll("review.comment", map[string]any{"repo": repo, "pr": 2, "anyone": true}, first["cursor"])),
		[]string{"review.comment:" + repo + ":43"}, "pr and anyone")
}

func TestRealGitHubKnowsCodeRabbitByItsApp(t *testing.T) {
	api := newFakeAPI(t, map[string]string{
		"repos/" + repo + "/pulls/comments": `[
			{"id": 3, "user": {"login": "coderabbitai[bot]", "type": "Bot"}, "performed_via_github_app": null, "path": "average.py", "line": 6,
			 "pull_request_url": "https://api.github.com/repos/` + repo + `/pulls/1", "created_at": "2026-10-19T03:46:35Z", "body": "Return the mean."},
			{"id": 2, "user": {"login": "coderabbitai", "type": "User"}, "path": "average.py", "line": 6,
			 "pull_request_url": "https://api.github.com/repos/` + repo + `/pulls/1", "created_at": "2026-10-19T03:46:30Z", "body": "a person named so"},
			{"id": 1, "user": {"login": "alexec", "type": "User"}, "path": "average.py", "line": 6,
			 "pull_request_url": "https://api.github.com/repos/` + repo + `/pulls/1", "created_at": "2026-10-19T03:46:20Z", "body": "mine"}]`,
		"repos/" + repo + "/pulls/1": `{"number": 1, "title": "Average", "html_url": "u", "head": {"ref": "walk/coderabbit-check",
			"repo": {"full_name": "` + repo + `"}}, "user": {"login": "alexec", "type": "User"}, "author_association": "OWNER"}`,
		"graphql": `{"data": {"repository": {"pullRequests": {"nodes": [
			{"number": 1, "headRefName": "a", "headRefOid": "h1", "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"},
			 "reviews": {"nodes": [{"author": {"login": "coderabbitai", "__typename": "Bot"}, "body": "Actionable comments posted: 1", "state": "COMMENTED", "url": "r1", "databaseId": 5, "commit": {"oid": "h1"}},
			   {"author": {"login": "coderabbitai", "__typename": "Bot"}, "body": "", "state": "COMMENTED", "url": "r9", "databaseId": 9, "commit": {"oid": "h1"}}]},
			 "commits": {"nodes": [{"commit": {"oid": "h1", "status": null}}]}},
			{"number": 2, "headRefName": "b", "headRefOid": "h2", "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"},
			 "reviews": {"nodes": [{"author": {"login": "coderabbitai", "__typename": "User"}, "state": "APPROVED", "commit": {"oid": "h2"}}]},
			 "commits": {"nodes": [{"commit": {"oid": "h2", "status": {"context": {"state": "PENDING", "createdAt": "2026-10-19T19:26:55Z"}}}}]}},
			{"number": 3, "headRefName": "c", "headRefOid": "h3", "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"},
			 "reviews": {"nodes": [{"author": {"login": "coderabbitai", "__typename": "Bot"}, "state": "COMMENTED", "commit": {"oid": "old"}}]},
			 "commits": {"nodes": [{"commit": {"oid": "h3", "status": {"context": {"state": "SUCCESS", "createdAt": "2026-10-19T19:29:03Z"}}}}]}},
			{"number": 4, "headRefName": "d", "headRefOid": "h4", "authorAssociation": "OWNER", "author": {"login": "alexec", "__typename": "User"},
			 "reviews": {"nodes": [{"author": {"login": "coderabbitai", "__typename": "Bot"}, "body": "Actionable comments posted: 0", "state": "COMMENTED", "databaseId": 6, "commit": {"oid": "h4"}}]},
			 "commits": {"nodes": [{"commit": {"oid": "h4", "status": {"context": {"state": "PENDING", "createdAt": "2026-10-19T19:26:55Z"}}}}]}}]}}}}`,
	})
	gh := api.github()
	comments, _, err := gh.CodeRabbitComments(context.Background(), repo, "2026-10-19T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(comments) != 1 || comments[0].ID != 3 || comments[0].PR.Branch != "walk/coderabbit-check" || !comments[0].Trusted {
		t.Fatalf("only its bot's comment, with its PR: %+v", comments)
	}
	prs, err := gh.CodeRabbitPRs(context.Background(), repo)
	if err != nil {
		t.Fatal(err)
	}
	got := []any{}
	for _, p := range prs {
		got = append(got, p.Reviewed, p.Review, p.round())
	}
	equal(t, got, []any{true, "commented", "h1:5", false, "", "h2:2026-10-19T19:26:55.000Z", true, "", "h3:2026-10-19T19:29:03.000Z",
		false, "commented", "h4:2026-10-19T19:26:55.000Z"},
		"its status at success, set anew by each review; with no status, a review on the head by its bot (not its answer in a thread)")
}

func TestThePageNamesCodeRabbitAndItsToolsPostItsCommands(t *testing.T) {
	c, api := viewsClient(t)
	_, p := callTool(t, c, "show_pull_request", map[string]any{"number": 7})
	rabbit, _ := p["codeRabbit"].(map[string]any)
	if rabbit == nil || rabbit["review"] != "commented" || rabbit["reviewUrl"] != "u2" || rabbit["status"] != "reviewed" || !strings.Contains(rabbit["summary"].(string), "Walkthrough") {
		t.Fatalf("codeRabbit: %v", p["codeRabbit"])
	}
	comments := p["comments"].([]any)
	if len(comments) != 1 || comments[0].(map[string]any)["app"] != "CodeRabbit" {
		t.Errorf("its summary is its block, its review is marked as its: %v", comments)
	}
	first := p["threads"].([]any)[0].(map[string]any)["comments"].([]any)[0].(map[string]any)
	if first["app"] != "CodeRabbit" || first["id"] != 44.0 {
		t.Errorf("thread: %v", first)
	}
	_, board := callTool(t, c, "show_pull_requests", map[string]any{})
	if board["prs"].([]any)[0].(map[string]any)["codeRabbit"] != "reviewed" {
		t.Errorf("board: %v", board["prs"])
	}

	for _, call := range []struct {
		tool string
		args map[string]any
	}{
		{"coderabbit_review", map[string]any{"number": 7}},
		{"coderabbit_review", map[string]any{"number": 7, "full": true}},
		{"coderabbit_resolve", map[string]any{"number": 7}},
		{"coderabbit_reply", map[string]any{"number": 7, "commentId": 44, "body": "Fixed: it divides by the count now."}},
		{"coderabbit_reply", map[string]any{"number": 7, "commentId": 44, "body": "@CodeRabbitAI is this right?"}},
	} {
		if r, _ := callTool(t, c, call.tool, call.args); r.IsError {
			t.Fatalf("%s: %v", call.tool, r.Content)
		}
	}
	if r, _ := callTool(t, c, "coderabbit_reply", map[string]any{"number": 7, "commentId": 44, "body": " "}); !r.IsError {
		t.Error("an empty answer was posted")
	}
	api.mu.Lock()
	defer api.mu.Unlock()
	equal(t, api.posted, []string{
		"/repos/o/r/issues/7/comments @coderabbitai review",
		"/repos/o/r/issues/7/comments @coderabbitai full review",
		"/repos/o/r/issues/7/comments @coderabbitai resolve",
		"/repos/o/r/pulls/7/comments/44/replies @coderabbitai Fixed: it divides by the count now.",
		"/repos/o/r/pulls/7/comments/44/replies @CodeRabbitAI is this right?",
	}, "posted")
}
