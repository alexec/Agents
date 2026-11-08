package agentsd

import (
	"context"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A session search for #<n> (#3899): the sessions on issue n, on its sub-issues (the issues
// part-of it, #3582) and on the PRs that fix them, from the links lineage already has. It goes
// along those links only, one way, so a session's other issues do not come in, as a walk's would.

// mostSubIssues bounds the sub-issues one search reads, as Lineage's epic plan does.
const mostSubIssues = 100

// issueToken is a search's #<n> or issue:#<n> (issue:<n> too), as a word of its own.
var issueToken = regexp.MustCompile(`(?i)(?:^|\s)(?:issue:)?#([0-9]{1,9})(?:\s|$)|(?:^|\s)issue:([0-9]{1,9})(?:\s|$)`)

// issueNumberIn is the issue a search names, or 0.
func issueNumberIn(query string) int {
	m := issueToken.FindStringSubmatch(query)
	if m == nil {
		return 0
	}
	n, _ := strconv.Atoi(m[1] + m[2])
	return n
}

func (d *Daemon) registerLineageSessions() {
	On(d, wire.CallLineageSessions, func(_ context.Context, _ *Client, r wire.LineageSessionsRequest) (wire.LineageSessions, error) {
		if r.Number <= 0 {
			return wire.LineageSessions{}, Invalid("lineage/sessions: an issue number is 1 or more")
		}
		return d.sessionsOnIssue(int(r.Number)), nil
	})
}

// issueNodes is #n in the forge repo of each of this machine's folders, each once.
func (d *Daemon) issueNodes(n int) []wire.LineageNode {
	seen := map[forgeRepo]bool{}
	var out []wire.LineageNode
	for _, p := range d.Store.Folders() {
		r := d.folderRepo(store.FolderPath(p.Folder))
		if r.forge == "" || seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, r.issue(n))
	}
	return out
}

// sessionsOnIssue is lineage/sessions. Ended links count: a session that worked on an issue
// stays one of its sessions, as the cost rollup counts it.
func (d *Daemon) sessionsOnIssue(n int) wire.LineageSessions {
	out := wire.LineageSessions{Matches: []wire.LineageSessionMatch{}}
	limited := false
	seen := map[string]bool{}
	add := func(session wire.LineageNode, on wire.LineageNode) {
		id, ok := strings.CutPrefix(session.Ref, "session:")
		if !ok || seen[id] {
			return
		}
		if len(out.Matches) >= lineage.MostAnswer {
			limited = true
			return
		}
		seen[id] = true
		out.Matches = append(out.Matches, wire.LineageSessionMatch{AgentID: wire.UUID(id), On: on})
	}
	graph := d.lineage()
	for _, root := range d.issueNodes(n) {
		issues := []wire.LineageNode{root}
		for _, l := range graph.Links(root).Links {
			if l.To == root && l.Rel == lineage.RelPartOf && l.From.Kind == lineage.KindIssue {
				if len(issues) > mostSubIssues {
					limited = true
					break
				}
				issues = append(issues, l.From)
			}
		}
		for _, issue := range issues {
			var prs []wire.LineageNode
			for _, l := range graph.Links(issue).Links {
				switch {
				case l.To != issue:
				case l.From.Kind == lineage.KindSession && worksOnIt(l.Rel):
					add(l.From, issue)
				case l.From.Kind == lineage.KindPR && (l.Rel == lineage.RelFixes || l.Rel == lineage.RelCloses):
					prs = append(prs, l.From)
				}
			}
			for _, pr := range prs {
				for _, l := range graph.Links(pr).Links {
					if l.To == pr && l.From.Kind == lineage.KindSession && worksOnIt(l.Rel) {
						add(l.From, issue)
					}
				}
			}
		}
	}
	if limited {
		out.Limited = &limited
	}
	return out
}

// worksOnIt says a session's link to an issue or a PR is work on it.
func worksOnIt(rel string) bool {
	return rel == lineage.RelWorksOn || rel == lineage.RelOpens || rel == lineage.RelReviews
}

// issueSearch is a search that names an issue (#3899): the sessions on it, as lineage/sessions
// finds them, and those with its #<n> label or #<n> in their title. agents/list sends them all,
// archived ones too, and leaves the rest of the words to the client, as it does for label:.
type issueSearch struct {
	label string
	on    map[wire.UUID]bool
}

// issueSearchOf is the issue search a query asks for, or nil when it names no issue.
func (d *Daemon) issueSearchOf(query string) *issueSearch {
	n := issueNumberIn(query)
	if n == 0 {
		return nil
	}
	s := &issueSearch{label: "#" + strconv.Itoa(n), on: map[wire.UUID]bool{}}
	for _, m := range d.sessionsOnIssue(n).Matches {
		s.on[m.AgentID] = true
	}
	return s
}

func (s *issueSearch) matches(a wire.Agent) bool {
	return s.on[a.ID] || a.Title != nil && namesIssue(*a.Title, s.label) ||
		slices.ContainsFunc(a.Labels, func(l wire.SessionLabel) bool { return strings.TrimSpace(l.Value) == s.label })
}

// namesIssue says text holds #<n> as a number of its own: #38 is not in "#3899".
func namesIssue(text, label string) bool {
	for i := strings.Index(text, label); i >= 0; {
		end := i + len(label)
		if end == len(text) || text[end] < '0' || text[end] > '9' {
			return true
		}
		next := strings.Index(text[end:], label)
		if next < 0 {
			break
		}
		i = end + next
	}
	return false
}
