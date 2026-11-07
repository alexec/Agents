package forgejomcp

import (
	"context"
	"fmt"
	"net/url"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// What the views read on Forgejo (#3838), in the gitlab server's shapes
// (Go/internal/gitlabmcp/pages.go), so a page is drawn the same way: the open pull requests
// and issues, and one pull request's page. As the person, with the same token as the events.
// A pull request's diff is PRDiff (forgewrite.go), which the Work pages read too.

// The lists' sections for a team (#2952, specs/2453-team-lists.md), as the gitlab server has
// them: each open pull request and issue is in one, by how it relates to the viewer, the login
// of this server's token. The pages draw them in this order and leave an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// boardReads is how many pull requests' checks and reviews the board reads at once.
const boardReads = 4

// viewer is the login whose token it is.
func (f *RealForgejo) viewer(ctx context.Context) (string, error) {
	var u user
	if err := f.get(ctx, "user", true, &u); err != nil {
		return "", err
	}
	return u.Login, nil
}

// teamMeta is the control plane's people and bots, by Forgejo login lowercased (#2951), read
// from the call's _meta, which the host fills in. Empty with no control plane, or a host that
// gives no Forgejo logins.
type teamMeta map[string]teamPerson

type teamPerson struct {
	Name string
	Bot  bool
}

func teamMetaOf(meta mcp.Meta) teamMeta {
	list, ok := meta["people"].([]any)
	if !ok {
		return nil
	}
	out := teamMeta{}
	for _, item := range list {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		login, _ := row["forgejo"].(string)
		if login == "" {
			continue
		}
		name, _ := row["name"].(string)
		bot, _ := row["bot"].(bool)
		out[strings.ToLower(login)] = teamPerson{Name: name, Bot: bot}
	}
	return out
}

// agentOnOf reads _meta's agentOnPR or agentOnIssue (#2951): who is on that number, or "".
func agentOnOf(meta mcp.Meta, key string, number int) string {
	m, ok := meta[key].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m[strconv.Itoa(number)].(string)
	return who
}

// otherSection: with the control plane's people (#2951), Team is those people and bots; with
// none, the repository's own (trusted: write access or more), and bots.
func (f *RealForgejo) otherSection(ctx context.Context, repo string, u user, people teamMeta) string {
	if len(people) > 0 {
		_, on := people[strings.ToLower(u.Login)]
		return sectionIf(on)
	}
	if isBot(u.Login, u.ID) {
		return sectionTeam
	}
	// When Forgejo cannot say, they are Others: the list still shows.
	trusted, _ := f.trusted(ctx, repo, &u)
	return sectionIf(trusted)
}

func sectionIf(team bool) string {
	if team {
		return sectionTeam
	}
	return sectionOthers
}

// named puts the control plane's name for the author on a row, and whether they are a bot.
func named(j map[string]any, u user, people teamMeta) {
	if isBot(u.Login, u.ID) {
		j["authorBot"] = true
	}
	if tp, on := people[strings.ToLower(u.Login)]; on {
		j["authorName"] = tp.Name
		if tp.Bot {
			j["authorBot"] = true
		}
	}
}

// MARK: The board

// prState is a pull request's checks and review, as the board and its page say them.
type prState struct {
	checks, review string
	runID          int
	err            error
}

// prStateOf reads a pull request's head's commit statuses and its reviews.
func (f *RealForgejo) prStateOf(ctx context.Context, repo string, p pullJSON) prState {
	s := prState{checks: "none"}
	if p.Head.SHA != "" {
		c, err := f.status(ctx, repo, p.Head.SHA)
		if err != nil {
			return prState{err: err}
		}
		if len(c.Statuses) > 0 {
			s.checks = checkState(c.State)
		}
		for _, st := range c.Statuses {
			if failedStatus(st.State) {
				if m := actionsRun.FindStringSubmatch(st.TargetURL); m != nil {
					s.runID, _ = strconv.Atoi(m[1])
					break
				}
			}
		}
	}
	var reviews []reviewJSON
	if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d/reviews?limit=%d", repoPath(repo), p.Number, perPage), false, &reviews); err != nil {
		return prState{err: err}
	}
	s.review, _ = reviewOf(reviews, len(p.RequestedReviewers) > 0)
	return s
}

// prSection is a pull request's section: Needs you when the viewer is asked to review it, or
// when the viewer's own has failing checks, a conflict, or a reviewer who asked for changes.
func (f *RealForgejo) prSection(ctx context.Context, repo string, p pullJSON, s prState, conflicts *bool, viewer string, people teamMeta) string {
	mine := viewer != "" && strings.EqualFold(p.User.Login, viewer)
	switch {
	case viewer != "" && slices.ContainsFunc(p.RequestedReviewers, func(u user) bool { return strings.EqualFold(u.Login, viewer) }):
		return sectionNeedsYou
	case mine && (s.checks == "failing" || (conflicts != nil && *conflicts) || s.review == "changes_requested"):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	return f.otherSection(ctx, repo, p.User, people)
}

// Board is the open pull requests, newest created first, at most 50, each with its head's
// checks, its review and its section for who is signed in (#2952). Forgejo has no list of
// many commits' statuses, so each pull request's are read, boardReads at a time.
func (f *RealForgejo) Board(ctx context.Context, repo string, meta mcp.Meta) (map[string]any, error) {
	var pulls []pullJSON
	if err := f.get(ctx, fmt.Sprintf("%s/pulls?state=open&limit=%d", repoPath(repo), perPage), false, &pulls); err != nil {
		return nil, err
	}
	sort.SliceStable(pulls, func(i, j int) bool { return before(pulls[j].CreatedAt, pulls[i].CreatedAt) })
	viewer, err := f.viewer(ctx)
	if err != nil {
		return nil, err
	}
	states := make([]prState, len(pulls))
	var wg sync.WaitGroup
	gate := make(chan struct{}, boardReads)
	for i, p := range pulls {
		wg.Add(1)
		gate <- struct{}{}
		go func() {
			defer func() { <-gate; wg.Done() }()
			states[i] = f.prStateOf(ctx, repo, p)
		}()
	}
	wg.Wait()
	people := teamMetaOf(meta)
	out := make([]any, len(pulls))
	needsYou := 0
	for i, p := range pulls {
		s := states[i]
		if s.err != nil {
			return nil, s.err
		}
		j := map[string]any{"number": p.Number, "title": p.Title, "url": p.HTMLURL, "branch": p.Head.Ref, "base": p.Base.Ref,
			"author": p.User.Login, "updatedAt": p.UpdatedAt, "draft": p.draft(), "checks": s.checks}
		if s.runID != 0 {
			j["failedRunId"] = s.runID
		}
		conflicts := f.conflicts(repo, p)
		if conflicts != nil {
			j["conflicts"] = *conflicts
		}
		if s.review != "" {
			j["review"] = s.review
		}
		named(j, p.User, people)
		section := f.prSection(ctx, repo, p, s, conflicts, viewer, people)
		j["section"] = section
		if section == sectionNeedsYou {
			needsYou++
		}
		if section == sectionNeedsYou || section == sectionYours {
			if who := agentOnOf(meta, "agentOnPR", p.Number); who != "" {
				j["agentOn"] = who
			}
		}
		out[i] = j
	}
	// count and attention, the Needs you count, are the sidebar row's (#2033).
	return map[string]any{"repo": repo, "viewer": viewer, "pullRequests": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: Issues

// OpenIssues are the open issues (not pull requests), newest created first, at most 50, with
// label's only when it is set, each with its section for who is signed in (#2952).
func (f *RealForgejo) OpenIssues(ctx context.Context, repo, label string, meta mcp.Meta) (map[string]any, error) {
	path := fmt.Sprintf("%s/issues?type=issues&state=open&limit=%d", repoPath(repo), perPage)
	if label != "" {
		path += "&labels=" + url.QueryEscape(label)
	}
	var list []issueJSON
	if err := f.get(ctx, path, false, &list); err != nil {
		return nil, err
	}
	sort.SliceStable(list, func(i, j int) bool { return before(list[j].CreatedAt, list[i].CreatedAt) })
	// Without the viewer the list still shows, as Team and Others only.
	viewer, _ := f.viewer(ctx)
	people := teamMetaOf(meta)
	out := make([]any, len(list))
	needsYou := 0
	for n, i := range list {
		j := issueSummary(i)
		named(j, i.User, people)
		var section string
		switch {
		case viewer != "" && slices.ContainsFunc(i.Assignees, func(u user) bool { return strings.EqualFold(u.Login, viewer) }):
			section = sectionNeedsYou
		case viewer != "" && strings.EqualFold(i.User.Login, viewer):
			section = sectionYours
		default:
			section = f.otherSection(ctx, repo, i.User, people)
		}
		j["section"] = section
		if section == sectionNeedsYou {
			needsYou++
		}
		if section == sectionNeedsYou || section == sectionYours {
			if who := agentOnOf(meta, "agentOnIssue", i.Number); who != "" {
				j["agentOn"] = who
			}
		}
		out[n] = j
	}
	return map[string]any{"repo": repo, "viewer": viewer, "issues": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: A pull request's page

// fileJSON is one of a pull request's changed files, as /pulls/:n/files says it.
type fileJSON struct {
	Filename  string `json:"filename"`
	Previous  string `json:"previous_filename"`
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
}

func (f fileJSON) change() string {
	switch f.Status {
	case "added":
		return "added"
	case "deleted", "removed":
		return "removed"
	case "renamed":
		return "renamed"
	}
	return "modified"
}

// noteOf is a comment as the page draws it.
func noteOf(author *user, body, at, url string, id int) map[string]any {
	login, bot := "", false
	if author != nil {
		login, bot = author.Login, isBot(author.Login, author.ID)
	}
	return map[string]any{"author": login, "bot": bot, "body": body, "at": at, "url": url, "id": id}
}

// PRPage is one pull request as its page draws it: the gitlab server's merge request page,
// with the head's commit statuses as its checks and its reviews' line comments as its threads.
func (f *RealForgejo) PRPage(ctx context.Context, repo string, number int) (map[string]any, error) {
	var p pullJSON
	if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d", repoPath(repo), number), false, &p); err != nil {
		return nil, err
	}
	viewer, err := f.viewer(ctx)
	if err != nil {
		return nil, err
	}
	changed, truncated, err := all[fileJSON](ctx, f, fmt.Sprintf("%s/pulls/%d/files", repoPath(repo), number))
	if err != nil {
		return nil, err
	}
	additions, deletions := 0, 0
	files := make([]any, len(changed))
	for i, c := range changed {
		additions, deletions = additions+c.Additions, deletions+c.Deletions
		files[i] = map[string]any{"path": c.Filename, "additions": c.Additions, "deletions": c.Deletions, "change": c.change()}
	}
	comments, _, err := all[commentJSON](ctx, f, fmt.Sprintf("%s/issues/%d/comments", repoPath(repo), number))
	if err != nil {
		return nil, err
	}
	conversation := []any{}
	for _, c := range comments {
		conversation = append(conversation, noteOf(&c.User, c.Body, c.CreatedAt, c.HTMLURL, c.ID))
	}
	var reviews []reviewJSON
	if err := f.get(ctx, fmt.Sprintf("%s/pulls/%d/reviews?limit=%d", repoPath(repo), number, perPage), false, &reviews); err != nil {
		return nil, err
	}
	// A review's own words are in the conversation; its line comments are threads.
	for _, r := range reviews {
		if strings.TrimSpace(r.Body) != "" {
			conversation = append(conversation, noteOf(r.User, r.Body, r.SubmittedAt, r.HTMLURL, r.ID))
		}
	}
	sort.SliceStable(conversation, func(i, j int) bool {
		return before(conversation[i].(map[string]any)["at"].(string), conversation[j].(map[string]any)["at"].(string))
	})
	lines, err := f.reviewComments(ctx, repo, p, "")
	if err != nil {
		return nil, err
	}
	threads := lineThreads(lines)
	state := prState{checks: "none"}
	runs := []any{}
	if p.Head.SHA != "" {
		c, err := f.status(ctx, repo, p.Head.SHA)
		if err != nil {
			return nil, err
		}
		if len(c.Statuses) > 0 {
			state.checks = checkState(c.State)
		}
		for _, s := range c.Statuses {
			run := map[string]any{"name": s.Context, "state": checkState(s.State), "url": s.TargetURL, "description": s.Description}
			if m := actionsRun.FindStringSubmatch(s.TargetURL); m != nil {
				id, _ := strconv.Atoi(m[1])
				run["runId"] = id
				if failedStatus(s.State) && state.runID == 0 {
					state.runID = id
				}
			}
			runs = append(runs, run)
		}
	}
	state.review, _ = reviewOf(reviews, len(p.RequestedReviewers) > 0)
	st := "open"
	switch {
	case p.Merged:
		st = "merged"
	case p.State == "closed":
		st = "closed"
	}
	squash := false
	if methods, err := f.MergeMethods(ctx, repo); err == nil && len(methods) > 0 {
		squash = methods[0] == "squash"
	}
	page := map[string]any{
		"repo": repo, "number": p.Number, "title": p.Title, "url": p.HTMLURL, "branch": p.Head.Ref, "base": p.Base.Ref,
		"author": p.User.Login, "state": st, "draft": p.draft(), "body": p.Body, "createdAt": p.CreatedAt,
		"additions": additions, "deletions": deletions, "checks": state.checks, "squash": squash,
		"checkRuns": runs, "files": files, "filesTotal": len(files), "filesCut": truncated, "comments": conversation, "threads": threads,
		"viewer": viewer, "fromFork": p.fork(), "headSha": p.Head.SHA,
	}
	if state.runID != 0 {
		page["failedRunId"] = state.runID
	}
	if st == "open" {
		if c := f.conflicts(repo, p); c != nil {
			page["conflicts"] = *c
		}
	}
	if state.review != "" {
		page["review"] = state.review
	}
	return page, nil
}

// lineThreads are a pull request's line comments as threads: Forgejo keeps a thread by its
// file and line, so the comments on one file and line, oldest first, are one.
func lineThreads(lines []reviewCommentJSON) []any {
	sort.SliceStable(lines, func(i, j int) bool { return before(lines[i].CreatedAt, lines[j].CreatedAt) })
	type key struct {
		path string
		line int
	}
	var order []key
	byKey := map[key][]reviewCommentJSON{}
	for _, c := range lines {
		k := key{c.Path, c.line()}
		if _, ok := byKey[k]; !ok {
			order = append(order, k)
		}
		byKey[k] = append(byKey[k], c)
	}
	threads := []any{}
	for _, k := range order {
		list := byKey[k]
		comments := make([]any, len(list))
		for i, c := range list {
			comments[i] = noteOf(c.User, c.Body, c.CreatedAt, c.HTMLURL, c.ID)
		}
		j := map[string]any{"path": k.path, "resolved": list[0].Resolver != nil, "outdated": list[0].Position == 0, "comments": comments}
		if k.line > 0 {
			j["line"] = k.line
		}
		threads = append(threads, j)
	}
	return threads
}
