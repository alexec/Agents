package forgejomcp

import (
	"context"
	"fmt"
	"net/http"
	"strings"
)

// An epic's plan on Forgejo (#3835, after GitHub's and GitLab's in #3267 and #3271). Forgejo has
// no sub-issues, but it has issue dependencies (/issues/:n/dependencies, the issues that block
// :n), and an epic waits for its children: so an epic's children are the issues it depends on,
// and a child's blockers are the issues the child depends on. Add child makes the epic depend on
// the child; Blocked by makes a child depend on another. Forgejo also keeps an issue with open
// dependencies from being closed, so an epic closes after its children, as the lead closes it.

// planChildrenMost bounds an epic's children, as GitLab's 100.
const planChildrenMost = 2 * perPage

// Ref is an issue or a pull request another names, as a child or a blocker: open says it is
// not closed.
type Ref struct {
	Repo   string
	Number int
	PR     bool
	Open   bool
}

// PlanChild is an issue the epic depends on, with the issues that block it.
type PlanChild struct {
	Item
	BlockedBy []Ref
}

// Plan is an issue (an epic) and its children, in Forgejo's order.
type Plan struct {
	Epic     Item
	Children []PlanChild
}

// dependencyJSON is an issue in a dependencies list: it names its repository, which can be
// another than the one asked about.
type dependencyJSON struct {
	forgeJSON
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
}

// dependencies are the issues that block repo's issue number, at most planChildrenMost.
func (f *RealForgejo) dependencies(ctx context.Context, repo string, number int) ([]dependencyJSON, error) {
	var out []dependencyJSON
	for page := 1; page <= planChildrenMost/perPage; page++ {
		var list []dependencyJSON
		if err := f.get(ctx, query(fmt.Sprintf("%s/issues/%d/dependencies", repoPath(repo), number), page), false, &list); err != nil {
			return nil, err
		}
		out = append(out, list...)
		if len(list) < perPage {
			break
		}
	}
	return out, nil
}

func (j dependencyJSON) repo(asked string) string {
	if j.Repository.FullName != "" {
		return j.Repository.FullName
	}
	return asked
}

// Plan is repo's issue number, the issues it depends on (its children, pull requests left out)
// and each child's own dependencies: a call for the epic, one for its children, and one per
// child.
func (f *RealForgejo) Plan(ctx context.Context, repo string, number int) (Plan, error) {
	var j forgeJSON
	if err := f.get(ctx, fmt.Sprintf("%s/issues/%d", repoPath(repo), number), false, &j); err != nil {
		return Plan{}, err
	}
	if j.PullRequest != nil {
		return Plan{}, &ForgejoError{Kind: NotFound, Message: fmt.Sprintf("%s#%d is a pull request, not an issue", repo, number)}
	}
	p := Plan{Epic: j.item(repo), Children: []PlanChild{}}
	deps, err := f.dependencies(ctx, repo, number)
	if err != nil {
		return Plan{}, err
	}
	for _, d := range deps {
		if d.PullRequest != nil {
			continue
		}
		at := d.repo(repo)
		child := PlanChild{Item: d.item(at), BlockedBy: []Ref{}}
		blockers, err := f.dependencies(ctx, at, d.Number)
		if err != nil {
			return Plan{}, err
		}
		for _, b := range blockers {
			child.BlockedBy = append(child.BlockedBy, Ref{Repo: b.repo(at), Number: b.Number, PR: b.PullRequest != nil, Open: b.State != "closed"})
		}
		p.Children = append(p.Children, child)
	}
	return p, nil
}

// SetBlockedBy makes repo's issue number depend on blockerRepo's issue blockerNumber, or no
// longer depend on it.
func (f *RealForgejo) SetBlockedBy(ctx context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error {
	owner, name, ok := strings.Cut(blockerRepo, "/")
	if !ok {
		return &ForgejoError{Kind: Failed, Message: "Forgejo: " + blockerRepo + " is not owner/repo"}
	}
	method := map[bool]string{true: http.MethodPost, false: http.MethodDelete}[blocked]
	return f.send(ctx, method, fmt.Sprintf("%s/issues/%d/dependencies", repoPath(repo), number),
		map[string]any{"owner": owner, "repo": name, "index": blockerNumber}, nil)
}

// CreateIssue makes an issue in repo with labels, by name, and says its number and link.
// Forgejo makes an issue with labels by id only, so they are added by name after.
func (f *RealForgejo) CreateIssue(ctx context.Context, repo, title string, labels []string) (int, string, error) {
	var j forgeJSON
	if err := f.send(ctx, http.MethodPost, repoPath(repo)+"/issues", map[string]any{"title": title}, &j); err != nil {
		return 0, "", err
	}
	if len(labels) > 0 {
		if err := f.SetLabels(ctx, repo, j.Number, labels, nil); err != nil {
			return j.Number, j.HTMLURL, err
		}
	}
	return j.Number, j.HTMLURL, nil
}
