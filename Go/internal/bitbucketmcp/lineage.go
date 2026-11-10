package bitbucketmcp

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

// What the daemon's lineage asks Bitbucket Cloud (#3879), as it asks Forgejo (#3844) and gh and
// glab for GitHub and GitLab: a node's title and state, a release's commits and pull
// requests, and the cost comment on a merged pull request. Bitbucket numbers issues and pull
// requests apart, so a node says which it is.

// Node is an issue's or a pull request's title, state (open, closed or merged) and labels (an
// issue's kind and component).
type Node struct {
	Title  string
	State  string
	Labels []string
}

// Commit is one commit of a compare: its sha and message.
type Commit struct{ SHA, Message string }

// Node is an issue, or with pr a pull request: a merged pull request's state is merged, and a
// declined or superseded one's closed.
func (b *RealBitbucket) Node(ctx context.Context, repo string, number int, pr bool) (Node, error) {
	var n Node
	if pr {
		var p pullJSON
		if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
			return Node{}, err
		}
		n = Node{Title: p.Title, State: forgePullJSON{pullJSON: p}.item(repo).State, Labels: []string{}}
	} else {
		var i issueJSON
		if err := b.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &i); err != nil {
			return Node{}, err
		}
		n = Node{Title: i.Title, State: i.forgeItem(repo).State, Labels: i.labels()}
	}
	if n.Title == "" {
		return Node{}, errors.New("Bitbucket did not say its title")
	}
	return n, nil
}

// CommitTime is the time of a tag's, a branch's or a sha's commit: Bitbucket says only its
// author's date.
func (b *RealBitbucket) CommitTime(ctx context.Context, repo, ref string) (time.Time, error) {
	var j struct {
		Date time.Time `json:"date"`
	}
	if err := b.get(ctx, repoPath(repo)+"/commit/"+url.PathEscape(ref), false, &j); err != nil {
		return time.Time{}, err
	}
	if j.Date.IsZero() {
		return time.Time{}, errors.New("Bitbucket did not say the commit's date")
	}
	return j.Date, nil
}

// compareMax bounds the commits of a compare; the daemon links at most 1000.
const compareMax = 1000

// Compare is the commits after base, up to head, newest first. Bitbucket's next page of
// commits is a token, not a number, so its next link is followed.
func (b *RealBitbucket) Compare(ctx context.Context, repo, base, head string) ([]Commit, error) {
	path := repoPath(repo) + "/commits?include=" + url.QueryEscape(head) + "&exclude=" + url.QueryEscape(base) + "&pagelen=100"
	var out []Commit
	for path != "" && len(out) < compareMax {
		var page paged[struct {
			Hash    string `json:"hash"`
			Message string `json:"message"`
		}]
		if err := b.get(ctx, path, false, &page); err != nil {
			return nil, err
		}
		for _, c := range page.Values {
			out = append(out, Commit{c.Hash, c.Message})
		}
		next, ok := strings.CutPrefix(page.Next, b.Base)
		if !ok || len(page.Values) == 0 {
			break
		}
		path = next
	}
	return out, nil
}

// CommitPR is the pull request a commit was merged by, 0 for none: also when the repository's
// commits are not linked to its pull requests (a 404).
func (b *RealBitbucket) CommitPR(ctx context.Context, repo, sha string) (int, error) {
	var page paged[struct {
		ID    int    `json:"id"`
		State string `json:"state"`
	}]
	err := b.get(ctx, repoPath(repo)+"/commit/"+url.PathEscape(sha)+"/pullrequests", false, &page)
	if IsNotFound(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	for _, p := range page.Values {
		if p.State == "MERGED" {
			return p.ID, nil
		}
	}
	return 0, nil
}

// CostComment edits the comment id names, or the first of the pull request's that starts with
// mark, or else posts one, and says its id. A comment id names that was deleted is posted again.
func (b *RealBitbucket) CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error) {
	given := id
	if id == "" {
		// Not shared: a comment posted a moment ago must be found.
		list, _, err := all[commentJSON](ctx, b, fmt.Sprintf("%s/pullrequests/%d/comments", repoPath(repo), number), false)
		if err != nil {
			return "", err
		}
		for _, c := range list {
			if !c.Deleted && c.Inline == nil && strings.HasPrefix(c.Content.Raw, mark) {
				id = strconv.Itoa(c.ID)
				break
			}
		}
	}
	text := map[string]any{"content": map[string]any{"raw": body}}
	var c commentJSON
	var err error
	if id != "" {
		err = b.send(ctx, http.MethodPut, fmt.Sprintf("%s/pullrequests/%d/comments/%s", repoPath(repo), number, url.PathEscape(id)), text, &c)
		if IsNotFound(err) && given != "" {
			return b.CostComment(ctx, repo, number, "", mark, body)
		}
	} else {
		err = b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/comments", repoPath(repo), number), text, &c)
	}
	if err != nil {
		return "", err
	}
	if c.ID == 0 {
		return "", errors.New("Bitbucket did not say the comment's id")
	}
	return strconv.Itoa(c.ID), nil
}
