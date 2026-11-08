package githubmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// The daemon's forge writes (#3130): a person's own clicks on the Work pages, as the signed-in
// person, next to the views' merge, review and comment (pages.go), which they reuse.

// mergeSettings are the merge methods a repo allows, and the person's default there.
type mergeSettings struct {
	Default string `json:"viewerDefaultMergeMethod"`
	Squash  bool   `json:"squashMergeAllowed"`
	Merge   bool   `json:"mergeCommitAllowed"`
	Rebase  bool   `json:"rebaseMergeAllowed"`
}

// methods are merge, squash or rebase, as the repo allows them, the default first.
func (m mergeSettings) methods() []string {
	out := []string{}
	if d := strings.ToLower(m.Default); d != "" && m.allows(d) {
		out = append(out, d)
	}
	for _, method := range []string{"squash", "merge", "rebase"} {
		if m.allows(method) && (len(out) == 0 || out[0] != method) {
			out = append(out, method)
		}
	}
	return out
}

func (m mergeSettings) allows(method string) bool {
	return map[string]bool{"squash": m.Squash, "merge": m.Merge, "rebase": m.Rebase}[method]
}

// MergeBy merges a pull request at sha by method (merge, squash or rebase) and deletes its
// branch on GitHub; with auto, GitHub does that once its checks pass. When the head is another
// commit, GitHub merges nothing.
func (g *RealGitHub) MergeBy(ctx context.Context, repo string, number int, sha, method string, auto bool) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	if err := checkSha(sha); err != nil {
		return nil, err
	}
	if method != "merge" && method != "squash" && method != "rebase" {
		return nil, &GitHubError{Kind: Failed, Message: "method is merge, squash or rebase"}
	}
	var p struct {
		NodeID string `json:"node_id"`
		Head   ref    `json:"head"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/pulls/%d", repo, number), false, &p); err != nil {
		return nil, err
	}
	if p.Head.Sha != sha {
		return nil, headChanged(number)
	}
	if auto {
		const enable = `mutation($id: ID!, $sha: GitObjectID!, $method: PullRequestMergeMethod!) { enablePullRequestAutoMerge(input: {
  pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $sha}) { pullRequest { number } } }`
		var out struct{}
		if err := g.graphql(ctx, enable, map[string]any{"id": p.NodeID, "sha": sha, "method": strings.ToUpper(method)}, &out); err != nil {
			return nil, err
		}
		return map[string]any{"merged": false, "auto": true, "url": prURL(repo, number)}, nil
	}
	body, _ := json.Marshal(map[string]string{"merge_method": method, "sha": sha})
	if _, err := g.do(ctx, http.MethodPut, fmt.Sprintf("repos/%s/pulls/%d/merge", repo, number), body, false); err != nil {
		return nil, err
	}
	// Its branch goes when it is this repo's own, as --delete-branch does.
	if p.Head.Repo != nil && p.Head.Repo.FullName == repo && p.Head.Ref != "" {
		_, _ = g.do(ctx, http.MethodDelete, fmt.Sprintf("repos/%s/git/refs/heads/%s", repo, p.Head.Ref), nil, false)
	}
	return map[string]any{"merged": true, "auto": false, "url": prURL(repo, number)}, nil
}

// SetLabels adds labels to an issue or a pull request and takes others off it, by name. A label
// to take off that it does not have is not an error.
func (g *RealGitHub) SetLabels(ctx context.Context, repo string, number int, add, remove []string) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	if len(add) > 0 {
		body, _ := json.Marshal(map[string][]string{"labels": add})
		if _, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/issues/%d/labels", repo, number), body, false); err != nil {
			return err
		}
	}
	for _, name := range remove {
		_, err := g.do(ctx, http.MethodDelete, fmt.Sprintf("repos/%s/issues/%d/labels/%s", repo, number, url.PathEscape(name)), nil, false)
		var ge *GitHubError
		if err != nil && (!errors.As(err, &ge) || ge.Kind != NotFound) {
			return err
		}
	}
	return nil
}

// SetState closes an issue or a pull request, or opens it again.
func (g *RealGitHub) SetState(ctx context.Context, repo string, number int, closed bool) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]string{"state": map[bool]string{true: "closed", false: "open"}[closed]})
	_, err := g.do(ctx, http.MethodPatch, fmt.Sprintf("repos/%s/issues/%d", repo, number), body, false)
	return err
}

// SetBody writes an issue's or a pull request's body: a forge request's ticked line (#3865).
func (g *RealGitHub) SetBody(ctx context.Context, repo string, number int, text string) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]string{"body": text})
	_, err := g.do(ctx, http.MethodPatch, fmt.Sprintf("repos/%s/issues/%d", repo, number), body, false)
	return err
}

// Unassign takes people off an issue or a pull request: a forge request done (#3865).
func (g *RealGitHub) Unassign(ctx context.Context, repo string, number int, logins []string) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	body, _ := json.Marshal(map[string][]string{"assignees": logins})
	_, err := g.do(ctx, http.MethodDelete, fmt.Sprintf("repos/%s/issues/%d/assignees", repo, number), body, false)
	return err
}

// RepoLabels are a repo's labels, at most 100, with their colours.
func (g *RealGitHub) RepoLabels(ctx context.Context, repo string) ([]string, map[string]string, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, nil, err
	}
	var ls []label
	if err := g.get(ctx, fmt.Sprintf("repos/%s/labels?per_page=100", repo), false, &ls); err != nil {
		return nil, nil, err
	}
	names, colors := labelsOf(ls)
	return names, colors, nil
}

// The plan's writes (#3271): a child added to an epic, new or one that is there, and a child's
// "blocked by" links. GitHub's sub-issue and dependency APIs take an issue's id, not its number.

// issueID is the id of issue number of repo.
func (g *RealGitHub) issueID(ctx context.Context, repo string, number int) (int64, error) {
	if _, _, err := ownerName(repo); err != nil {
		return 0, err
	}
	var i struct {
		ID int64 `json:"id"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/issues/%d", repo, number), false, &i); err != nil {
		return 0, err
	}
	if i.ID == 0 {
		return 0, &GitHubError{Kind: NotFound, Message: fmt.Sprintf("no issue #%d in %s", number, repo)}
	}
	return i.ID, nil
}

// CreateIssue opens an issue in repo with labels (GitHub makes a label that the repo does not
// have), and is its number and URL.
func (g *RealGitHub) CreateIssue(ctx context.Context, repo, title string, labels []string) (int, string, error) {
	if _, _, err := ownerName(repo); err != nil {
		return 0, "", err
	}
	body, _ := json.Marshal(map[string]any{"title": title, "labels": append([]string{}, labels...)})
	data, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/issues", repo), body, false)
	if err != nil {
		return 0, "", err
	}
	var i struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
	}
	if json.Unmarshal(data, &i) != nil || i.Number < 1 {
		return 0, "", &GitHubError{Kind: Failed, Message: "GitHub's answer is not an issue"}
	}
	return i.Number, i.HTMLURL, nil
}

// AddSubIssue makes issue childNumber of childRepo a sub-issue of issue number of repo; it leaves
// the parent it had, as a person who adds it to this epic means.
func (g *RealGitHub) AddSubIssue(ctx context.Context, repo string, number int, childRepo string, childNumber int) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	id, err := g.issueID(ctx, childRepo, childNumber)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{"sub_issue_id": id, "replace_parent": true})
	_, err = g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/issues/%d/sub_issues", repo, number), body, false)
	return err
}

// SetBlockedBy says that issue number of repo is blocked by issue blockerNumber of blockerRepo,
// or with blocked false that it is not. A link to take off that is not there is not an error.
func (g *RealGitHub) SetBlockedBy(ctx context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	if _, _, err := ownerName(repo); err != nil {
		return err
	}
	id, err := g.issueID(ctx, blockerRepo, blockerNumber)
	if err != nil {
		return err
	}
	path := fmt.Sprintf("repos/%s/issues/%d/dependencies/blocked_by", repo, number)
	if blocked {
		body, _ := json.Marshal(map[string]int64{"issue_id": id})
		_, err = g.do(ctx, http.MethodPost, path, body, false)
		return err
	}
	_, err = g.do(ctx, http.MethodDelete, fmt.Sprintf("%s/%d", path, id), nil, false)
	var ge *GitHubError
	if err != nil && errors.As(err, &ge) && ge.Kind == NotFound {
		return nil
	}
	return err
}
