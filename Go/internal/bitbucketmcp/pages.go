package bitbucketmcp

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/mcpevents"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// What the views read on Bitbucket (#3866), in the forgejo server's shapes
// (Go/internal/forgejomcp/pages.go), so a page is drawn the same way: the open pull requests
// and issues, and one pull request's page. As the person, with the same token as the events.
// A pull request's diff is PRDiff (forgewrite.go), which the Work pages read too.

// The lists' sections for a team (#2952, specs/2453-team-lists.md), as the gitlab server has
// them: each open pull request and issue is in one, by how it relates to the viewer, the
// person whose token it is. The pages draw them in this order and leave an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// boardReads is how many pull requests' checks and conflicts the board reads at once.
const boardReads = 4

// teamMeta is the control plane's people and bots, by Bitbucket nickname lowercased (#2951),
// read from the call's _meta, which the host fills in. Empty with no control plane, or a host
// that gives no Bitbucket logins.
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
		login, _ := row["bitbucket"].(string)
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
// none, the repository's own (trusted: write access or more, or the workspace's members), and
// bots.
func (b *RealBitbucket) otherSection(ctx context.Context, repo string, u *user, people teamMeta) string {
	if len(people) > 0 {
		_, on := people[strings.ToLower(u.name())]
		return sectionIf(on)
	}
	if u != nil && isBot(u.name(), u.Type) {
		return sectionTeam
	}
	// When Bitbucket cannot say, they are Others: the list still shows.
	trusted, _ := b.trusted(ctx, repo, u)
	return sectionIf(trusted)
}

func sectionIf(team bool) string {
	if team {
		return sectionTeam
	}
	return sectionOthers
}

// named puts the control plane's name for the author on a row, and whether they are a bot.
func named(j map[string]any, u *user, people teamMeta) {
	if u == nil {
		return
	}
	if isBot(u.name(), u.Type) {
		j["authorBot"] = true
	}
	if tp, on := people[strings.ToLower(u.name())]; on {
		j["authorName"] = tp.Name
		if tp.Bot {
			j["authorBot"] = true
		}
	}
}

// MARK: The board

// prState is a pull request's checks and conflict, as the board and its page say them.
type prState struct {
	checks    string
	runID     int
	conflicts bool
	err       error
}

// prStateOf reads a pull request's head's commit statuses and whether its diffstat has a
// file in conflict.
func (b *RealBitbucket) prStateOf(ctx context.Context, repo string, p pullJSON) prState {
	s := prState{checks: "none"}
	if sha := p.Source.hash(); sha != "" {
		statuses, err := b.statuses(ctx, repo, sha, false)
		if err != nil {
			return prState{err: err}
		}
		if state := combined(statuses); state != "" {
			s.checks = checkState(state)
		}
		s.runID = failedRun(statuses)
	}
	c, err := b.conflicts(ctx, repo, p)
	if err != nil {
		return prState{err: err}
	}
	s.conflicts = c
	return s
}

// failedRun is the build number of the first failed Pipelines run among a commit's statuses,
// 0 when none failed or the failed ones are another CI's.
func failedRun(statuses []statusJSON) int {
	for _, s := range statuses {
		if s.State == "FAILED" {
			if n := PipelineRun(s.URL); n != 0 {
				return n
			}
		}
	}
	return 0
}

// asksReview says whether me is one of a pull request's reviewers and has not approved it yet.
func (p forgePullJSON) asksReview(me *user) bool {
	if !slices.ContainsFunc(p.Reviewers, func(r user) bool { return r.same(me) }) {
		return false
	}
	return !slices.ContainsFunc(p.Participants, func(r participant) bool { return r.User.same(me) && (r.Approved || r.State == "approved") })
}

// prSection is a pull request's section: Needs you when the viewer is a reviewer who has not
// approved it, or when the viewer's own has failing checks, a conflict, or a reviewer who asked
// for changes.
func (b *RealBitbucket) prSection(ctx context.Context, repo string, p forgePullJSON, s prState, review string, me *user, people teamMeta) string {
	mine := me != nil && p.Author.same(me)
	switch {
	case me != nil && p.asksReview(me):
		return sectionNeedsYou
	case mine && (s.checks == "failing" || s.conflicts || review == "changes_requested"):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	return b.otherSection(ctx, repo, &p.Author, people)
}

// viewer is the person whose token it is, or nil when Bitbucket does not say.
func (b *RealBitbucket) viewer(ctx context.Context) (*user, error) {
	me, err := b.me(ctx)
	if err != nil {
		return nil, err
	}
	return &me, nil
}

// Board is the open pull requests, newest created first, at most 50, each with its head's
// checks, its conflict, its review and its section for who is signed in (#2952). Bitbucket
// has no list of many commits' statuses, so each pull request's are read, boardReads at a time.
func (b *RealBitbucket) Board(ctx context.Context, repo string, meta mcp.Meta) (map[string]any, error) {
	var list paged[forgePullJSON]
	if err := b.get(ctx, fmt.Sprintf("%s/pullrequests?state=OPEN&sort=-created_on&pagelen=%d&%s", repoPath(repo), perPage, forgePullFields), false, &list); err != nil {
		return nil, err
	}
	pulls := list.Values
	sort.SliceStable(pulls, func(i, j int) bool { return mcpevents.Before(pulls[j].CreatedOn, pulls[i].CreatedOn) })
	me, err := b.viewer(ctx)
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
			states[i] = b.prStateOf(ctx, repo, p.pullJSON)
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
		j := map[string]any{"number": p.ID, "title": p.Title, "url": p.Links.HTML.Href, "branch": p.Source.Branch.Name, "base": p.Destination.Branch.Name,
			"author": p.Author.name(), "updatedAt": p.UpdatedOn, "draft": p.Draft, "checks": s.checks, "conflicts": s.conflicts}
		if s.runID != 0 {
			j["failedRunId"] = s.runID
		}
		review := p.review()
		if review != "" {
			j["review"] = review
		}
		named(j, &p.Author, people)
		section := b.prSection(ctx, repo, p, s, review, me, people)
		j["section"] = section
		if section == sectionNeedsYou {
			needsYou++
		}
		if section == sectionNeedsYou || section == sectionYours {
			if who := agentOnOf(meta, "agentOnPR", p.ID); who != "" {
				j["agentOn"] = who
			}
		}
		out[i] = j
	}
	// count and attention, the Needs you count, are the sidebar row's (#2033).
	return map[string]any{"repo": repo, "viewer": me.name(), "pullRequests": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: Issues

// OpenIssues are the open issues (new, open or on hold), newest created first, at most 50,
// with label's kind or component only when it is set, each with its section for who is signed
// in (#2952).
func (b *RealBitbucket) OpenIssues(ctx context.Context, repo, label string, meta mcp.Meta) (map[string]any, error) {
	q := openIssues
	if label != "" {
		q += fmt.Sprintf(" AND (kind=%q OR component.name=%q)", label, label)
	}
	var list paged[issueJSON]
	if err := b.get(ctx, fmt.Sprintf("%s/issues?sort=-created_on&pagelen=%d&%s", repoPath(repo), perPage, bbql(q)), false, &list); err != nil {
		if noTracker(err) {
			return nil, fmt.Errorf("%w: %s may have no issue tracker", err, repo)
		}
		return nil, err
	}
	issues := list.Values
	sort.SliceStable(issues, func(i, j int) bool { return mcpevents.Before(issues[j].CreatedOn, issues[i].CreatedOn) })
	// Without the viewer the list still shows, as Team and Others only.
	me, _ := b.viewer(ctx)
	people := teamMetaOf(meta)
	out := make([]any, len(issues))
	needsYou := 0
	for n, i := range issues {
		j := issueSummary(i)
		named(j, i.Reporter, people)
		var section string
		switch {
		case me != nil && i.Assignee.same(me):
			section = sectionNeedsYou
		case me != nil && i.Reporter.same(me):
			section = sectionYours
		default:
			section = b.otherSection(ctx, repo, i.Reporter, people)
		}
		j["section"] = section
		if section == sectionNeedsYou {
			needsYou++
		}
		if section == sectionNeedsYou || section == sectionYours {
			if who := agentOnOf(meta, "agentOnIssue", i.ID); who != "" {
				j["agentOn"] = who
			}
		}
		out[n] = j
	}
	return map[string]any{"repo": repo, "viewer": me.name(), "issues": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: A pull request's page

// fileJSON is one of a pull request's changed files, as /pullrequests/:n/diffstat says it.
type fileJSON struct {
	Status  string `json:"status"`
	Added   int    `json:"lines_added"`
	Removed int    `json:"lines_removed"`
	Old     *struct {
		Path string `json:"path"`
	} `json:"old"`
	New *struct {
		Path string `json:"path"`
	} `json:"new"`
}

func (f fileJSON) path() string {
	if f.New != nil {
		return f.New.Path
	}
	if f.Old != nil {
		return f.Old.Path
	}
	return ""
}

func (f fileJSON) change() string {
	switch f.Status {
	case "added", "removed", "renamed":
		return f.Status
	}
	return "modified"
}

// noteOf is a comment as the page draws it.
func noteOf(author *user, body, at, url string, id int) map[string]any {
	return map[string]any{"author": author.name(), "bot": author != nil && isBot(author.name(), author.Type), "body": body, "at": at, "url": url, "id": id}
}

// PRPage is one pull request as its page draws it: the forgejo server's pull request page,
// with the head's commit statuses as its checks and its comments on lines as its threads.
func (b *RealBitbucket) PRPage(ctx context.Context, repo string, number int) (map[string]any, error) {
	var p forgePullJSON
	if err := b.get(ctx, fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), false, &p); err != nil {
		return nil, err
	}
	me, err := b.viewer(ctx)
	if err != nil {
		return nil, err
	}
	changed, truncated, err := all[fileJSON](ctx, b, fmt.Sprintf("%s/pullrequests/%d/diffstat", repoPath(repo), number), false)
	if err != nil {
		return nil, err
	}
	additions, deletions, conflicts := 0, 0, false
	files := make([]any, len(changed))
	for i, c := range changed {
		additions, deletions = additions+c.Added, deletions+c.Removed
		files[i] = map[string]any{"path": c.path(), "additions": c.Added, "deletions": c.Removed, "change": c.change()}
		conflicts = conflicts || conflictStates[c.Status]
	}
	comments, _, err := all[commentJSON](ctx, b, fmt.Sprintf("%s/pullrequests/%d/comments?sort=created_on", repoPath(repo), number), false)
	if err != nil {
		return nil, err
	}
	conversation := []any{}
	var lines []commentJSON
	for _, c := range comments {
		switch {
		case c.Deleted:
		case c.Inline != nil || c.Parent != nil:
			lines = append(lines, c)
		case strings.TrimSpace(c.Content.Raw) != "":
			conversation = append(conversation, noteOf(c.User, c.Content.Raw, c.CreatedOn, c.Links.HTML.Href, c.ID))
		}
	}
	threads, answers := lineThreads(lines)
	// An answer to a comment that is not on a line is the conversation's.
	for _, c := range answers {
		conversation = append(conversation, noteOf(c.User, c.Content.Raw, c.CreatedOn, c.Links.HTML.Href, c.ID))
	}
	sort.SliceStable(conversation, func(i, j int) bool {
		return mcpevents.Before(conversation[i].(map[string]any)["at"].(string), conversation[j].(map[string]any)["at"].(string))
	})
	state := prState{checks: "none", conflicts: conflicts}
	runs := []any{}
	if sha := p.Source.hash(); sha != "" {
		statuses, err := b.statuses(ctx, repo, sha, false)
		if err != nil {
			return nil, err
		}
		if s := combined(statuses); s != "" {
			state.checks = checkState(s)
		}
		state.runID = failedRun(statuses)
		for _, s := range statuses {
			run := map[string]any{"name": s.title(), "state": checkState(s.State), "url": s.URL, "description": s.Description}
			if id := PipelineRun(s.URL); id != 0 {
				run["runId"] = id
			}
			runs = append(runs, run)
		}
	}
	st := "closed"
	switch p.State {
	case "OPEN":
		st = "open"
	case "MERGED":
		st = "merged"
	}
	squash := false
	if methods, err := b.MergeMethods(ctx, repo, number); err == nil && len(methods) > 0 {
		squash = methods[0] == "squash"
	}
	page := map[string]any{
		"repo": repo, "number": p.ID, "title": p.Title, "url": p.Links.HTML.Href, "branch": p.Source.Branch.Name, "base": p.Destination.Branch.Name,
		"author": p.Author.name(), "state": st, "draft": p.Draft, "body": p.Description, "createdAt": p.CreatedOn,
		"additions": additions, "deletions": deletions, "checks": state.checks, "squash": squash,
		"checkRuns": runs, "files": files, "filesTotal": len(files), "filesCut": truncated, "comments": conversation, "threads": threads,
		"viewer": me.name(), "fromFork": p.fork(), "headSha": p.Source.hash(),
	}
	if state.runID != 0 {
		page["failedRunId"] = state.runID
	}
	if st == "open" {
		page["conflicts"] = state.conflicts
	}
	if review := p.review(); review != "" {
		page["review"] = review
	}
	return page, nil
}

// lineThreads are a pull request's comments on lines, oldest first, as threads: Bitbucket
// keeps a thread by its first comment, which each answer names as its parent (or its parent's
// parent). answers are the ones whose thread starts on no line.
func lineThreads(lines []commentJSON) (threads []any, answers []commentJSON) {
	sort.SliceStable(lines, func(i, j int) bool { return mcpevents.Before(lines[i].CreatedOn, lines[j].CreatedOn) })
	rootOf := map[int]int{}
	var order []int
	byRoot := map[int][]commentJSON{}
	for _, c := range lines {
		root := c.ID
		if c.Parent != nil {
			root = c.Parent.ID
			if r, ok := rootOf[root]; ok {
				root = r
			}
		}
		rootOf[c.ID] = root
		if _, ok := byRoot[root]; !ok {
			order = append(order, root)
		}
		byRoot[root] = append(byRoot[root], c)
	}
	threads = []any{}
	for _, root := range order {
		list := byRoot[root]
		// Its first comment, or the first answer when that was deleted: an answer carries its line.
		first := list[0]
		if first.Inline == nil {
			answers = append(answers, list...)
			continue
		}
		comments := make([]any, len(list))
		for i, c := range list {
			comments[i] = noteOf(c.User, c.Content.Raw, c.CreatedOn, c.Links.HTML.Href, c.ID)
		}
		j := map[string]any{"path": first.Inline.Path, "resolved": first.Resolution != nil, "outdated": false, "comments": comments}
		if line := first.line(); line > 0 {
			j["line"] = line
		}
		threads = append(threads, j)
	}
	return threads, answers
}
