package bitbucketmcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The daemon's forge writes (#3786, after Forgejo's in #3753): a person's own clicks on the
// Work pages, as the signed-in person. Bitbucket keeps issues and pull requests apart, so each
// write says which it is on.

// Kinds are an issue's kinds, the labels every repository has.
var Kinds = []string{"bug", "enhancement", "proposal", "task"}

// NoPRLabels is why a pull request's labels are not read or written: Bitbucket's have none.
const NoPRLabels = "Bitbucket's pull requests have no labels"

func kindPath(pr bool) string { return map[bool]string{false: "issues", true: "pullrequests"}[pr] }

// Comment adds a comment, as Markdown, to an issue or a pull request, and says its link.
func (b *RealBitbucket) Comment(ctx context.Context, repo string, number int, pr bool, body string) (string, error) {
	var c commentJSON
	if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/%s/%d/comments", repoPath(repo), kindPath(pr), number),
		map[string]any{"content": map[string]any{"raw": body}}, &c); err != nil {
		return "", err
	}
	return c.Links.HTML.Href, nil
}

// SetLabels sets an issue's kind or component, the labels Bitbucket's issues have: a kind
// added is its kind, another label its component. A kind cannot be taken off, only changed; a
// component taken off leaves none.
func (b *RealBitbucket) SetLabels(ctx context.Context, repo string, number int, add, remove []string) error {
	change := map[string]any{}
	for _, l := range add {
		field, value := "component", any(map[string]any{"name": l})
		if slices.Contains(Kinds, strings.ToLower(l)) {
			field, value = "kind", strings.ToLower(l)
		}
		if _, twice := change[field]; twice {
			return &BitbucketError{Kind: Failed, Message: "a Bitbucket issue has one kind and one component: add one of each at most"}
		}
		change[field] = value
	}
	var i issueJSON
	if len(remove) > 0 {
		if err := b.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &i); err != nil {
			return err
		}
	}
	for _, l := range remove {
		switch {
		case strings.EqualFold(l, i.Kind):
			if _, set := change["kind"]; !set {
				return &BitbucketError{Kind: Failed, Message: "a Bitbucket issue always has a kind: add another kind in its place"}
			}
		case i.Component != nil && strings.EqualFold(l, i.Component.Name):
			if _, set := change["component"]; !set {
				change["component"] = nil
			}
		}
	}
	if len(change) == 0 {
		return nil
	}
	return b.send(ctx, http.MethodPut, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), change, nil)
}

// SetState closes an issue (resolved) or opens it again, or declines a pull request.
// Bitbucket cannot open a declined pull request again.
func (b *RealBitbucket) SetState(ctx context.Context, repo string, number int, pr, closed bool) error {
	if pr {
		if !closed {
			return &BitbucketError{Kind: Failed, Message: "Bitbucket cannot reopen a declined pull request: open a new one from its branch"}
		}
		return b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/decline", repoPath(repo), number), nil, nil)
	}
	return b.send(ctx, http.MethodPut, fmt.Sprintf("%s/issues/%d", repoPath(repo), number),
		map[string]any{"state": map[bool]string{true: "resolved", false: "open"}[closed]}, nil)
}

// RepoLabels are what an issue's labels can be: the kinds, and the repository's components.
func (b *RealBitbucket) RepoLabels(ctx context.Context, repo string) ([]string, error) {
	components, _, err := all[struct {
		Name string `json:"name"`
	}](ctx, b, repoPath(repo)+"/components", false)
	if err != nil && !noTracker(err) {
		return nil, err
	}
	names := slices.Clone(Kinds)
	for _, c := range components {
		names = append(names, c.Name)
	}
	return names, nil
}

// strategies are Bitbucket's merge strategies as the Work pages name them. Its others
// (fast_forward, squash_fast_forward, rebase_merge) are for its own page.
var strategies = map[string]string{"merge_commit": "merge", "squash": "squash", "rebase_fast_forward": "rebase"}

// strategyOf is a Work page's method as Bitbucket's strategy.
func strategyOf(method string) string {
	for s, m := range strategies {
		if m == method {
			return s
		}
	}
	return ""
}

// MergeMethods are merge, squash and rebase, as the pull request's target branch allows them,
// its default first.
func (b *RealBitbucket) MergeMethods(ctx context.Context, repo string, number int) ([]string, error) {
	var p pullJSON
	if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
		return nil, err
	}
	var branch struct {
		Strategies []string `json:"merge_strategies"`
		Default    string   `json:"default_merge_strategy"`
	}
	if err := b.get(ctx, fmt.Sprintf("%s/refs/branches/%s", repoPath(repo), url.PathEscape(p.Destination.Branch.Name)), false, &branch); err != nil {
		return nil, err
	}
	var methods []string
	for _, s := range branch.Strategies {
		m, ok := strategies[s]
		switch {
		case !ok:
		case s == branch.Default:
			methods = append([]string{m}, methods...)
		default:
			methods = append(methods, m)
		}
	}
	return methods, nil
}

// atHead is a pull request when its head is still the commit sha the person saw.
func (b *RealBitbucket) atHead(ctx context.Context, repo string, number int, sha string) (pullJSON, error) {
	var p pullJSON
	if strings.TrimSpace(sha) == "" {
		return p, &BitbucketError{Kind: Failed, Message: "sha is the head commit the person saw: read the pull request again"}
	}
	if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
		return p, err
	}
	if !sameCommit(p.Source.hash(), sha) {
		return p, &BitbucketError{Kind: Failed, Message: fmt.Sprintf("the pull request has a newer commit (%s) than the person saw: read it again", p.Source.hash())}
	}
	return p, nil
}

// Merge merges a pull request at sha by method (merge, squash or rebase) and deletes its
// branch. Bitbucket's merge takes no commit, so the head is read first.
func (b *RealBitbucket) Merge(ctx context.Context, repo string, number int, sha, method string) error {
	strategy := strategyOf(method)
	if strategy == "" {
		return &BitbucketError{Kind: Failed, Message: "Bitbucket merges by merge, squash or rebase"}
	}
	if _, err := b.atHead(ctx, repo, number, sha); err != nil {
		return err
	}
	return b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/merge", repoPath(repo), number),
		map[string]any{"merge_strategy": strategy, "close_source_branch": true}, nil)
}

// Approve approves a pull request at the head commit sha, and says the pull request's link.
func (b *RealBitbucket) Approve(ctx context.Context, repo string, number int, sha string) (string, error) {
	p, err := b.atHead(ctx, repo, number, sha)
	if err != nil {
		return "", err
	}
	if err := b.send(ctx, http.MethodPost, fmt.Sprintf("%s/pullrequests/%d/approve", repoPath(repo), number), nil, nil); err != nil {
		return "", err
	}
	return p.Links.HTML.Href, nil
}

// MARK: The diff

// diffLines is the most lines of hunks a diff gives, all files together; past it, a file is
// listed with no hunks and the diff says it was cut.
const diffLines = 5000

// DiffLine is one line of a hunk: context, added or removed.
type DiffLine struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Hunk is one @@ block of a file's diff, as #1472's diff component takes it.
type Hunk struct {
	OldStart int        `json:"oldStart"`
	NewStart int        `json:"newStart"`
	Lines    []DiffLine `json:"lines"`
}

var (
	hunkHead = regexp.MustCompile(`^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@`)
	// fileHead is a file's first line in git's diff: diff --git a/<old> b/<new>.
	fileHead = regexp.MustCompile(`^diff --git a/(.*) b/(.*)$`)
)

// diffFile is one file of a pull request's diff.
type diffFile struct {
	path, previous, change string
	additions, deletions   int
	hunks                  []Hunk
	lines                  int
	binary                 bool
}

// parseDiff reads git's unified diff of a pull request (/pullrequests/:n/diff), a file at a
// time, as the forgejo server's does.
func parseDiff(text string) []diffFile {
	var files []diffFile
	var f *diffFile
	for _, line := range strings.Split(text, "\n") {
		if m := fileHead.FindStringSubmatch(line); m != nil {
			files = append(files, diffFile{path: m[2], previous: m[1], change: "modified", hunks: []Hunk{}})
			f = &files[len(files)-1]
			continue
		}
		if f == nil {
			continue
		}
		if m := hunkHead.FindStringSubmatch(line); m != nil {
			oldStart, _ := strconv.Atoi(m[1])
			newStart, _ := strconv.Atoi(m[2])
			f.hunks = append(f.hunks, Hunk{OldStart: oldStart, NewStart: newStart, Lines: []DiffLine{}})
			continue
		}
		if len(f.hunks) == 0 {
			switch {
			case strings.HasPrefix(line, "new file mode"):
				f.change = "added"
			case strings.HasPrefix(line, "deleted file mode"):
				f.change = "removed"
			case strings.HasPrefix(line, "rename from "):
				f.change = "renamed"
			case strings.HasPrefix(line, "Binary files"):
				f.binary = true
			}
			continue
		}
		h := &f.hunks[len(f.hunks)-1]
		switch {
		case strings.HasPrefix(line, "+"):
			h.Lines = append(h.Lines, DiffLine{"added", line[1:]})
			f.additions++
		case strings.HasPrefix(line, "-"):
			h.Lines = append(h.Lines, DiffLine{"removed", line[1:]})
			f.deletions++
		case strings.HasPrefix(line, " "):
			h.Lines = append(h.Lines, DiffLine{"context", line[1:]})
		default:
			// "\ No newline at end of file", or the diff's own last newline.
			continue
		}
		f.lines++
	}
	return files
}

// PRDiff is a pull request's diff at its head now, in the shape of the views' agents/open-diff
// (#1341), which the daemon's forge/diff is.
func (b *RealBitbucket) PRDiff(ctx context.Context, repo string, number int) (map[string]any, error) {
	var p pullJSON
	if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
		return nil, err
	}
	// Bitbucket sends it on to the diff of the two commits, on its own API.
	res, err := b.request(ctx, http.MethodGet, fmt.Sprintf("%s/pullrequests/%d/diff", repoPath(repo), number), nil,
		http.Header{"Accept": {"text/plain"}})
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return nil, &BitbucketError{Kind: Failed, Message: "Bitbucket: " + err.Error()}
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, failure(res, body)
	}
	files := []any{}
	left, cut := diffLines, false
	for _, d := range parseDiff(string(body)) {
		j := map[string]any{"path": d.path, "change": d.change, "additions": d.additions, "deletions": d.deletions}
		if d.change == "renamed" && d.previous != d.path {
			j["previousPath"] = d.previous
		}
		switch {
		case d.binary || len(d.hunks) == 0:
			j["hunks"], j["note"] = []Hunk{}, "No lines to show: a binary file, a rename, or a file mode's change."
		case d.lines > left:
			j["hunks"], j["note"], cut = []Hunk{}, "Not shown: the diff is too long. Open it on Bitbucket.", true
		default:
			j["hunks"] = d.hunks
			left -= d.lines
		}
		files = append(files, j)
	}
	return map[string]any{"repo": repo, "number": number, "url": strings.TrimSuffix(p.Links.HTML.Href, "/") + "/diff", "sha": p.Source.hash(),
		"files": files, "cut": cut}, nil
}
