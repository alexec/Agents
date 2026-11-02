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
