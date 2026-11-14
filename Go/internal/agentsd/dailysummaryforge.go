package agentsd

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The daily summary's facts from GitHub (#3720), read with the person's gh for the
// repositories of the folders here: what waits on the person there, and the outcomes that
// landed (pull requests merged, issues and epics closed, releases published). A session that
// made one of them goes under its line as its link, not as a line of its own.

const (
	// approvalLabel is the label of a pull request that waits for the person's approval.
	approvalLabel = "needs-approval"
	// otherSessionLines is the most sessions with no outcome that "Landed" lists: the rest is a count.
	otherSessionLines = 10
)

// The starts of the lines about one item on GitHub: the same item from a checkout on two
// machines is one line, by its link.
const (
	pullLine     = "Pull request merged at "
	epicLine     = "Epic closed at "
	issueLine    = "Issue closed at "
	releaseLine  = "Release published at "
	assignedLine = "Issue assigned to you: "
	reviewLine   = "Review asked of you: "
	approvalLine = "Approval asked of you: "
)

var forgeStarts = []string{pullLine, epicLine, issueLine, releaseLine, assignedLine, reviewLine, approvalLine}

// forgeKey is the link of a line about one item on GitHub, the last word of its first line;
// "" for any other line.
func forgeKey(line string) string {
	first, _, _ := strings.Cut(line, "\n")
	for _, s := range forgeStarts {
		if strings.HasPrefix(first, s) {
			if f := strings.Fields(first); len(f) > 0 {
				return f[len(f)-1]
			}
		}
	}
	return ""
}

// summaryRepo is one GitHub repository and the folders here that are checkouts of it.
type summaryRepo struct {
	name, url string
	folders   []string
}

// summaryRepos is the repositories of folders, as gh names them; a folder that is no
// checkout of one, or that gh cannot read, is left out.
func (d *Daemon) summaryRepos(gh string, folders []string) []summaryRepo {
	folders = slices.Clone(folders)
	sort.Strings(folders)
	var out []summaryRepo
	at := map[string]int{}
	for _, f := range folders {
		if _, err := os.Stat(filepath.Join(f, ".git")); err != nil || !pushesToForge(f) {
			continue
		}
		var repo struct {
			NameWithOwner string `json:"nameWithOwner"`
			URL           string `json:"url"`
		}
		if ghJSON(d.ctx, gh, f, &repo, "repo", "view", "--json", "nameWithOwner,url") != nil || repo.NameWithOwner == "" {
			continue
		}
		if i, ok := at[repo.NameWithOwner]; ok {
			out[i].folders = append(out[i].folders, f)
			continue
		}
		at[repo.NameWithOwner] = len(out)
		out = append(out, summaryRepo{name: repo.NameWithOwner, url: repo.URL, folders: []string{f}})
	}
	return out
}

// forgeItem is one issue or pull request that gh search names.
type forgeItem struct {
	Number     int       `json:"number"`
	Title      string    `json:"title"`
	URL        string    `json:"url"`
	CreatedAt  time.Time `json:"createdAt"`
	Repository struct {
		NameWithOwner string `json:"nameWithOwner"`
	} `json:"repository"`
}

// forgeWaits is what waits on the person on GitHub, oldest first: the open issues assigned
// to them, the pull requests whose review is asked of them, and the open pull requests
// labelled needs-approval. A pull request asked both ways is one line.
func (d *Daemon) forgeWaits(gh string, repos []summaryRepo) []string {
	if len(repos) == 0 {
		return nil
	}
	in := []string{"--state", "open", "--limit", "100", "--json", "number,title,url,createdAt,repository"}
	for _, r := range repos {
		in = append(in, "--repo", r.name)
	}
	type waiting struct {
		at   time.Time
		line string
	}
	var out []waiting
	seen := map[string]bool{}
	for _, ask := range []struct {
		start string
		args  []string
	}{
		{approvalLine, []string{"search", "prs", "--label", approvalLabel}},
		{reviewLine, []string{"search", "prs", "--review-requested", "@me"}},
		{assignedLine, []string{"search", "issues", "--assignee", "@me"}},
	} {
		var items []forgeItem
		if ghJSON(d.ctx, gh, repos[0].folders[0], &items, append(ask.args, in...)...) != nil {
			continue
		}
		for _, it := range items {
			if seen[it.URL] {
				continue
			}
			seen[it.URL] = true
			out = append(out, waiting{it.CreatedAt, fmt.Sprintf("%s#%d %q in %s, since %s. %s", ask.start, it.Number, it.Title,
				it.Repository.NameWithOwner, summaryClock(it.CreatedAt), it.URL)})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].at.Before(out[j].at) })
	lines := make([]string, len(out))
	for i, w := range out {
		lines[i] = w.line
	}
	return lines
}

// forgeOutcome is one thing that landed on GitHub, and what makes a session its own: a
// label such as "P#12" or "#12", or the pull request's branch.
type forgeOutcome struct {
	at            time.Time
	line          string
	repo          *summaryRepo
	label, branch string
	sessions      []string
}

// forgeOutcomes is what landed in repos since: epics closed, then pull requests merged,
// issues closed and releases published, each oldest first, with the sessions in its
// folders that made it under it. used is those sessions.
func (d *Daemon) forgeOutcomes(gh string, repos []summaryRepo, since time.Time, sessions []*wire.Agent) (lines []string, used map[wire.UUID]bool) {
	day := dayStamp(since)
	var epics, pulls, issues, releases []*forgeOutcome
	for i := range repos {
		r := &repos[i]
		f := r.folders[0]
		if found, err := mergedPullRequests(d.ctx, gh, f, day); err == nil {
			for _, p := range found {
				if !p.MergedAt.Before(since) {
					pulls = append(pulls, &forgeOutcome{at: p.MergedAt, repo: r, label: fmt.Sprintf("P#%d", p.Number), branch: p.HeadRefName,
						line: fmt.Sprintf("%s%s: #%d %q in %s. %s", pullLine, summaryClock(p.MergedAt), p.Number, p.Title, r.name, p.URL)})
				}
			}
		}
		var closed []struct {
			Number      int       `json:"number"`
			Title       string    `json:"title"`
			URL         string    `json:"url"`
			ClosedAt    time.Time `json:"closedAt"`
			StateReason string    `json:"stateReason"`
			Labels      []struct {
				Name string `json:"name"`
			} `json:"labels"`
		}
		if ghJSON(d.ctx, gh, f, &closed, "issue", "list", "--state", "closed", "--search", "closed:>="+day,
			"--limit", "200", "--json", "number,title,url,closedAt,stateReason,labels") == nil {
			for _, c := range closed {
				// Not planned or a duplicate is no outcome.
				if c.ClosedAt.Before(since) || c.StateReason != "" && c.StateReason != "COMPLETED" {
					continue
				}
				start, list := issueLine, &issues
				if slices.ContainsFunc(c.Labels, func(l struct {
					Name string `json:"name"`
				}) bool {
					return l.Name == "epic"
				}) {
					start, list = epicLine, &epics
				}
				*list = append(*list, &forgeOutcome{at: c.ClosedAt, repo: r, label: fmt.Sprintf("#%d", c.Number),
					line: fmt.Sprintf("%s%s: #%d %q in %s. %s", start, summaryClock(c.ClosedAt), c.Number, c.Title, r.name, c.URL)})
			}
		}
		var published []struct {
			TagName     string    `json:"tagName"`
			Name        string    `json:"name"`
			PublishedAt time.Time `json:"publishedAt"`
		}
		if ghJSON(d.ctx, gh, f, &published, "release", "list", "--exclude-drafts", "--limit", "20",
			"--json", "tagName,name,publishedAt") == nil {
			for _, p := range published {
				if p.PublishedAt.Before(since) || r.url == "" {
					continue
				}
				name := p.TagName
				if p.Name != "" && p.Name != p.TagName {
					name += fmt.Sprintf(" %q", p.Name)
				}
				releases = append(releases, &forgeOutcome{at: p.PublishedAt, repo: r,
					line: fmt.Sprintf("%s%s: %s in %s. %s/releases/tag/%s", releaseLine, summaryClock(p.PublishedAt), name, r.name, r.url, url.PathEscape(p.TagName))})
			}
		}
	}
	used = map[wire.UUID]bool{}
	// A session goes under a pull request first, then an issue: one line each.
	for _, list := range [][]*forgeOutcome{pulls, epics, issues} {
		for _, o := range list {
			for _, a := range sessions {
				if used[a.ID] || !slices.Contains(o.repo.folders, filepath.Clean(folderPath(a))) {
					continue
				}
				branch := a.Worktree != nil && a.Worktree.Branch != nil && o.branch != "" && *a.Worktree.Branch == o.branch
				if branch || slices.ContainsFunc(a.Labels, func(l wire.SessionLabel) bool { return l.Value == o.label }) {
					used[a.ID] = true
					o.sessions = append(o.sessions, fmt.Sprintf("session %q: %s", agentTitle(a), sessionLink(a.ID)))
				}
			}
		}
	}
	for _, list := range [][]*forgeOutcome{epics, pulls, issues, releases} {
		sort.SliceStable(list, func(i, j int) bool { return list[i].at.Before(list[j].at) })
		for _, o := range list {
			lines = append(lines, o.line+subLines(o.sessions))
		}
	}
	return lines, used
}

// subLines is lines under an item's line, indented under its "- ".
func subLines(lines []string) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString("\n  - " + l)
	}
	return b.String()
}

// personLine is the facts' first line, about the person: how many things wait on them, and
// the outcomes that landed, such as "3 things wait on you. 12 pull requests merged, 2 epics
// closed."
func personLine(waiting, landed []string) string {
	waits := 0
	for _, l := range waiting {
		if !strings.HasPrefix(l, "and ") {
			waits++
		}
	}
	var b strings.Builder
	switch waits {
	case 0:
		b.WriteString("Nothing waits on you.")
	case 1:
		b.WriteString("1 thing waits on you.")
	default:
		fmt.Fprintf(&b, "%d things wait on you.", waits)
	}
	var said []string
	for _, kind := range []struct{ start, one, many string }{
		{pullLine, "pull request merged", "pull requests merged"},
		{epicLine, "epic closed", "epics closed"},
		{issueLine, "issue closed", "issues closed"},
		{releaseLine, "release published", "releases published"},
	} {
		n := 0
		for _, l := range landed {
			if strings.HasPrefix(l, kind.start) {
				n++
			}
		}
		switch {
		case n == 1:
			said = append(said, "1 "+kind.one)
		case n > 1:
			said = append(said, fmt.Sprintf("%d %s", n, kind.many))
		}
	}
	if len(said) > 0 {
		b.WriteString(" " + strings.Join(said, ", ") + ".")
	}
	return b.String()
}
