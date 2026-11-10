package forgejomcp

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// What the daemon's lineage asks Forgejo (#3844), as it asks gh and glab for GitHub and GitLab:
// a node's title and state, a release's commits and pull requests, and the cost comment on a
// merged pull request. Issues and pull requests share Forgejo's issue API, so one call says
// either.

// Node is an issue's or a pull request's title, state (open, closed or merged) and labels.
type Node struct {
	Title  string
	State  string
	Labels []string
}

// Commit is one commit of a compare: its sha and message.
type Commit struct{ SHA, Message string }

// Node is an issue or a pull request: a merged pull request's state is merged.
func (f *RealForgejo) Node(ctx context.Context, repo string, number int) (Node, error) {
	var j struct {
		Title       string  `json:"title"`
		State       string  `json:"state"`
		Labels      []label `json:"labels"`
		PullRequest *struct {
			Merged bool `json:"merged"`
		} `json:"pull_request"`
	}
	if err := f.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &j); err != nil {
		return Node{}, err
	}
	if j.Title == "" {
		return Node{}, errors.New("Forgejo did not say its title")
	}
	n := Node{Title: j.Title, State: j.State, Labels: labelNames(j.Labels)}
	if j.PullRequest != nil && j.PullRequest.Merged {
		n.State = "merged"
	}
	return n, nil
}

// CommitTime is the commit time of a tag, a branch or a sha.
func (f *RealForgejo) CommitTime(ctx context.Context, repo, ref string) (time.Time, error) {
	var j struct {
		Commit struct {
			Committer struct {
				Date time.Time `json:"date"`
			} `json:"committer"`
		} `json:"commit"`
	}
	if err := f.get(ctx, repoPath(repo)+"/git/commits/"+url.PathEscape(ref)+"?stat=false&verification=false&files=false", false, &j); err != nil {
		return time.Time{}, err
	}
	if j.Commit.Committer.Date.IsZero() {
		return time.Time{}, errors.New("Forgejo did not say the commit's date")
	}
	return j.Commit.Committer.Date, nil
}

// Compare is the commits after base, up to head.
func (f *RealForgejo) Compare(ctx context.Context, repo, base, head string) ([]Commit, error) {
	var j struct {
		Commits []struct {
			SHA    string `json:"sha"`
			Commit struct {
				Message string `json:"message"`
			} `json:"commit"`
		} `json:"commits"`
	}
	if err := f.get(ctx, repoPath(repo)+"/compare/"+url.PathEscape(base)+"..."+url.PathEscape(head), false, &j); err != nil {
		return nil, err
	}
	out := make([]Commit, 0, len(j.Commits))
	for _, c := range j.Commits {
		out = append(out, Commit{c.SHA, c.Commit.Message})
	}
	return out, nil
}

// CommitPR is the pull request a commit was merged by, 0 for none.
func (f *RealForgejo) CommitPR(ctx context.Context, repo, sha string) (int, error) {
	var j struct {
		Number int `json:"number"`
	}
	err := f.get(ctx, repoPath(repo)+"/commits/"+url.PathEscape(sha)+"/pull", false, &j)
	if IsNotFound(err) {
		return 0, nil
	}
	return j.Number, err
}

// CostComment edits the comment id names, or the first of the pull request's that starts with
// mark, or else posts one, and says its id. A comment id names that was deleted is posted again.
func (f *RealForgejo) CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error) {
	given := id
	// Not shared: a comment posted a moment ago must be found.
	for page := 1; id == "" && page <= maxPages; page++ {
		var list []commentJSON
		if err := f.get(ctx, query(fmt.Sprintf("%s/issues/%d/comments", repoPath(repo), number), page), false, &list); err != nil {
			return "", err
		}
		for _, c := range list {
			if strings.HasPrefix(c.Body, mark) {
				id = strconv.Itoa(c.ID)
				break
			}
		}
		if len(list) < perPage {
			break
		}
	}
	var c commentJSON
	var err error
	if id != "" {
		err = f.send(ctx, http.MethodPatch, fmt.Sprintf("%s/issues/comments/%s", repoPath(repo), url.PathEscape(id)), map[string]any{"body": body}, &c)
		if IsNotFound(err) && given != "" {
			return f.CostComment(ctx, repo, number, "", mark, body)
		}
	} else {
		err = f.send(ctx, http.MethodPost, fmt.Sprintf("%s/issues/%d/comments", repoPath(repo), number), map[string]any{"body": body}, &c)
	}
	if err != nil {
		return "", err
	}
	if c.ID == 0 {
		return "", errors.New("Forgejo did not say the comment's id")
	}
	return strconv.Itoa(c.ID), nil
}
