package gitlabmcp

import (
	"regexp"
	"context"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
)

// The daemon's forge writes (#3130): a person's own clicks on the Work pages, as the signed-in
// person, next to the views' approve and retry (pages.go), which they reuse.

func kindPath(mr bool) string { return map[bool]string{false: "issues", true: "merge_requests"}[mr] }

// Comment adds a note, as Markdown, to an issue or a merge request.
func (g *RealGitLab) Comment(ctx context.Context, project string, number int, mr bool, body string) error {
	var out map[string]any
	return g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/%s/%d/notes", pid(project), kindPath(mr), number),
		map[string]any{"body": body}, &out)
}

// SetLabels adds labels to an issue or a merge request and takes others off it, by name.
func (g *RealGitLab) SetLabels(ctx context.Context, project string, number int, mr bool, add, remove []string) error {
	change := map[string]any{}
	if len(add) > 0 {
		change["add_labels"] = strings.Join(add, ",")
	}
	if len(remove) > 0 {
		change["remove_labels"] = strings.Join(remove, ",")
	}
	if len(change) == 0 {
		return nil
	}
	var out map[string]any
	return g.send(ctx, http.MethodPut, fmt.Sprintf("projects/%s/%s/%d", pid(project), kindPath(mr), number), change, &out)
}

// SetAssignees assigns people to an issue or a merge request and takes others off it, by
// username (#4403). GitLab sets the whole list by user id, so it reads the list there is and each
// new person's id first. A username that GitLab does not know is an error.
func (g *RealGitLab) SetAssignees(ctx context.Context, project string, number int, mr bool, add, remove []string) error {
	path := fmt.Sprintf("projects/%s/%s/%d", pid(project), kindPath(mr), number)
	var item struct {
		Assignees []user `json:"assignees"`
	}
	if err := g.get(ctx, path, false, &item); err != nil {
		return err
	}
	ids := []int{}
	has := func(name string) bool {
		return slices.ContainsFunc(item.Assignees, func(u user) bool { return strings.EqualFold(u.Username, name) })
	}
	for _, u := range item.Assignees {
		if !slices.ContainsFunc(remove, func(name string) bool { return strings.EqualFold(u.Username, name) }) {
			ids = append(ids, u.ID)
		}
	}
	for _, name := range add {
		if has(name) {
			continue
		}
		var found []user
		if err := g.get(ctx, "users?username="+url.QueryEscape(name), false, &found); err != nil {
			return err
		}
		if len(found) == 0 {
			return &GitLabError{Kind: NotFound, Message: "no GitLab user is called " + name}
		}
		ids = append(ids, found[0].ID)
	}
	var out map[string]any
	return g.send(ctx, http.MethodPut, path, map[string]any{"assignee_ids": ids}, &out)
}

// SetState closes an issue or a merge request, or opens it again.
func (g *RealGitLab) SetState(ctx context.Context, project string, number int, mr, closed bool) error {
	var out map[string]any
	return g.send(ctx, http.MethodPut, fmt.Sprintf("projects/%s/%s/%d", pid(project), kindPath(mr), number),
		map[string]any{"state_event": map[bool]string{true: "close", false: "reopen"}[closed]}, &out)
}

// MergeMethods are merge and squash, as the project's squash option allows them, its default
// first. GitLab's own merge method (a merge commit, or fast-forward) is the project's to say.
func (g *RealGitLab) MergeMethods(ctx context.Context, project string) ([]string, error) {
	var p struct {
		Squash string `json:"squash_option"`
	}
	if err := g.get(ctx, "projects/"+pid(project), true, &p); err != nil {
		return nil, err
	}
	switch p.Squash {
	case "never":
		return []string{"merge"}, nil
	case "always":
		return []string{"squash"}, nil
	case "default_on":
		return []string{"squash", "merge"}, nil
	}
	return []string{"merge", "squash"}, nil
}

// Merge merges a merge request at sha, squashed or not, and deletes its source branch; with
// auto, GitLab does that once its pipeline passes. GitLab refuses when the head is another commit.
func (g *RealGitLab) Merge(ctx context.Context, project string, number int, sha string, squash, auto bool) error {
	if strings.TrimSpace(sha) == "" {
		return &GitLabError{Kind: Failed, Message: "sha is needed: the head commit that the page shows"}
	}
	body := map[string]any{"sha": sha, "squash": squash, "should_remove_source_branch": true}
	if auto {
		body["merge_when_pipeline_succeeds"] = true
	}
	var out map[string]any
	return g.send(ctx, http.MethodPut, fmt.Sprintf("projects/%s/merge_requests/%d/merge", pid(project), number), body, &out)
}

// CancelAutoMerge turns off a merge request's merge when its pipeline passes (#4410).
func (g *RealGitLab) CancelAutoMerge(ctx context.Context, project string, number int) error {
	var out map[string]any
	return g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/merge_requests/%d/cancel_merge_when_pipeline_succeeds", pid(project), number), nil, &out)
}

// draftMark is GitLab's mark of a draft at the start of a title: Draft:, [Draft] or (Draft), as
// GitLab's own DRAFT_REGEX finds it, one or more times.
var draftMark = regexp.MustCompile(`(?i)^\s*((\[draft\]|\(draft\)|draft:)\s*)+`)

// MarkReady marks a draft merge request ready (#4410): GitLab's API has no draft field to set,
// so its title loses the draft mark, as GitLab's own Mark as ready does.
func (g *RealGitLab) MarkReady(ctx context.Context, project string, number int) error {
	path := fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), number)
	var m struct {
		Title string `json:"title"`
	}
	if err := g.get(ctx, path, false, &m); err != nil {
		return err
	}
	title := draftMark.ReplaceAllString(m.Title, "")
	if title == m.Title {
		return nil
	}
	var out map[string]any
	return g.send(ctx, http.MethodPut, path, map[string]any{"title": title}, &out)
}

// ProjectLabels are a project's labels, at most 100, with their colours.
func (g *RealGitLab) ProjectLabels(ctx context.Context, project string) ([]string, map[string]string, error) {
	var ls []labelJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/labels?per_page=100", pid(project)), false, &ls); err != nil {
		return nil, nil, err
	}
	names, colors := []string{}, map[string]string{}
	for _, l := range ls {
		names = append(names, l.Name)
		if l.Color != "" {
			colors[l.Name] = strings.ToLower(l.Color)
		}
	}
	return names, colors, nil
}
