package azuredevopsmcp

import (
	"context"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// What the views read on Azure DevOps (#4098), in the forgejo server's shapes
// (Go/internal/forgejomcp/pages.go), so a page is drawn the same way: the active pull requests
// and one pull request's page. As the person, with the same token as the events. A pull
// request's diff is PRDiff (forgewrite.go), which the Work pages read too.

// The list's sections for a team (#2952, specs/2453-team-lists.md), as the azureboards server
// has them (Go/internal/azureboardsmcp/views.go): each active pull request is in one, by how it
// relates to the viewer, the token's owner. An organization has only its own members and its
// bots, so with no control-plane people (#2951) every pull request that is not the viewer's is
// Team; with them, Team is the people and bots on the control plane, by their Azure DevOps
// login (#3853). The page draws them in this order and leaves an empty one out.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// boardSize is the most pull requests the list shows; boardReads is how many pull requests'
// checks it reads at once.
const (
	boardSize  = 50
	boardReads = 4
)

// teamMeta is the control plane's people and bots, by Azure DevOps login lowercased (#2951,
// #3853), read from the call's _meta, which the host fills in. Empty with no control plane, or
// a host that gives no Azure DevOps logins.
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
		login, _ := row["azuredevops"].(string)
		if login == "" {
			continue
		}
		name, _ := row["name"].(string)
		bot, _ := row["bot"].(bool)
		out[strings.ToLower(login)] = teamPerson{Name: name, Bot: bot}
	}
	return out
}

// of is the control-plane person who is i. An Azure DevOps login is the sign-in email or the
// display name (the connection's own is the display name), so either matches, and the
// identity's id too.
func (t teamMeta) of(i identity) (teamPerson, bool) {
	for _, login := range []string{i.UniqueName, i.DisplayName, i.ID} {
		if login == "" {
			continue
		}
		if tp, on := t[strings.ToLower(login)]; on {
			return tp, true
		}
	}
	return teamPerson{}, false
}

// agentOnOf reads _meta's agentOnPR (#2951): who is on that number, or "".
func agentOnOf(meta mcp.Meta, number int) string {
	m, ok := meta["agentOnPR"].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m[strconv.Itoa(number)].(string)
	return who
}

// named puts the control plane's name for the author on a row, and whether they are a bot.
func named(j map[string]any, author identity, people teamMeta) {
	if isBot(author) {
		j["authorBot"] = true
	}
	if tp, on := people.of(author); on {
		j["authorName"] = tp.Name
		if tp.Bot {
			j["authorBot"] = true
		}
	}
}

// viewerJSON is the token's owner: their id, and their sign-in name, else their display name.
type viewerJSON struct{ id, name string }

// viewer is the token's owner, from the organization's connectionData, which me reads too.
func (f *RealAzureDevOps) viewer(ctx context.Context, repo string) (viewerJSON, error) {
	org, _, _ := splitRepo(repo)
	var c struct {
		AuthenticatedUser struct {
			ID                  string `json:"id"`
			ProviderDisplayName string `json:"providerDisplayName"`
			Properties          struct {
				Account struct {
					Value string `json:"$value"`
				} `json:"Account"`
			} `json:"properties"`
		} `json:"authenticatedUser"`
	}
	if err := f.get(ctx, url.PathEscape(org)+"/_apis/connectionData", true, &c); err != nil {
		return viewerJSON{}, err
	}
	u := c.AuthenticatedUser
	if u.ID == "" {
		return viewerJSON{}, &AzureDevOpsError{Kind: NotSignedIn, Message: "Azure DevOps did not say whose the token is"}
	}
	name := u.Properties.Account.Value
	if name == "" {
		name = u.ProviderDisplayName
	}
	return viewerJSON{id: u.ID, name: name}, nil
}

func (v viewerJSON) is(i identity) bool { return v.id != "" && strings.EqualFold(i.ID, v.id) }

// MARK: The board

// failedBuild is the id of the first failed Azure Pipelines build among a pull request's
// checks, 0 when none failed or the failed ones are other services' statuses.
func failedBuild(runs []CheckRun) int {
	for _, r := range runs {
		if r.State == "failing" && r.Build != 0 {
			return r.Build
		}
	}
	return 0
}

// asksReview says whether the viewer is one of a pull request's reviewers and has not voted.
func (p forgePullJSON) asksReview(me viewerJSON) bool {
	for _, r := range p.Reviewers {
		if me.is(r.identity) && r.Vote == 0 && !r.HasDeclined {
			return true
		}
	}
	return false
}

// prSection is a pull request's section: Needs you when the viewer is a reviewer who has not
// voted, or when the viewer's own has failing checks, a conflict, or a reviewer who rejected it
// or waits for its author.
func prSection(p forgePullJSON, checks string, me viewerJSON, people teamMeta) string {
	mine := me.is(p.CreatedBy)
	switch {
	case p.asksReview(me):
		return sectionNeedsYou
	case mine && (checks == "failing" || p.MergeStatus == "conflicts" || p.review() == "changes_requested"):
		return sectionNeedsYou
	case mine:
		return sectionYours
	}
	if len(people) > 0 {
		if _, on := people.of(p.CreatedBy); !on {
			return sectionOthers
		}
	}
	return sectionTeam
}

// Board is the active pull requests, newest created first, at most boardSize, each with its
// checks, its conflict, its review and its section for the token's owner (#2952). Azure DevOps
// has no list of many pull requests' builds, so each one's are read, boardReads at a time.
func (f *RealAzureDevOps) Board(ctx context.Context, repo string, meta mcp.Meta) (map[string]any, error) {
	var list struct {
		Value []forgePullJSON `json:"value"`
	}
	q := url.Values{"searchCriteria.status": {"active"}, "$top": {strconv.Itoa(boardSize)}}
	if err := f.get(ctx, api(repoPath(repo)+"/pullrequests", q), false, &list); err != nil {
		return nil, err
	}
	pulls := list.Value
	sort.SliceStable(pulls, func(i, j int) bool { return mcpevents.Before(pulls[j].CreationDate, pulls[i].CreationDate) })
	me, err := f.viewer(ctx, repo)
	if err != nil {
		return nil, err
	}
	runs := make([][]CheckRun, len(pulls))
	errs := make([]error, len(pulls))
	var wg sync.WaitGroup
	gate := make(chan struct{}, boardReads)
	for i, p := range pulls {
		wg.Add(1)
		gate <- struct{}{}
		go func() {
			defer func() { <-gate; wg.Done() }()
			runs[i], errs[i] = f.checkRuns(ctx, repo, p.ID)
		}()
	}
	wg.Wait()
	people := teamMetaOf(meta)
	out := make([]any, len(pulls))
	needsYou := 0
	for i, p := range pulls {
		if errs[i] != nil {
			return nil, errs[i]
		}
		checks := combinedChecks(runs[i])
		j := map[string]any{"number": p.ID, "title": p.Title, "url": f.prURL(repo, p.ID), "branch": branch(p.SourceRefName),
			"base": branch(p.TargetRefName), "author": p.CreatedBy.name(), "updatedAt": mcpevents.Normalized(p.CreationDate), "draft": p.IsDraft,
			"checks": checks, "conflicts": p.MergeStatus == "conflicts", "autoMerge": p.AutoCompleteSetBy != nil, "mine": me.is(p.CreatedBy)}
		if id := failedBuild(runs[i]); id != 0 {
			j["failedRunId"] = id
		}
		if review := p.review(); review != "" {
			j["review"] = review
		}
		named(j, p.CreatedBy, people)
		section := prSection(p, checks, me, people)
		j["section"] = section
		if section == sectionNeedsYou {
			needsYou++
		}
		if section == sectionNeedsYou || section == sectionYours {
			if who := agentOnOf(meta, p.ID); who != "" {
				j["agentOn"] = who
			}
		}
		out[i] = j
	}
	// count and attention, the Needs you count, are the sidebar row's (#2033).
	return map[string]any{"repo": repo, "viewer": me.name, "pullRequests": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: A pull request's page

// noteOf is a comment as the page draws it.
func noteOf(c threadCommentJSON, url string) map[string]any {
	return map[string]any{"author": c.Author.name(), "bot": isBot(c.Author), "body": c.Content, "at": mcpevents.Normalized(c.PublishedDate),
		"url": url, "id": c.ID}
}

// said says whether a comment is a person's words: not deleted, not Azure DevOps's own (a
// vote, a push), and not empty.
func said(c threadCommentJSON) bool {
	return !c.IsDeleted && c.CommentType != "system" && strings.TrimSpace(c.Content) != ""
}

// PRPage is one pull request as its page draws it: the forgejo server's pull request page,
// with its builds and statuses as its checks and its threads on lines as its line comments.
func (f *RealAzureDevOps) PRPage(ctx context.Context, repo string, number int) (map[string]any, error) {
	var p forgePullJSON
	if err := f.get(ctx, api(fmt.Sprintf("%s/pullrequests/%d", repoPath(repo), number), nil), false, &p); err != nil {
		return nil, err
	}
	me, err := f.viewer(ctx, repo)
	if err != nil {
		return nil, err
	}
	threads, err := f.threads(ctx, repo, number, false)
	if err != nil {
		return nil, err
	}
	conversation, lines := []any{}, []any{}
	for _, t := range threads {
		if t.IsDeleted {
			continue
		}
		link := fmt.Sprintf("%s?discussionId=%d", f.prURL(repo, number), t.ID)
		var notes []any
		for _, c := range t.Comments {
			if said(c) {
				notes = append(notes, noteOf(c, link))
			}
		}
		switch {
		case len(notes) == 0:
		case t.onALine():
			lines = append(lines, map[string]any{"path": t.path(), "line": t.line(), "resolved": t.resolved(), "outdated": false,
				"comments": notes})
		default:
			conversation = append(conversation, notes...)
		}
	}
	sort.SliceStable(conversation, func(i, j int) bool {
		return mcpevents.Before(conversation[i].(map[string]any)["at"].(string), conversation[j].(map[string]any)["at"].(string))
	})
	checkRuns, err := f.checkRuns(ctx, repo, number)
	if err != nil {
		return nil, err
	}
	runs := []any{}
	for _, c := range checkRuns {
		run := map[string]any{"name": c.Name, "state": c.State, "url": c.URL}
		if c.Build != 0 {
			run["runId"] = c.Build
		}
		runs = append(runs, run)
	}
	files := []any{}
	cut := false
	last, err := f.newestIteration(ctx, repo, number)
	if err != nil {
		return nil, err
	}
	if last.ID > 0 {
		changed, err := f.changes(ctx, repo, number, last.ID)
		if err != nil {
			return nil, err
		}
		// Azure DevOps says no file's lines added and removed, only how it changed.
		for _, c := range changed {
			files = append(files, map[string]any{"path": strings.TrimPrefix(c.Item.Path, "/"), "change": changeOf(c)})
		}
		cut = len(changed) >= maxChanges
	}
	st := map[string]string{"active": "open", "completed": "merged"}[p.Status]
	if st == "" {
		st = "closed"
	}
	squash := false
	if methods, err := f.MergeMethods(ctx, repo, number); err == nil && len(methods) > 0 {
		squash = methods[0] == "squash"
	}
	checks := combinedChecks(checkRuns)
	page := map[string]any{
		"repo": repo, "number": p.ID, "title": p.Title, "url": f.prURL(repo, p.ID), "branch": branch(p.SourceRefName),
		"base": branch(p.TargetRefName), "author": p.CreatedBy.name(), "state": st, "draft": p.IsDraft, "body": p.Description,
		"createdAt": mcpevents.Normalized(p.CreationDate), "checks": checks, "squash": squash, "autoMerge": p.AutoCompleteSetBy != nil,
		"checkRuns": runs, "files": files, "filesTotal": len(files), "filesCut": cut, "comments": conversation, "threads": lines,
		"viewer": me.name, "mine": me.is(p.CreatedBy), "fromFork": p.fork(), "headSha": p.head(),
	}
	if id := failedBuild(checkRuns); id != 0 {
		page["failedRunId"] = id
	}
	if st == "open" {
		page["conflicts"] = p.MergeStatus == "conflicts"
	}
	if review := p.review(); review != "" {
		page["review"] = review
	}
	return page, nil
}
