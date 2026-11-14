package githubmcp

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

// pr.blocked's read of GitHub (#5321): one GraphQL query for the open PRs, with what stops
// each one merging. mergeable says a conflict, mergeStateStatus BEHIND says behind (GitHub
// says it only when the base's rule wants the branch up to date), reviewDecision says changes
// requested, the last auto-merge event of its timeline says auto-merge was turned off, and the
// head commit's checks against the base's required checks (its rulesets' and its classic
// protection's) say which required check failed.
const blockedQuery = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
    nodes { number title body headRefName url isDraft headRefOid mergeable mergeStateStatus reviewDecision
      isCrossRepository authorAssociation author { login __typename }
      autoMergeRequest { enabledAt }
      labels(first: 30) { nodes { name } }
      latestReviews(first: 20) { nodes { state url } }
      timelineItems(itemTypes: [AUTO_MERGE_ENABLED_EVENT, AUTO_MERGE_DISABLED_EVENT], last: 1) { nodes { __typename } }
      baseRef { rules(first: 50) { nodes { parameters { ... on RequiredStatusChecksParameters { requiredStatusChecks { context } } } } }
        branchProtectionRule { requiredStatusCheckContexts } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
        ... on CheckRun { name status conclusion detailsUrl }
        ... on StatusContext { context state targetUrl } } } } } } } } } } }`

// blockedNode is one PR of blockedQuery's answer.
type blockedNode struct {
	Number      int    `json:"number"`
	Title       string `json:"title"`
	Body        string `json:"body"`
	HeadRefName string `json:"headRefName"`
	URL         string `json:"url"`
	Draft       bool   `json:"isDraft"`
	HeadSHA     string `json:"headRefOid"`
	Mergeable   string `json:"mergeable"`
	MergeState  string `json:"mergeStateStatus"`
	Decision    string `json:"reviewDecision"`
	CrossRepo   bool   `json:"isCrossRepository"`
	Association string `json:"authorAssociation"`
	Author      *struct {
		Login    string `json:"login"`
		Typename string `json:"__typename"`
	} `json:"author"`
	AutoMerge *struct {
		EnabledAt string `json:"enabledAt"`
	} `json:"autoMergeRequest"`
	Labels struct {
		Nodes []struct {
			Name string `json:"name"`
		} `json:"nodes"`
	} `json:"labels"`
	Reviews struct {
		Nodes []struct {
			State string `json:"state"`
			URL   string `json:"url"`
		} `json:"nodes"`
	} `json:"latestReviews"`
	Timeline struct {
		Nodes []struct {
			Typename string `json:"__typename"`
		} `json:"nodes"`
	} `json:"timelineItems"`
	BaseRef *struct {
		Rules struct {
			Nodes []struct {
				Parameters *struct {
					Checks []struct {
						Context string `json:"context"`
					} `json:"requiredStatusChecks"`
				} `json:"parameters"`
			} `json:"nodes"`
		} `json:"rules"`
		Protection *struct {
			Contexts []string `json:"requiredStatusCheckContexts"`
		} `json:"branchProtectionRule"`
	} `json:"baseRef"`
	Commits struct {
		Nodes []struct {
			Commit struct {
				Rollup *struct {
					Contexts struct {
						Nodes []checkContext `json:"nodes"`
					} `json:"contexts"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"commits"`
}

// checkContext is a check run or a commit status on the head.
type checkContext struct {
	Typename   string `json:"__typename"`
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"detailsUrl"`
	Context    string `json:"context"`
	State      string `json:"state"`
	TargetURL  string `json:"targetUrl"`
}

// outcome is a check's name, its URL, and whether it failed or still runs.
func (c checkContext) outcome() (name, url string, failed, running bool) {
	if c.Typename == "StatusContext" {
		return c.Context, c.TargetURL, c.State == "FAILURE" || c.State == "ERROR", c.State == "PENDING" || c.State == "EXPECTED"
	}
	switch c.Conclusion {
	case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
		failed = true
	}
	return c.Name, c.DetailsURL, failed, c.Status != "COMPLETED"
}

func (n blockedNode) required() []string {
	var out []string
	if n.BaseRef == nil {
		return nil
	}
	for _, r := range n.BaseRef.Rules.Nodes {
		if r.Parameters != nil {
			for _, c := range r.Parameters.Checks {
				out = append(out, c.Context)
			}
		}
	}
	if n.BaseRef.Protection != nil {
		out = append(out, n.BaseRef.Protection.Contexts...)
	}
	return out
}

// blocking is what stops the PR merging until its author acts.
func (n blockedNode) blocking() mcpevents.Blocking {
	b := mcpevents.Blocking{HeadSHA: n.HeadSHA, Conflict: n.Mergeable == "CONFLICTING", Behind: n.MergeState == "BEHIND",
		Unknown: n.Mergeable == "UNKNOWN" || n.MergeState == "UNKNOWN"}
	if n.Decision == "CHANGES_REQUESTED" {
		b.ChangesRequested = true
		for _, r := range n.Reviews.Nodes {
			if r.State == "CHANGES_REQUESTED" {
				b.ReviewURL = r.URL
				break
			}
		}
	}
	if t := n.Timeline.Nodes; n.AutoMerge == nil && len(t) > 0 && t[len(t)-1].Typename == "AutoMergeDisabledEvent" {
		b.AutomergeDisabled = true
	}
	required := n.required()
	if len(required) == 0 || len(n.Commits.Nodes) == 0 || n.Commits.Nodes[0].Commit.Rollup == nil {
		b.ChecksRunning = len(required) > 0
		return b
	}
	// A required check is failed when one by its name failed and none by its name still
	// runs (a rerun); one that has not reported yet still runs.
	type seen struct {
		url             string
		failed, running bool
	}
	checks := map[string]*seen{}
	for _, c := range n.Commits.Nodes[0].Commit.Rollup.Contexts.Nodes {
		name, url, failed, running := c.outcome()
		s := checks[name]
		if s == nil {
			s = &seen{}
			checks[name] = s
		}
		s.running = s.running || running
		if failed && !s.failed {
			s.failed, s.url = true, url
		}
	}
	slices.Sort(required)
	for _, name := range slices.Compact(required) {
		s := checks[name]
		switch {
		case s == nil || s.running:
			b.ChecksRunning = true
		case s.failed:
			b.FailedChecks = append(b.FailedChecks, mcpevents.FailedCheck{Name: name, URL: s.url})
		}
	}
	return b
}

func (g *RealGitHub) BlockedPRs(ctx context.Context, repo string) ([]BlockedPR, error) {
	owner, name, ok := strings.Cut(repo, "/")
	if !ok {
		return nil, &GitHubError{Kind: NotFound, Message: "repo is owner/name"}
	}
	request, _ := json.Marshal(map[string]any{"query": blockedQuery, "variables": map[string]string{"owner": owner, "name": name}})
	body, err := g.shared("graphql blocked "+repo, func() ([]byte, error) {
		return g.do(ctx, http.MethodPost, "graphql", request, false)
	})
	if err != nil {
		return nil, err
	}
	var answer struct {
		Data struct {
			Repository *struct {
				PullRequests struct {
					Nodes []blockedNode `json:"nodes"`
				} `json:"pullRequests"`
			} `json:"repository"`
		} `json:"data"`
		Errors []struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &answer) != nil {
		return nil, &GitHubError{Kind: Failed, Message: "GitHub's answer is not JSON"}
	}
	if len(answer.Errors) > 0 {
		if answer.Errors[0].Type == "NOT_FOUND" {
			return nil, &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
		}
		return nil, &GitHubError{Kind: Failed, Message: "GitHub: " + answer.Errors[0].Message}
	}
	if answer.Data.Repository == nil {
		return nil, &GitHubError{Kind: NotFound, Message: "not found on GitHub"}
	}
	return blockedPRs(answer.Data.Repository.PullRequests.Nodes), nil
}

func blockedPRs(nodes []blockedNode) []BlockedPR {
	var out []BlockedPR
	for _, n := range nodes {
		b := BlockedPR{PR: PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL, Fixes: closingRefs(n.Body)}}
		if n.Author != nil {
			b.PR.Author = n.Author.Login
		}
		if n.Author != nil && !n.CrossRepo {
			b.Trusted = isOwnAuthor(n.Association, n.Author.Login, n.Author.Typename)
		}
		var labels []string
		for _, l := range n.Labels.Nodes {
			labels = append(labels, l.Name)
		}
		b.Skip = mcpevents.SkipsBlocked(n.Draft, labels)
		b.Blocking = n.blocking()
		out = append(out, b)
	}
	return out
}
