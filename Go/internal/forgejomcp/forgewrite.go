package forgejomcp

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The daemon's forge writes (#3753, after GitLab's in #3130): a person's own clicks on the Work
// pages, as the signed-in person. Issues and pull requests share Forgejo's issue API, so a
// comment, a label and a close are the same call for both.

// Comment adds a comment, as Markdown, to an issue or a pull request, and says its link.
func (f *RealForgejo) Comment(ctx context.Context, repo string, number int, body string) (string, error) {
	var c commentJSON
	if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/issues/%d/comments", repoPath(repo), number),
		map[string]any{"body": body}, &c); err != nil {
		return "", err
	}
	return c.HTMLURL, nil
}

// SetLabels adds labels to an issue or a pull request, by name, and takes others off it: Forgejo
// takes a label off only by its id, which the item's own labels say.
func (f *RealForgejo) SetLabels(ctx context.Context, repo string, number int, add, remove []string) error {
	path := fmt.Sprintf("%s/issues/%d/labels", repoPath(repo), number)
	if len(add) > 0 {
		if err := f.send(ctx, http.MethodPost, path, map[string]any{"labels": add}, nil); err != nil {
			return err
		}
	}
	if len(remove) == 0 {
		return nil
	}
	var has []labelJSON
	if err := f.get(ctx, path, false, &has); err != nil {
		return err
	}
	for _, name := range remove {
		for _, l := range has {
			if strings.EqualFold(l.Name, name) {
				if err := f.send(ctx, http.MethodDelete, fmt.Sprintf("%s/%d", path, l.ID), nil, nil); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// SetAssignees assigns people to an issue or a pull request and takes others off it, by login
// (#4403). Forgejo sets the whole list, so it reads the list there is first.
func (f *RealForgejo) SetAssignees(ctx context.Context, repo string, number int, add, remove []string) error {
	path := fmt.Sprintf("%s/issues/%d", repoPath(repo), number)
	var item struct {
		Assignees []user `json:"assignees"`
	}
	if err := f.get(ctx, path, false, &item); err != nil {
		return err
	}
	logins := []string{}
	for _, u := range item.Assignees {
		if !slices.ContainsFunc(remove, func(l string) bool { return strings.EqualFold(u.Login, l) }) {
			logins = append(logins, u.Login)
		}
	}
	for _, l := range add {
		if !slices.ContainsFunc(logins, func(o string) bool { return strings.EqualFold(o, l) }) {
			logins = append(logins, l)
		}
	}
	return f.send(ctx, http.MethodPatch, path, map[string]any{"assignees": logins}, nil)
}

// SetState closes an issue or a pull request, or opens it again.
func (f *RealForgejo) SetState(ctx context.Context, repo string, number int, closed bool) error {
	return f.send(ctx, http.MethodPatch, fmt.Sprintf("%s/issues/%d", repoPath(repo), number),
		map[string]any{"state": map[bool]string{true: "closed", false: "open"}[closed]}, nil)
}

// RepoLabels are a repository's labels, at most 500, with their colours.
func (f *RealForgejo) RepoLabels(ctx context.Context, repo string) ([]string, map[string]string, error) {
	ls, _, err := all[labelJSON](ctx, f, repoPath(repo)+"/labels")
	if err != nil {
		return nil, nil, err
	}
	names, colors := []string{}, map[string]string{}
	for _, l := range ls {
		names = append(names, l.Name)
		if l.Color != "" {
			colors[l.Name] = "#" + strings.ToLower(strings.TrimPrefix(l.Color, "#"))
		}
	}
	return names, colors, nil
}

// MergeMethods are merge, squash and rebase, as the repository allows them, its default first.
// Forgejo's other styles (a rebase with a merge commit, fast-forward only) are for its own page.
func (f *RealForgejo) MergeMethods(ctx context.Context, repo string) ([]string, error) {
	var r struct {
		Merge   bool   `json:"allow_merge_commits"`
		Squash  bool   `json:"allow_squash_merge"`
		Rebase  bool   `json:"allow_rebase"`
		Default string `json:"default_merge_style"`
	}
	if err := f.get(ctx, repoPath(repo), true, &r); err != nil {
		return nil, err
	}
	var methods []string
	for _, m := range []struct {
		name    string
		allowed bool
	}{{"merge", r.Merge}, {"squash", r.Squash}, {"rebase", r.Rebase}} {
		if !m.allowed {
			continue
		}
		if m.name == r.Default {
			methods = append([]string{m.name}, methods...)
		} else {
			methods = append(methods, m.name)
		}
	}
	return methods, nil
}

// Merge merges a pull request at sha by method (merge, squash or rebase) and deletes its
// branch; with auto, Forgejo does that once its checks succeed. Forgejo refuses when the head
// is another commit.
func (f *RealForgejo) Merge(ctx context.Context, repo string, number int, sha, method string, auto bool) error {
	sha, err := headSha(sha)
	if err != nil {
		return err
	}
	body := map[string]any{"Do": method, "head_commit_id": sha, "delete_branch_after_merge": true, "merge_when_checks_succeed": auto}
	if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/pulls/%d/merge", repoPath(repo), number), body, nil); err != nil {
		var fe *ForgejoError
		if errors.As(err, &fe) && strings.Contains(strings.ToLower(fe.Message), "head") {
			return fmt.Errorf("the pull request has a newer commit than the person saw: read it again (%w)", err)
		}
		return err
	}
	return nil
}

// Approve approves a pull request at the head commit sha, and says the review's link.
func (f *RealForgejo) Approve(ctx context.Context, repo string, number int, sha string) (string, error) {
	sha, err := headSha(sha)
	if err != nil {
		return "", err
	}
	var r reviewJSON
	if err := f.send(ctx, http.MethodPost, fmt.Sprintf("%s/pulls/%d/reviews", repoPath(repo), number),
		map[string]any{"event": "APPROVED", "commit_id": sha}, &r); err != nil {
		return "", err
	}
	return r.HTMLURL, nil
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

// parseDiff reads git's unified diff of a pull request (/pulls/:n.diff), a file at a time.
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
func (f *RealForgejo) PRDiff(ctx context.Context, repo string, number int) (map[string]any, error) {
	var p pullJSON
	if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), number), false, &p); err != nil {
		return nil, err
	}
	body, err := f.do(ctx, http.MethodGet, fmt.Sprintf("%s/pulls/%d.diff", repoPath(repo), number), nil)
	if err != nil {
		return nil, err
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
			j["hunks"], j["note"], cut = []Hunk{}, "Not shown: the diff is too long. Open it on Forgejo.", true
		default:
			j["hunks"] = d.hunks
			left -= d.lines
		}
		files = append(files, j)
	}
	return map[string]any{"repo": repo, "number": number, "url": p.HTMLURL + "/files", "sha": p.Head.SHA, "files": files, "cut": cut}, nil
}
