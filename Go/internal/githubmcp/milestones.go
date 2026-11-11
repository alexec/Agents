package githubmcp

import (
	"context"
	"fmt"
)

// Milestone is an open milestone as GitHub lists it: its title and its due date
// (YYYY-MM-DD), "" when it has none (#4654).
type Milestone struct{ Title, Due string }

// mostMilestones bounds the milestones one read lists: one page.
const mostMilestones = 100

// Milestones are the repo's open milestones, one page of them.
func (g *RealGitHub) Milestones(ctx context.Context, repo string) ([]Milestone, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	var listed []struct {
		Title string  `json:"title"`
		DueOn *string `json:"due_on"`
	}
	if err := g.get(ctx, fmt.Sprintf("repos/%s/milestones?state=open&per_page=%d", repo, mostMilestones), true, &listed); err != nil {
		return nil, err
	}
	out := make([]Milestone, len(listed))
	for i, m := range listed {
		out[i].Title = m.Title
		// GitHub keeps a due date as its day's first moment in UTC, 2026-11-20T08:00:00Z.
		if m.DueOn != nil && len(*m.DueOn) >= len("2006-01-02") {
			out[i].Due = (*m.DueOn)[:len("2006-01-02")]
		}
	}
	return out, nil
}
