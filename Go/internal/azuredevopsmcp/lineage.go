package azuredevopsmcp

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// What the daemon's lineage asks Azure Repos (#3952), as it asks Bitbucket (#3879) and Forgejo
// (#3844): a pull request's title and state, a release's commits and pull requests, and the
// cost comment on a merged pull request. Azure Repos has no issues (they are Azure Boards' work
// items) and no milestones.

// Node is a pull request's title, state (open, closed or merged) and labels (its tags).
type Node struct {
	Title  string
	State  string
	Labels []string
}

// Commit is one commit of a compare: its sha and message.
type Commit struct{ SHA, Message string }

// Node is a pull request: a completed one's state is merged, and an abandoned one's closed.
func (f *RealAzureDevOps) Node(ctx context.Context, repo string, number int) (Node, error) {
	var p forgePullJSON
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p); err != nil {
		return Node{}, err
	}
	if p.Title == "" {
		return Node{}, errors.New("Azure DevOps did not say its title")
	}
	return Node{Title: p.Title, State: f.item(repo, p).State, Labels: p.labels()}, nil
}

// fullSHA is a commit's whole id; any other ref is a tag.
var fullSHA = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)

// commitJSON is a commit of a list: Azure DevOps cuts a long comment, but its first line stays.
type commitJSON struct {
	CommitID  string `json:"commitId"`
	Comment   string `json:"comment"`
	Committer struct {
		Date time.Time `json:"date"`
	} `json:"committer"`
}

// version sets a version of the commits query: a sha's, else a tag's.
func version(q url.Values, which, ref string) {
	kind := "tag"
	if fullSHA.MatchString(ref) {
		kind = "commit"
	}
	q.Set("searchCriteria."+which+".version", ref)
	q.Set("searchCriteria."+which+".versionType", kind)
}

// CommitTime is the committer's time of a tag's or a sha's commit.
func (f *RealAzureDevOps) CommitTime(ctx context.Context, repo, ref string) (time.Time, error) {
	q := url.Values{"searchCriteria.$top": {"1"}}
	version(q, "itemVersion", ref)
	var list struct {
		Value []commitJSON `json:"value"`
	}
	if err := f.get(ctx, api(repoPath(repo)+"/commits", q), false, &list); err != nil {
		return time.Time{}, err
	}
	if len(list.Value) == 0 || list.Value[0].Committer.Date.IsZero() {
		return time.Time{}, errors.New("Azure DevOps did not say the commit's date")
	}
	return list.Value[0].Committer.Date, nil
}

// compareMax bounds the commits of a compare; the daemon links at most 1000.
const compareMax = 1000

// comparePage is how many commits one read of a compare asks for.
const comparePage = 100

// Compare is the commits after base, up to head, newest first: the commits of head that base
// does not have.
func (f *RealAzureDevOps) Compare(ctx context.Context, repo, base, head string) ([]Commit, error) {
	var out []Commit
	for len(out) < compareMax {
		q := url.Values{"searchCriteria.$top": {strconv.Itoa(comparePage)}, "searchCriteria.$skip": {strconv.Itoa(len(out))}}
		version(q, "itemVersion", head)
		version(q, "compareVersion", base)
		var list struct {
			Value []commitJSON `json:"value"`
		}
		if err := f.get(ctx, api(repoPath(repo)+"/commits", q), false, &list); err != nil {
			return nil, err
		}
		for _, c := range list.Value {
			out = append(out, Commit{c.CommitID, c.Comment})
		}
		if len(list.Value) < comparePage {
			break
		}
	}
	return out, nil
}

// CommitPR is the completed pull request whose merge commit sha is, 0 for none.
func (f *RealAzureDevOps) CommitPR(ctx context.Context, repo, sha string) (int, error) {
	var res struct {
		Results []map[string][]struct {
			ID     int    `json:"pullRequestId"`
			Status string `json:"status"`
		} `json:"results"`
	}
	query := map[string]any{"queries": []any{map[string]any{"type": "lastMergeCommit", "items": []string{sha}}}}
	if err := f.send(ctx, http.MethodPost, api(repoPath(repo)+"/pullrequestquery", nil), query, &res); err != nil {
		return 0, err
	}
	for _, r := range res.Results {
		for _, p := range r[sha] {
			if p.Status == "completed" {
				return p.ID, nil
			}
		}
	}
	return 0, nil
}

// CostComment edits the comment id names (thread/comment), or the first of the pull request's
// that starts with mark, or else posts one in a closed thread of its own, so a branch policy
// that wants every comment resolved is not held by it, and says its id. A comment id names
// that was deleted is posted again.
func (f *RealAzureDevOps) CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error) {
	given := id
	if id == "" {
		// Not shared: a comment posted a moment ago must be found.
		threads, err := f.threads(ctx, repo, number, false)
		if err != nil {
			return "", err
		}
	find:
		for _, t := range threads {
			if t.IsDeleted || t.onALine() {
				continue
			}
			for _, c := range t.Comments {
				if !c.IsDeleted && c.ParentCommentID == 0 && strings.HasPrefix(c.Content, mark) {
					id = fmt.Sprintf("%d/%d", t.ID, c.ID)
					break find
				}
			}
		}
	}
	if id != "" {
		thread, comment, ok := strings.Cut(id, "/")
		if !ok {
			return "", fmt.Errorf("%q is not a thread and a comment", id)
		}
		path := fmt.Sprintf("%s/pullRequests/%d/threads/%s/comments/%s", repoPath(repo), number, url.PathEscape(thread), url.PathEscape(comment))
		var c threadCommentJSON
		err := f.send(ctx, http.MethodPatch, api(path, nil), map[string]any{"content": body}, &c)
		if IsNotFound(err) && given != "" {
			return f.CostComment(ctx, repo, number, "", mark, body)
		}
		if err != nil {
			return "", err
		}
		return id, nil
	}
	var t threadJSON
	if err := f.send(ctx, http.MethodPost, api(fmt.Sprintf("%s/pullRequests/%d/threads", repoPath(repo), number), nil),
		map[string]any{"status": "closed", "comments": []any{map[string]any{"parentCommentId": 0, "content": body, "commentType": "text"}}},
		&t); err != nil {
		return "", err
	}
	if t.ID == 0 {
		return "", errors.New("Azure DevOps did not say the thread's id")
	}
	// The first comment of a thread is comment 1.
	first := 1
	if len(t.Comments) > 0 && t.Comments[0].ID > 0 {
		first = t.Comments[0].ID
	}
	return fmt.Sprintf("%d/%d", t.ID, first), nil
}
