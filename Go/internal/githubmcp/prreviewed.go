package githubmcp

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// PRReview is a person's review of a pull request (#3860): Approve, Request changes, or a
// comment with words. Once agents post as their own bot, the person approves a UI enhancement
// with a real review, and pr.reviewed wakes the lane that waits for it.
type PRReview struct {
	ID      int
	PR      PR
	Author  string
	State   string // approved, changes_requested or commented
	Body    string
	URL     string
	Commit  string
	At      string
	Trusted bool // the repo's owner, a member or a collaborator, and not a bot (#728)
}

func (r PRReview) data() map[string]any {
	return map[string]any{"pr": r.PR.json(), "reviewedAt": r.At,
		"review": map[string]any{"author": r.Author, "state": r.State, "body": r.Body, "url": r.URL, "commit": r.Commit}}
}

// reviewState is how pr.reviewed names a review's state, or "" for one it never raises: a
// pending review is not posted yet, a dismissed one no longer counts, and a comment with no
// words is only the wrapper of a reply on a line, which review.comment and the thread carry.
func reviewState(state, body string) string {
	switch strings.ToUpper(state) {
	case "APPROVED":
		return "approved"
	case "CHANGES_REQUESTED":
		return "changes_requested"
	case "COMMENTED":
		if strings.TrimSpace(body) != "" {
			return "commented"
		}
	}
	return ""
}

// prReviewsQuery is the open PRs with their last reviews: one call for pr.reviewed, whatever
// the number of PRs.
const prReviewsQuery = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
    number title body headRefName url author { login }
    reviews(last: 20) { nodes { author { login __typename } authorAssociation body state url databaseId submittedAt commit { oid } } } } } } }`

// PRReviews is pr.reviewed's read: the reviews of the open PRs submitted at or after since,
// only PR number pr's when it is not 0.
func (g *RealGitHub) PRReviews(ctx context.Context, repo, since string, pr int) ([]PRReview, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return nil, err
	}
	request, _ := json.Marshal(map[string]any{"query": prReviewsQuery, "variables": map[string]string{"owner": owner, "name": name}})
	body, err := g.shared("graphql reviews "+repo, func() ([]byte, error) {
		return g.do(ctx, http.MethodPost, "graphql", request, false)
	})
	if err != nil {
		return nil, err
	}
	var answer struct {
		Data struct {
			Repository *struct {
				PullRequests struct {
					Nodes []struct {
						Number      int       `json:"number"`
						Title       string    `json:"title"`
						Body        string    `json:"body"`
						HeadRefName string    `json:"headRefName"`
						URL         string    `json:"url"`
						Author      *gqlActor `json:"author"`
						Reviews     struct {
							Nodes []struct {
								Author      *gqlActor `json:"author"`
								Association string    `json:"authorAssociation"`
								Body        string    `json:"body"`
								State       string    `json:"state"`
								URL         string    `json:"url"`
								DatabaseID  int       `json:"databaseId"`
								SubmittedAt string    `json:"submittedAt"`
								Commit      *struct {
									Oid string `json:"oid"`
								} `json:"commit"`
							} `json:"nodes"`
						} `json:"reviews"`
					} `json:"nodes"`
				} `json:"pullRequests"`
			} `json:"repository"`
		} `json:"data"`
		Errors []gqlError `json:"errors"`
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
	var out []PRReview
	for _, n := range answer.Data.Repository.PullRequests.Nodes {
		if pr != 0 && n.Number != pr {
			continue
		}
		p := PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL, Fixes: closingRefs(n.Body), Author: n.Author.login()}
		for _, v := range n.Reviews.Nodes {
			state := reviewState(v.State, v.Body)
			if state == "" || v.SubmittedAt == "" || mcpevents.Before(v.SubmittedAt, since) {
				continue
			}
			r := PRReview{ID: v.DatabaseID, PR: p, Author: v.Author.login(), State: state, Body: clip(v.Body), URL: v.URL, At: v.SubmittedAt}
			if v.Commit != nil {
				r.Commit = v.Commit.Oid
			}
			if v.Author != nil {
				r.Trusted = isTrusted(v.Association, v.Author.Login, v.Author.Typename)
			}
			out = append(out, r)
		}
	}
	return out, nil
}
