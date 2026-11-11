package githubmcp

import (
	"context"
	"strings"
)

// The Timeline's read (#4172): a repo's epics, open and closed since a time, each with its
// sub-issues and their dates, and the repo's newest releases, in as few queries as there are
// pages of epics. The daemon puts the epics of a project's repos on one time axis and forecasts
// the open ones (lineage/forecast.go).

// TimelineChild is an epic's sub-issue with its dates (the Item's CreatedAt and ClosedAt),
// StateReason (completed, not_planned or ""), and when each pull request that closes it opened.
type TimelineChild struct {
	Item
	StateReason string
	PROpenedAt  []string
}

// TimelineEpic is an epic with its dates and its sub-issues (at most 100), in GitHub's order.
type TimelineEpic struct {
	Item
	StateReason string
	Children    []TimelineChild
}

// Release is a published release: its tag, when, and its page.
type Release struct {
	Tag, PublishedAt, URL string
}

// Timeline is a repo's epics and its newest releases.
type Timeline struct {
	Epics    []TimelineEpic
	Releases []Release
}

// timelinePages bounds each of the two lists of epics, of timelinePage each.
const (
	timelinePages = 10
	timelinePage  = 10
	// timelineReleases is how many of the newest releases a read gives.
	timelineReleases = 50
)

const timelineQuery = `query($owner: String!, $name: String!, $states: [IssueState!], $since: DateTime, $first: Int!, $after: String, $releases: Int!) {
  repository(owner: $owner, name: $name) {
    issues(labels: ["epic"], states: $states, filterBy: {since: $since}, first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { issueState: state ` + itemFields + ` ` + issueFields + `
        subIssues(first: 100) { nodes { issueState: state ` + itemFields + ` ` + issueFields + `
          closedByPullRequestsReferences(first: 5, includeClosedPrs: true) { nodes { createdAt } } } } } }
    releases(first: $releases, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName publishedAt url isDraft } } } }`

// Timeline is repo's open epics, and those closed since since (RFC 3339), with their
// sub-issues, and its newest releases (drafts left out).
func (g *RealGitHub) Timeline(ctx context.Context, repo, since string) (Timeline, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return Timeline{}, err
	}
	out := Timeline{Releases: []Release{}, Epics: []TimelineEpic{}}
	seen := map[int]bool{}
	for n, states := range [][]string{{"OPEN"}, {"CLOSED"}} {
		after := ""
		for range timelinePages {
			// The releases come with the first page; the other pages ask for one, the fewest GraphQL takes.
			withReleases := n == 0 && after == ""
			vars := map[string]any{"owner": owner, "name": name, "states": states, "first": timelinePage, "releases": 1}
			if n == 1 {
				vars["since"] = since
			}
			if after != "" {
				vars["after"] = after
			}
			if withReleases {
				vars["releases"] = timelineReleases
			}
			var data struct {
				Repository *struct {
					Issues struct {
						PageInfo struct {
							HasNextPage bool   `json:"hasNextPage"`
							EndCursor   string `json:"endCursor"`
						} `json:"pageInfo"`
						Nodes []struct {
							gqlItem
							SubIssues struct {
								Nodes []struct {
									gqlItem
									ClosedBy struct {
										Nodes []struct {
											CreatedAt string `json:"createdAt"`
										} `json:"nodes"`
									} `json:"closedByPullRequestsReferences"`
								} `json:"nodes"`
							} `json:"subIssues"`
						} `json:"nodes"`
					} `json:"issues"`
					Releases struct {
						Nodes []struct {
							TagName     string `json:"tagName"`
							PublishedAt string `json:"publishedAt"`
							URL         string `json:"url"`
							IsDraft     bool   `json:"isDraft"`
						} `json:"nodes"`
					} `json:"releases"`
				} `json:"repository"`
			}
			if err := g.graphql(ctx, timelineQuery, vars, &data); err != nil {
				return Timeline{}, err
			}
			if data.Repository == nil {
				return Timeline{}, &GitHubError{Kind: NotFound, Message: "no repository " + repo}
			}
			if withReleases {
				for _, r := range data.Repository.Releases.Nodes {
					if !r.IsDraft && r.TagName != "" && r.PublishedAt != "" {
						out.Releases = append(out.Releases, Release{Tag: r.TagName, PublishedAt: r.PublishedAt, URL: r.URL})
					}
				}
			}
			for _, e := range data.Repository.Issues.Nodes {
				if e.Number < 1 || seen[e.Number] {
					continue
				}
				seen[e.Number] = true
				epic := TimelineEpic{Item: e.item(), StateReason: strings.ToLower(e.StateReason),
					Children: []TimelineChild{}}
				if epic.Repo == "" {
					epic.Repo = repo
				}
				for _, c := range e.SubIssues.Nodes {
					if c.Number < 1 || c.Repository.NameWithOwner == "" {
						continue
					}
					child := TimelineChild{Item: c.item(), StateReason: strings.ToLower(c.StateReason)}
					for _, pr := range c.ClosedBy.Nodes {
						if pr.CreatedAt != "" {
							child.PROpenedAt = append(child.PROpenedAt, pr.CreatedAt)
						}
					}
					epic.Children = append(epic.Children, child)
				}
				out.Epics = append(out.Epics, epic)
			}
			page := data.Repository.Issues.PageInfo
			if !page.HasNextPage || page.EndCursor == "" {
				break
			}
			after = page.EndCursor
		}
	}
	return out, nil
}
