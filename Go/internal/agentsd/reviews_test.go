package agentsd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// reviewsIn is pins/list's For Review pull requests of the folder on repo.
func reviewsIn(t *testing.T, d *Daemon, c *conn, id int, repo string) []wire.ReviewPull {
	t.Helper()
	var listed []wire.FolderPins
	json.Unmarshal(c.call(t, id, "pins/list", wire.Empty{}), &listed)
	for _, pp := range listed {
		if d.folderRepo(store.FolderPath(pp.Folder)).path == repo && len(pp.Reviews) > 0 {
			return pp.Reviews
		}
	}
	return nil
}

// #3330: For Review lists each folder's open pull requests labelled needs-approval, newest
// first, but not one labelled approved or changes-wanted too, nor a draft; a dismissed one is
// kept out after the next read too, and the dismissal is kept on disk.
func TestForReviewListsPullRequestsWaitingForApproval(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	pr := func(repo string, n int, updated string, labels ...string) githubmcp.Item {
		return githubmcp.Item{Repo: repo, Number: n, PR: true, State: "open", Title: "PR " + updated,
			URL:    fmt.Sprintf("https://github.com/%s/pull/%d", repo, n),
			Author: "alexec", Labels: append([]string{"needs-approval"}, labels...), UpdatedAt: updated + "T10:00:00Z"}
	}
	older, newer := pr("alexec/agents", 1, "2026-11-01"), pr("alexec/agents", 2, "2026-11-02")
	approved, wanted := pr("alexec/agents", 3, "2026-11-03", "approved"), pr("alexec/agents", 4, "2026-11-03", "changes-wanted")
	draft := pr("alexec/agents", 5, "2026-11-03")
	draft.Draft = true
	web := pr("alexec/web", 6, "2026-11-01")
	gh.reviews = []githubmcp.Item{newer, older, approved, wanted, draft, web}

	d.readReviews(d.ctx)
	got := reviewsIn(t, d, c, 1, "alexec/agents")
	if len(got) != 2 || got[0].Number != 2 || got[1].Number != 1 || got[0].Repo != "alexec/agents" ||
		string(got[0].URL) != newer.URL || deref(got[0].Author) != "alexec" || got[0].Title != newer.Title ||
		deref(got[0].Ref) != "github:alexec/agents#2" {
		t.Fatalf("agents' reviews: %+v", got)
	}
	if web := reviewsIn(t, d, c, 2, "alexec/web"); len(web) != 1 || web[0].Number != 6 {
		t.Fatalf("web's reviews: %+v", web)
	}
	// The Remote reads them in its catch-up.
	var snapshot wire.CatchUpSnapshot
	json.Unmarshal(c.call(t, 20, "client/catchUp", wire.CatchUpRequest{Parts: []string{"pins"}}), &snapshot)
	caught := 0
	for _, pp := range snapshot.Pins {
		caught += len(pp.Reviews)
	}
	if caught != 3 {
		t.Fatalf("the catch-up's reviews: %d", caught)
	}

	var folder wire.URL
	var listed []wire.FolderPins
	json.Unmarshal(c.call(t, 3, "pins/list", wire.Empty{}), &listed)
	for _, pp := range listed {
		if len(pp.Reviews) == 2 {
			folder = pp.Folder
		}
	}
	c.call(t, 4, "reviews/dismiss", wire.ReviewDismissRequest{Folder: folder, URL: wire.URL(newer.URL)})
	if got := reviewsIn(t, d, c, 5, "alexec/agents"); len(got) != 1 || got[0].Number != 1 {
		t.Fatalf("after Dismiss: %+v", got)
	}
	d.readReviews(d.ctx)
	if got := reviewsIn(t, d, c, 6, "alexec/agents"); len(got) != 1 || got[0].Number != 1 {
		t.Fatalf("a dismissed pull request came back: %+v", got)
	}

	// #3464: one the person opened is said opened, after the next read too, and kept on disk.
	if got := reviewsIn(t, d, c, 30, "alexec/agents"); got[0].Opened != nil {
		t.Fatalf("not opened yet: %+v", got)
	}
	c.call(t, 31, "reviews/open", wire.ReviewOpenRequest{Folder: folder, URL: wire.URL(older.URL)})
	d.readReviews(d.ctx)
	if got := reviewsIn(t, d, c, 32, "alexec/agents"); len(got) != 1 || got[0].Opened == nil || !*got[0].Opened {
		t.Fatalf("after open: %+v", got)
	}
	if b, err := os.ReadFile(d.reviewOpenedPath()); err != nil || !strings.Contains(string(b), older.URL) {
		t.Fatalf("the opened pull request is kept on disk: %s %v", b, err)
	}
	b, err := os.ReadFile(d.reviewDismissalsPath())
	if err != nil || !strings.Contains(string(b), newer.URL) {
		t.Fatalf("the dismissal is kept on disk: %s %v", b, err)
	}

	// Gone from GitHub's list (approved, closed), it goes from For Review.
	gh.reviews = nil
	d.setReviews(map[string][]wire.ReviewPull{})
	if got := reviewsIn(t, d, c, 7, "alexec/agents"); got != nil {
		t.Fatalf("nothing waits: %+v", got)
	}
}
