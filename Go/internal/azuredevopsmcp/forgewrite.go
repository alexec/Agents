package azuredevopsmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

// The daemon's forge writes (#3803, after Bitbucket's in #3786): a person's own clicks on the
// Work pages, as the token's owner. A pull request's tags are its labels.

// Comment adds a comment, as Markdown, to a pull request in a thread of its own, and says its link.
func (f *RealAzureDevOps) Comment(ctx context.Context, repo string, number int, body string) (string, error) {
	var t threadJSON
	if err := f.send(ctx, http.MethodPost, api(fmt.Sprintf("%s/pullRequests/%d/threads", repoPath(repo), number), nil),
		map[string]any{"status": "active", "comments": []any{map[string]any{"parentCommentId": 0, "content": body, "commentType": "text"}}},
		&t); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, number), t.ID), nil
}

// SetLabels adds tags to a pull request and takes others off.
func (f *RealAzureDevOps) SetLabels(ctx context.Context, repo string, number int, add, remove []string) error {
	path := fmt.Sprintf("%s/pullRequests/%d/labels", repoPath(repo), number)
	for _, l := range add {
		if err := f.send(ctx, http.MethodPost, api(path, nil), map[string]any{"name": l}, nil); err != nil {
			return err
		}
	}
	for _, l := range remove {
		if err := f.send(ctx, http.MethodDelete, api(path+"/"+url.PathEscape(l), nil), nil, nil); err != nil && !IsNotFound(err) {
			return err
		}
	}
	return nil
}

// RepoLabels are the tags a pull request can be given: Azure DevOps has no list of a
// repository's, so they are the tags of its newest pull requests, of every state.
func (f *RealAzureDevOps) RepoLabels(ctx context.Context, repo string) ([]string, error) {
	var list struct {
		Value []pullJSON `json:"value"`
	}
	q := url.Values{"searchCriteria.status": {"all"}, "$top": {strconv.Itoa(perPage)}}
	if err := f.get(ctx, api(repoPath(repo)+"/pullrequests", q), false, &list); err != nil {
		return nil, err
	}
	names := []string{}
	for _, p := range list.Value {
		for _, l := range p.labels() {
			if !slices.ContainsFunc(names, func(n string) bool { return strings.EqualFold(n, l) }) {
				names = append(names, l)
			}
		}
	}
	slices.SortFunc(names, func(a, b string) int { return strings.Compare(strings.ToLower(a), strings.ToLower(b)) })
	return names, nil
}

// SetState abandons a pull request, or makes an abandoned one active again.
func (f *RealAzureDevOps) SetState(ctx context.Context, repo string, number int, closed bool) error {
	return f.send(ctx, http.MethodPatch, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil),
		map[string]any{"status": map[bool]string{true: "abandoned", false: "active"}[closed]}, nil)
}

// strategies are Azure DevOps's merge strategies as the Work pages name them, in its order.
// Its rebaseMerge (semi-linear) is for its own page.
var strategies = []struct{ method, strategy, setting string }{
	{"merge", "noFastForward", "allowNoFastForward"},
	{"squash", "squash", "allowSquash"},
	{"rebase", "rebase", "allowRebase"},
}

// mergeTypesPolicy is the branch policy "Limit merge types".
const mergeTypesPolicy = "fa4e907d-c16b-4a4c-9dfa-4916e5d9b9b1"

// MergeMethods are merge, squash and rebase, as the pull request's target branch's policy
// allows them; every one with no policy.
func (f *RealAzureDevOps) MergeMethods(ctx context.Context, repo string, number int) ([]string, error) {
	var p pullJSON
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p); err != nil {
		return nil, err
	}
	r, err := f.repository(ctx, repo)
	if err != nil {
		return nil, err
	}
	var list struct {
		Value []struct {
			IsEnabled bool            `json:"isEnabled"`
			IsDeleted bool            `json:"isDeleted"`
			Settings  map[string]bool `json:"settings"`
		} `json:"value"`
	}
	q := url.Values{"repositoryId": {r.ID}, "refName": {p.TargetRefName}, "policyType": {mergeTypesPolicy}}
	if err := f.get(ctx, api(projectPath(repo)+"git/policy/configurations", q), false, &list); err != nil {
		return nil, err
	}
	allowed := map[string]bool{}
	limited := false
	for _, c := range list.Value {
		if !c.IsEnabled || c.IsDeleted {
			continue
		}
		limited = true
		for k, v := range c.Settings {
			allowed[k] = allowed[k] || v
		}
	}
	var methods []string
	for _, s := range strategies {
		if !limited || allowed[s.setting] {
			methods = append(methods, s.method)
		}
	}
	return methods, nil
}

// atHead is a pull request when its head is still the commit sha the person saw.
func (f *RealAzureDevOps) atHead(ctx context.Context, repo string, number int, sha string) (pullJSON, error) {
	var p pullJSON
	sha, err := headSha(sha)
	if err != nil {
		return p, &AzureDevOpsError{Kind: Failed, Message: err.Error()}
	}
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p); err != nil {
		return p, err
	}
	if !strings.EqualFold(p.head(), sha) {
		return p, &AzureDevOpsError{Kind: Failed, Message: fmt.Sprintf("the pull request has a newer commit (%s) than the person saw: read it again", p.head())}
	}
	return p, nil
}

// Merge completes a pull request at sha by method (merge, squash or rebase) and deletes its
// branch; with auto, it completes on its own once its policies pass.
func (f *RealAzureDevOps) Merge(ctx context.Context, repo string, number int, sha, method string, auto bool) error {
	strategy := ""
	for _, s := range strategies {
		if s.method == method {
			strategy = s.strategy
		}
	}
	if strategy == "" {
		return &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps merges by merge, squash or rebase"}
	}
	p, err := f.atHead(ctx, repo, number, sha)
	if err != nil {
		return err
	}
	body := map[string]any{"completionOptions": map[string]any{"mergeStrategy": strategy, "deleteSourceBranch": true}}
	if auto {
		id, err := f.me(ctx, repo)
		if err != nil {
			return err
		}
		body["autoCompleteSetBy"] = map[string]any{"id": id}
	} else {
		// Azure DevOps refuses when the head is not this commit.
		body["status"] = "completed"
		body["lastMergeSourceCommit"] = map[string]any{"commitId": p.head()}
	}
	return f.send(ctx, http.MethodPatch, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), body, nil)
}

// Approve votes approved on a pull request at the head commit sha, and says its link.
func (f *RealAzureDevOps) Approve(ctx context.Context, repo string, number int, sha string) (string, error) {
	if _, err := f.atHead(ctx, repo, number, sha); err != nil {
		return "", err
	}
	id, err := f.me(ctx, repo)
	if err != nil {
		return "", err
	}
	if err := f.send(ctx, http.MethodPut, api(fmt.Sprintf("%s/pullrequests/%d/reviewers/%s", repoPath(repo), number, url.PathEscape(id)), nil),
		map[string]any{"vote": 10}, nil); err != nil {
		return "", err
	}
	return f.prURL(repo, number), nil
}

// RetryBuild runs a build's failed jobs again, and says the build's page.
func (f *RealAzureDevOps) RetryBuild(ctx context.Context, repo string, build int) (string, error) {
	var b buildJSON
	if err := f.send(ctx, http.MethodPatch, api(fmt.Sprintf("%sbuild/builds/%d", projectPath(repo), build), url.Values{"retry": {"true"}}),
		map[string]any{}, &b); err != nil {
		return "", err
	}
	return b.Links.Web.Href, nil
}

// FailedLog is the end of a build's failed steps' logs, each with its job and its errors.
func (f *RealAzureDevOps) FailedLog(ctx context.Context, repo string, build int) (string, error) {
	out, err := f.buildLog(ctx, repo, build)
	if err != nil {
		return "", err
	}
	steps, _ := out["failedSteps"].([]any)
	if len(steps) == 0 {
		return fmt.Sprintf("Build %d has no failed step.", build), nil
	}
	var parts []string
	for _, s := range steps {
		step, _ := s.(map[string]any)
		head := fmt.Sprintf("%v", step["name"])
		if job, _ := step["job"].(string); job != "" {
			head = job + ": " + head
		}
		lines := []string{head}
		if errs, _ := step["errors"].([]string); len(errs) > 0 {
			lines = append(lines, errs...)
		}
		if log, _ := step["log"].(string); log != "" {
			lines = append(lines, log)
		}
		parts = append(parts, strings.Join(lines, "\n"))
	}
	return strings.Join(parts, "\n\n"), nil
}

// MARK: The diff

// diffLines is the most lines of hunks a diff gives, all files together; past it, a file is
// listed with no hunks and the diff says it was cut.
const diffLines = 5000

// diffFiles is the most files whose lines a diff reads; past it, a file is listed with no hunks.
const diffFiles = 100

// context is the lines of context a hunk has around a change.
const contextLines = 3

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

// lineBlock is one block of Azure DevOps's file diff: a range of the old file's lines and of
// the new file's, unchanged, added, deleted or edited.
type lineBlock struct {
	ChangeType    blockChange `json:"changeType"`
	OriginalStart int         `json:"originalLineNumberStart"`
	OriginalCount int         `json:"originalLinesCount"`
	ModifiedStart int         `json:"modifiedLineNumberStart"`
	ModifiedCount int         `json:"modifiedLinesCount"`
}

// blockChange is a block's change: none, add, delete or edit, which Azure DevOps writes as a
// word or as its number (0 to 3).
type blockChange string

func (c *blockChange) UnmarshalJSON(b []byte) error {
	var n int
	if json.Unmarshal(b, &n) == nil {
		*c = blockChange([]string{"none", "add", "delete", "edit"}[max(0, min(n, 3))])
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	*c = blockChange(strings.ToLower(s))
	return nil
}

// hunksOf are the hunks of a file's blocks, with was and now the old and the new file's lines: each change with
// contextLines around it, changes that close together in one hunk. A block that changes
// none of one side's lines says where it is by the other side's.
func hunksOf(blocks []lineBlock, was, now []string) ([]Hunk, int, int) {
	line := func(lines []string, n int) string {
		if n >= 1 && n <= len(lines) {
			return lines[n-1]
		}
		return ""
	}
	var hunks []Hunk
	var h *Hunk
	additions, deletions := 0, 0
	delta := 0 // an old line's number less its new line's, between blocks
	nextNew := 1
	for _, b := range blocks {
		if b.ChangeType == "none" || (b.OriginalCount == 0 && b.ModifiedCount == 0) {
			continue
		}
		newStart := b.ModifiedStart
		if b.ModifiedCount == 0 {
			newStart = b.OriginalStart - delta
		}
		oldStart := newStart + delta
		if b.OriginalCount > 0 {
			oldStart = b.OriginalStart
		}
		if h != nil && newStart-nextNew > 2*contextLines {
			for n := nextNew; n < nextNew+contextLines && n <= len(now); n++ {
				h.Lines = append(h.Lines, DiffLine{"context", line(now, n)})
			}
			h = nil
		}
		if h == nil {
			from := max(1, newStart-contextLines)
			hunks = append(hunks, Hunk{OldStart: from + (oldStart - newStart), NewStart: from, Lines: []DiffLine{}})
			h = &hunks[len(hunks)-1]
			nextNew = from
		}
		for n := nextNew; n < newStart; n++ {
			h.Lines = append(h.Lines, DiffLine{"context", line(now, n)})
		}
		for n := oldStart; n < oldStart+b.OriginalCount; n++ {
			h.Lines = append(h.Lines, DiffLine{"removed", line(was, n)})
		}
		for n := newStart; n < newStart+b.ModifiedCount; n++ {
			h.Lines = append(h.Lines, DiffLine{"added", line(now, n)})
		}
		deletions += b.OriginalCount
		additions += b.ModifiedCount
		nextNew = newStart + b.ModifiedCount
		delta = oldStart + b.OriginalCount - nextNew
	}
	if h != nil {
		for n := nextNew; n < nextNew+contextLines && n <= len(now); n++ {
			h.Lines = append(h.Lines, DiffLine{"context", line(now, n)})
		}
	}
	return hunks, additions, deletions
}

// changeOf is a change entry's change in the diff's words: added, removed, renamed or modified.
func changeOf(c changeJSON) string {
	kinds := strings.Split(strings.ReplaceAll(c.ChangeType, " ", ""), ",")
	switch {
	case slices.Contains(kinds, "add"):
		return "added"
	case slices.Contains(kinds, "delete"):
		return "removed"
	case slices.Contains(kinds, "rename"):
		return "renamed"
	}
	return "modified"
}

// content is a file's lines at a commit; binary says it is not text.
func (f *RealAzureDevOps) content(ctx context.Context, repo, path, commit string) (lines []string, binary bool, err error) {
	q := url.Values{"path": {path}, "versionDescriptor.version": {commit}, "versionDescriptor.versionType": {"commit"},
		"includeContent": {"true"}}
	var item struct {
		Content         string `json:"content"`
		ContentMetadata struct {
			IsBinary bool `json:"isBinary"`
		} `json:"contentMetadata"`
	}
	if err := f.get(ctx, api(repoPath(repo)+"/items", q), false, &item); err != nil {
		return nil, false, err
	}
	if item.ContentMetadata.IsBinary {
		return nil, true, nil
	}
	text := strings.TrimSuffix(strings.ReplaceAll(item.Content, "\r\n", "\n"), "\n")
	if text == "" {
		return []string{}, false, nil
	}
	return strings.Split(text, "\n"), false, nil
}

// PRDiff is a pull request's diff at its newest push, against the merge base with its target,
// in the shape of the views' agents/open-diff (#1341), which the daemon's forge/diff is. Azure
// DevOps says each file's changed ranges of lines (its file diffs), and the lines are read from
// the two commits.
func (f *RealAzureDevOps) PRDiff(ctx context.Context, repo string, number int) (map[string]any, error) {
	last, err := f.newestIteration(ctx, repo, number)
	if err != nil {
		return nil, err
	}
	if last.ID == 0 || last.SourceRefCommit == nil {
		return nil, &AzureDevOpsError{Kind: Failed, Message: "Azure DevOps has no push of this pull request yet"}
	}
	head := last.SourceRefCommit.CommitID
	base := ""
	if last.CommonRefCommit != nil {
		base = last.CommonRefCommit.CommitID
	} else if last.TargetRefCommit != nil {
		base = last.TargetRefCommit.CommitID
	}
	changes, err := f.changes(ctx, repo, number, last.ID)
	if err != nil {
		return nil, err
	}
	// The ranges of the files whose lines are shown, in one call.
	type fileDiff struct {
		Path   string      `json:"path"`
		Blocks []lineBlock `json:"lineDiffBlocks"`
	}
	ranges := map[string][]lineBlock{}
	var params []any
	for _, c := range changes[:min(diffFiles, len(changes))] {
		if change := changeOf(c); change == "modified" || change == "renamed" {
			p := map[string]any{"path": c.Item.Path}
			if c.OriginalPath != "" {
				p["originalPath"] = c.OriginalPath
			}
			params = append(params, p)
		}
	}
	if len(params) > 0 && base != "" {
		var diffs []fileDiff
		if err := f.send(ctx, http.MethodPost, api(repoPath(repo)+"/filediffs", nil),
			map[string]any{"baseVersionCommit": base, "targetVersionCommit": head, "fileDiffParams": params}, &diffs); err != nil {
			return nil, err
		}
		for _, d := range diffs {
			ranges[d.Path] = d.Blocks
		}
	}
	files := []any{}
	left, cut := diffLines, false
	for n, c := range changes {
		path := strings.TrimPrefix(c.Item.Path, "/")
		change := changeOf(c)
		j := map[string]any{"path": path, "change": change, "additions": 0, "deletions": 0, "hunks": []Hunk{}}
		if change == "renamed" && c.OriginalPath != "" {
			j["previousPath"] = strings.TrimPrefix(c.OriginalPath, "/")
		}
		if n >= diffFiles {
			j["note"], cut = "Not shown: the pull request changes too many files. Open it on Azure DevOps.", true
			files = append(files, j)
			continue
		}
		var was, now []string
		binary := false
		if change != "added" && base != "" {
			from := c.Item.Path
			if c.OriginalPath != "" {
				from = c.OriginalPath
			}
			if was, binary, err = f.content(ctx, repo, from, base); err != nil {
				return nil, err
			}
		}
		if change != "removed" && !binary {
			if now, binary, err = f.content(ctx, repo, c.Item.Path, head); err != nil {
				return nil, err
			}
		}
		blocks := ranges[c.Item.Path]
		switch change {
		case "added":
			blocks = []lineBlock{{ChangeType: "add", ModifiedStart: 1, ModifiedCount: len(now)}}
		case "removed":
			blocks = []lineBlock{{ChangeType: "delete", OriginalStart: 1, OriginalCount: len(was)}}
		}
		hunks, additions, deletions := hunksOf(blocks, was, now)
		j["additions"], j["deletions"] = additions, deletions
		lines := 0
		for _, h := range hunks {
			lines += len(h.Lines)
		}
		switch {
		case binary || len(hunks) == 0:
			j["note"] = "No lines to show: a binary file, a rename, or a file mode's change."
		case lines > left:
			j["note"], cut = "Not shown: the diff is too long. Open it on Azure DevOps.", true
		default:
			j["hunks"] = hunks
			left -= lines
		}
		files = append(files, j)
	}
	return map[string]any{"repo": repo, "number": number, "url": f.prURL(repo, number) + "?_a=files", "sha": head,
		"files": files, "cut": cut}, nil
}
