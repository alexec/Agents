package githubmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// CodeRabbit (#1344) through GitHub only: it has no API to start a review or answer a
// comment (Enterprise only, and metrics), and no MCP server. It is known by its GitHub App's
// slug, never by a name a person can take: GitHub gives its words as the app (REST's
// performed_via_github_app), or as the app's bot account, `coderabbitai[bot]` in REST and the
// Bot `coderabbitai` in GraphQL. The tools post its commands as the person; its replies come
// back as review comments and events.

// codeRabbitApp is CodeRabbit's GitHub App slug, and the handle its commands mention.
const codeRabbitApp = "coderabbitai"

// codeRabbitStatus is the commit status it sets: pending while it reviews, then success.
const codeRabbitStatus = "CodeRabbit"

// codeRabbitSummary starts the one comment it keeps on a PR, edited after each review.
const codeRabbitSummary = "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->"

// isCodeRabbitREST says whether REST's author of something is CodeRabbit: its app, or its bot.
func isCodeRabbitREST(u user, appSlug string) bool {
	return appSlug == codeRabbitApp || (u.Type == "Bot" && strings.EqualFold(u.Login, codeRabbitApp+"[bot]"))
}

// isCodeRabbit says whether GraphQL's author is CodeRabbit's bot.
func (a *gqlActor) isCodeRabbit() bool {
	return a.isBot() && strings.EqualFold(a.Login, codeRabbitApp)
}

// app is the app an author writes as, by its name, or "".
func (a *gqlActor) app() string {
	if a.isCodeRabbit() {
		return "CodeRabbit"
	}
	return ""
}

// MARK: What the events read

// ReviewedPR is an open pull request and whether CodeRabbit has reviewed its head commit: a
// review on that commit, or its status at success. Review is its last review's state there
// (commented, approved or changes_requested), "" when only the status says so.
type ReviewedPR struct {
	PR
	HeadSHA  string
	Reviewed bool
	Review   string
	URL      string
	Trusted  bool
}

// CodeRabbitComment is one review comment by CodeRabbit, on a line or as an answer in a thread.
type CodeRabbitComment struct {
	ID        int
	PR        PR
	Path      string
	Line      int
	InReplyTo int
	Body      string
	URL       string
	At        string
	Trusted   bool
}

func (c CodeRabbitComment) data() map[string]any {
	comment := map[string]any{"id": c.ID, "path": c.Path, "body": c.Body, "url": c.URL}
	if c.Line != 0 {
		comment["line"] = c.Line
	}
	if c.InReplyTo != 0 {
		comment["inReplyTo"] = c.InReplyTo
	}
	return map[string]any{"pr": c.PR.json(), "comment": comment, "commentedAt": c.At}
}

// reviewedQuery is the open PRs with their head commit, CodeRabbit's status on it and the
// last reviews: one call for review.posted, whatever the number of PRs.
const reviewedQuery = `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
  pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
    number title headRefName headRefOid url isCrossRepository authorAssociation author { login __typename }
    reviews(last: 20) { nodes { author { login __typename } state url commit { oid } } }
    commits(last: 1) { nodes { commit { oid status { context(name: "` + codeRabbitStatus + `") { state } } } } } } } } }`

func (g *RealGitHub) CodeRabbitPRs(ctx context.Context, repo string) ([]ReviewedPR, error) {
	owner, name, err := ownerName(repo)
	if err != nil {
		return nil, err
	}
	request, _ := json.Marshal(map[string]any{"query": reviewedQuery, "variables": map[string]string{"owner": owner, "name": name}})
	body, err := g.shared("graphql coderabbit "+repo, func() ([]byte, error) {
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
						HeadRefName string    `json:"headRefName"`
						HeadRefOid  string    `json:"headRefOid"`
						URL         string    `json:"url"`
						CrossRepo   bool      `json:"isCrossRepository"`
						Association string    `json:"authorAssociation"`
						Author      *gqlActor `json:"author"`
						Reviews     struct {
							Nodes []struct {
								Author *gqlActor `json:"author"`
								State  string    `json:"state"`
								URL    string    `json:"url"`
								Commit *struct {
									Oid string `json:"oid"`
								} `json:"commit"`
							} `json:"nodes"`
						} `json:"reviews"`
						Commits struct {
							Nodes []struct {
								Commit struct {
									Oid    string `json:"oid"`
									Status *struct {
										Context *struct {
											State string `json:"state"`
										} `json:"context"`
									} `json:"status"`
								} `json:"commit"`
							} `json:"nodes"`
						} `json:"commits"`
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
	var out []ReviewedPR
	for _, n := range answer.Data.Repository.PullRequests.Nodes {
		r := ReviewedPR{PR: PR{Number: n.Number, Title: n.Title, Branch: n.HeadRefName, URL: n.URL}, HeadSHA: n.HeadRefOid}
		if n.Author != nil && !n.CrossRepo {
			r.Trusted = isTrusted(n.Association, n.Author.Login, n.Author.Typename)
		}
		for _, c := range n.Commits.Nodes {
			if c.Commit.Oid == n.HeadRefOid && c.Commit.Status != nil && c.Commit.Status.Context != nil &&
				strings.EqualFold(c.Commit.Status.Context.State, "SUCCESS") {
				r.Reviewed = true
			}
		}
		for _, v := range n.Reviews.Nodes {
			if v.Author.isCodeRabbit() && v.Commit != nil && v.Commit.Oid == n.HeadRefOid {
				r.Reviewed, r.Review, r.URL = true, strings.ToLower(v.State), v.URL
			}
		}
		if r.URL == "" {
			r.URL = n.URL
		}
		out = append(out, r)
	}
	return out, nil
}

func (g *RealGitHub) CodeRabbitComments(ctx context.Context, repo, since string) ([]CodeRabbitComment, bool, error) {
	type comment struct {
		ID          int    `json:"id"`
		HTMLURL     string `json:"html_url"`
		PullURL     string `json:"pull_request_url"`
		Body        string `json:"body"`
		Path        string `json:"path"`
		Line        *int   `json:"line"`
		Original    *int   `json:"original_line"`
		InReplyTo   int    `json:"in_reply_to_id"`
		User        user   `json:"user"`
		CreatedAt   string `json:"created_at"`
		PerformedBy *struct {
			Slug string `json:"slug"`
		} `json:"performed_via_github_app"`
	}
	// since lists comments updated since; an edited old one is dropped by its created_at.
	path := fmt.Sprintf("repos/%s/pulls/comments?sort=created&direction=desc&since=%s", repo, url.QueryEscape(since))
	items, truncated, err := newest(ctx, g, path, since, func(c comment) string { return c.CreatedAt })
	if err != nil {
		return nil, false, err
	}
	var out []CodeRabbitComment
	pulls := map[string]pull{}
	for _, c := range items {
		slug := ""
		if c.PerformedBy != nil {
			slug = c.PerformedBy.Slug
		}
		if !isCodeRabbitREST(c.User, slug) {
			continue
		}
		// A comment names its PR only by URL; the PR (cached for this poll) says its title and branch.
		path := strings.TrimPrefix(strings.TrimPrefix(c.PullURL, g.API), "https://api.github.com/")
		p, ok := pulls[path]
		if !ok {
			if err := g.get(ctx, path, false, &p); err != nil {
				return nil, false, err
			}
			pulls[path] = p
		}
		line := 0
		if c.Line != nil {
			line = *c.Line
		} else if c.Original != nil {
			line = *c.Original
		}
		out = append(out, CodeRabbitComment{ID: c.ID, PR: p.pr(), Path: c.Path, Line: line, InReplyTo: c.InReplyTo,
			Body: clip(c.Body), URL: c.HTMLURL, At: c.CreatedAt, Trusted: p.trusted(repo)})
	}
	return out, truncated, nil
}

// MARK: What the tools do

// ReplyInThread answers a review comment in its thread, as the person.
func (g *RealGitHub) ReplyInThread(ctx context.Context, repo string, number, commentID int, words string) (map[string]any, error) {
	if _, _, err := ownerName(repo); err != nil {
		return nil, err
	}
	body, _ := json.Marshal(map[string]string{"body": words})
	answer, err := g.do(ctx, http.MethodPost, fmt.Sprintf("repos/%s/pulls/%d/comments/%d/replies", repo, number, commentID), body, false)
	if err != nil {
		return nil, err
	}
	var c struct {
		HTMLURL string `json:"html_url"`
	}
	_ = json.Unmarshal(answer, &c)
	return map[string]any{"url": c.HTMLURL}, nil
}

// mentioned is words that mention CodeRabbit, so it answers: its handle put first when missing.
func mentioned(words string) string {
	words = strings.TrimSpace(words)
	if strings.Contains(strings.ToLower(words), "@"+codeRabbitApp) {
		return words
	}
	return "@" + codeRabbitApp + " " + words
}

type askReviewArgs struct {
	Repo   string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number int    `json:"number" jsonschema:"the pull request's number"`
	Full   bool   `json:"full,omitempty" jsonschema:"true: review every file again, not only the changes since its last review"`
}

type replyArgs struct {
	Repo      string `json:"repo,omitempty" jsonschema:"owner/name; the repo this folder pushes to when left out"`
	Number    int    `json:"number" jsonschema:"the pull request's number"`
	CommentID int    `json:"commentId" jsonschema:"the id of CodeRabbit's review comment to answer (comment.id in a review.comment event)"`
	Body      string `json:"body" jsonschema:"the answer, in Markdown; @coderabbitai is put first when it is not in it"`
}

// addCodeRabbitTools puts the tools that speak to CodeRabbit on server: agents and pages may call them.
func addCodeRabbitTools(server *mcp.Server, gh Views, repoOf func(context.Context, string) (string, error)) {
	command := func(ctx context.Context, repo string, number int, words string) *mcp.CallToolResult {
		repo, err := repoOf(ctx, repo)
		if err != nil {
			return failed(err)
		}
		r, err := gh.CommentOnPR(ctx, repo, number, words)
		if err != nil {
			return failed(err)
		}
		r["command"] = words
		return structured(r)
	}

	mcp.AddTool(server, &mcp.Tool{Name: "coderabbit_review", Title: "Ask CodeRabbit to review again",
		Description: "Asks CodeRabbit to review a pull request again, with a comment `@coderabbitai review` (the changes since its last " +
			"review) or, with full, `@coderabbitai full review` (every file). Its review comes back as review.posted and review.comment events.",
		Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in askReviewArgs) (*mcp.CallToolResult, any, error) {
			words := "@" + codeRabbitApp + " review"
			if in.Full {
				words = "@" + codeRabbitApp + " full review"
			}
			return command(ctx, in.Repo, in.Number, words), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "coderabbit_reply", Title: "Answer a CodeRabbit comment",
		Description: "Answers one of CodeRabbit's review comments in its thread, mentioning @coderabbitai so it reads the answer: say what " +
			"you changed, or why the comment does not apply. Its answer comes back as a review.comment event.",
		Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in replyArgs) (*mcp.CallToolResult, any, error) {
			repo, err := repoOf(ctx, in.Repo)
			if err != nil {
				return failed(err), nil, nil
			}
			if strings.TrimSpace(in.Body) == "" {
				return failed(fmt.Errorf("write the answer first")), nil, nil
			}
			if in.CommentID <= 0 {
				return failed(fmt.Errorf("commentId is the id of CodeRabbit's review comment")), nil, nil
			}
			r, err := gh.ReplyInThread(ctx, repo, in.Number, in.CommentID, mentioned(in.Body))
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(r), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "coderabbit_resolve", Title: "Resolve CodeRabbit's comments",
		Description: "Asks CodeRabbit to resolve all its review comments on a pull request, with a comment `@coderabbitai resolve`. " +
			"Do it only when each one is fixed or answered.",
		Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in prArgs) (*mcp.CallToolResult, any, error) {
			return command(ctx, in.Repo, in.Number, "@"+codeRabbitApp+" resolve"), nil, nil
		})
}

// MARK: On the page

// codeRabbitState is CodeRabbit's status in a PR's checks: reviewing, reviewed or failed; "" when it has none.
func codeRabbitState(items []checkItem) string {
	for _, c := range items {
		if c.Typename == "StatusContext" && c.Context == codeRabbitStatus {
			switch c.state() {
			case "passing":
				return "reviewed"
			case "failing":
				return "failed"
			}
			return "reviewing"
		}
	}
	return ""
}
