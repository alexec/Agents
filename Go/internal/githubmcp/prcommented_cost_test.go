package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// P20261031-1: a pr.commented wait with pr: N, over the real client, against a fake of GitHub
// that holds K people's comments on other issues and PRs. It counts what each poll asks for.

// commentAPI is GitHub's issues/comments listing (since and pages honoured) and the issues and
// pulls it names, counting every GET.
type commentAPI struct {
	*httptest.Server
	mu       sync.Mutex
	comments []map[string]any // newest first
	listings int
	items    int
}

func newCommentAPI(t *testing.T) *commentAPI {
	a := &commentAPI{}
	a.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		path := strings.TrimPrefix(r.URL.Path, "/")
		switch {
		case path == "repos/"+repo+"/issues/comments":
			a.listings++
			since := r.URL.Query().Get("since")
			page, _ := strconv.Atoi(r.URL.Query().Get("page"))
			per, _ := strconv.Atoi(r.URL.Query().Get("per_page"))
			var kept []map[string]any
			for _, c := range a.comments {
				if !before(c["created_at"].(string), since) {
					kept = append(kept, c)
				}
			}
			from, to := min(len(kept), (page-1)*per), min(len(kept), page*per)
			_ = json.NewEncoder(w).Encode(append([]map[string]any{}, kept[from:to]...))
		case strings.HasPrefix(path, "repos/"+repo+"/issues/"):
			a.items++
			n, _ := strconv.Atoi(strings.TrimPrefix(path, "repos/"+repo+"/issues/"))
			issue := map[string]any{"number": n}
			if n%2 == 0 {
				issue["pull_request"] = map[string]any{"url": "x"}
			}
			_ = json.NewEncoder(w).Encode(issue)
		case strings.HasPrefix(path, "repos/"+repo+"/pulls/"):
			a.items++
			n, _ := strconv.Atoi(strings.TrimPrefix(path, "repos/"+repo+"/pulls/"))
			_ = json.NewEncoder(w).Encode(map[string]any{"number": n, "title": "PR", "html_url": fmt.Sprintf("u%d", n),
				"head": map[string]any{"ref": fmt.Sprintf("agents/%d", n)}})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(a.Close)
	return a
}

// comment is a person's comment on issue (or PR) n at at.
func (a *commentAPI) comment(id, n int, at string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.comments = append(a.comments, map[string]any{"id": id, "html_url": fmt.Sprintf("c%d", id),
		"issue_url": fmt.Sprintf("%srepos/%s/issues/%d", a.URL+"/", repo, n), "body": "a person's words",
		"user": map[string]any{"login": "alexec"}, "author_association": "OWNER", "created_at": at})
	sort.SliceStable(a.comments, func(i, j int) bool { return before(a.comments[j]["created_at"].(string), a.comments[i]["created_at"].(string)) })
}

func (a *commentAPI) taken() (listings, items int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	l, i := a.listings, a.items
	a.listings, a.items = 0, 0
	return l, i
}

// prCommentedCost polls a pr: 950 wait over k comments on other issues and PRs and gives each
// poll's listing and item GETs, and whether the cursor moved past them.
func prCommentedCost(t *testing.T, k int) (firstListings, firstItems, secondListings, secondItems int, moved bool) {
	api := newCommentAPI(t)
	clock := time.Now().UTC().Truncate(time.Second)
	events := &Events{GitHub: NewRealGitHub(api.URL, func() string { return "token" },
		func(context.Context) (string, error) { return repo, nil }), Now: func() time.Time { return clock }}
	poll := func(cursor any) map[string]any {
		raw, _ := json.Marshal(map[string]any{"name": "pr.commented", "arguments": map[string]any{"repo": repo, "pr": 950}, "cursor": cursor})
		out, err := events.Poll(context.Background(), raw)
		if err != nil {
			t.Fatalf("poll: %v", err)
		}
		return out
	}
	start := poll(nil)["cursor"]
	for i := range k {
		api.comment(i+1, 1000+i, timeString(clock.Add(time.Duration(i+1)*time.Second)))
	}
	clock = clock.Add(time.Hour)
	api.taken()
	first := poll(start)
	firstListings, firstItems = api.taken()
	if got := first["events"].([]any); len(got) != 0 {
		t.Fatalf("raised %v for other PRs", got)
	}
	poll(first["cursor"])
	secondListings, secondItems = api.taken()
	return firstListings, firstItems, secondListings, secondItems, first["cursor"] != start
}

func TestAPRCommentedWaitFetchesNoOtherIssueAndMovesItsCursorPastThem(t *testing.T) {
	for _, k := range []int{50, 200} {
		l1, i1, l2, i2, moved := prCommentedCost(t, k)
		t.Logf("K=%d: first poll %d listing + %d item GETs, second poll %d listing + %d item GETs, cursor moved %v", k, l1, i1, l2, i2, moved)
		if i1 != 0 {
			t.Errorf("K=%d: the first poll fetched %d issues and pulls that are not PR 950", k, i1)
		}
		if i2 != 0 {
			t.Errorf("K=%d: the second poll fetched %d issues and pulls again", k, i2)
		}
		if !moved {
			t.Errorf("K=%d: the cursor stayed at the start", k)
		}
	}
}

// A wait on every PR asks whether an issue is a pull request once, not on every poll.
func TestPRCommentsAsksWhetherAnIssueIsAPullOnce(t *testing.T) {
	api := newCommentAPI(t)
	g := NewRealGitHub(api.URL, func() string { return "token" }, func(context.Context) (string, error) { return repo, nil })
	since := "2026-10-28T10:00:00.000Z"
	for i := range 10 {
		api.comment(i+1, 1000+i, fmt.Sprintf("2026-10-28T10:%02d:00Z", i+1))
	}
	for range 2 {
		if _, _, err := g.PRComments(context.Background(), repo, since, 0); err != nil {
			t.Fatal(err)
		}
	}
	_, items := api.taken()
	equal(t, items, 10+5+5, "10 issues once, and the 5 pulls each time")
}
