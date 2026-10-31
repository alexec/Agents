package agentsd

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The Lineage section of the Issues and PR pages (#2941): the sessions that worked on an
// issue or a pull request, and on its pull requests, with what each cost. The github, gitlab
// and linear servers have no way to the host's record, so the host answers a view's
// tools/call of lineageViewTool itself, with lineage/walk and lineage/cost, and never passes
// it on. Only a view of one of those three servers may ask: the record names the person's
// sessions and what they spent.

const (
	lineageViewTool = "agents_lineage"
	// lineageViewSessions bounds the sessions one answer names.
	lineageViewSessions = 100
)

// lineageViewServers is the servers whose views may ask, by their mcpcatalog id.
var lineageViewServers = map[string]bool{"agents/github": true, "agents/gitlab": true, "agents/linear": true}

type lineageView struct {
	// Ref is the node, as lineage refs name it: github:owner/repo#12.
	Ref string `json:"ref"`
	// Summary is "3 sessions · 2 pull requests (1 merged, 1 waste)", or that nothing is linked.
	Summary string `json:"summary"`
	// Total is what was banked on it, its pull requests' too for an issue; "" with nothing.
	Total    string               `json:"total,omitempty"`
	Waste    string               `json:"waste,omitempty"`
	Sessions []lineageViewSession `json:"sessions"`
	// PRs is an issue's pull requests; Issues is a pull request's issues.
	PRs     []lineageViewNode `json:"prs"`
	Issues  []lineageViewNode `json:"issues"`
	Limited bool              `json:"limited,omitempty"`
}

type lineageViewSession struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	// How is "works on it", "opened #12", "reviews #12" or "a helper of “title”".
	How string `json:"how"`
	// Words is the session's own: "$1.20 · 45.0k tokens · 2h 5m · archived".
	Words string `json:"words,omitempty"`
}

type lineageViewNode struct {
	Ref  string `json:"ref"`
	Name string `json:"name"`
	URL  string `json:"url,omitempty"`
	// Outcome is open, merged, closed or reverted (a pull request), or "" (an issue).
	Outcome string `json:"outcome,omitempty"`
	Waste   bool   `json:"waste,omitempty"`
	Words   string `json:"words,omitempty"`
}

// mayAskLineage says a view of s may call lineageViewTool.
func mayAskLineage(s viewServer) bool {
	o, ok := oursForServer(s)
	return ok && lineageViewServers[o.ID]
}

// lineageViewResult is the tools/call result a view of s gets for lineageViewTool.
func (d *Daemon) lineageViewResult(s viewServer, args json.RawMessage) (wire.JSONValue, error) {
	if !mayAskLineage(s) {
		return nil, viewRefused("A view may not call " + lineageViewTool + ".")
	}
	var a struct {
		URL string `json:"url"`
	}
	_ = json.Unmarshal(args, &a)
	node, base, ok := nodeOfURL(a.URL)
	if !ok {
		return toolError("No issue or pull request at " + strconv.Quote(a.URL) + ".")
	}
	v := d.lineageViewOf(node, base)
	text, _ := json.Marshal(v)
	return json.Marshal(map[string]any{
		"content":           []map[string]string{{"type": "text", "text": string(text)}},
		"structuredContent": v,
	})
}

func toolError(words string) (wire.JSONValue, error) {
	return json.Marshal(map[string]any{"content": []map[string]string{{"type": "text", "text": words}}, "isError": true})
}

// nodeOfURL is the issue or pull request at a web address, and the address's scheme and host
// (for the links to its pull requests on a GitLab of its own): github.com/o/r/issues/5,
// <gitlab>/group/project/-/issues/5, linear.app/<team>/issue/ENG-4/..., or a pull request's.
func nodeOfURL(raw string) (wire.LineageNode, string, bool) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return wire.LineageNode{}, "", false
	}
	base := u.Scheme + "://" + u.Host
	if repo, n, ok := prOfURL(raw); ok {
		return repo.pr(n), base, true
	}
	path := strings.Trim(u.Path, "/")
	if strings.EqualFold(u.Host, "linear.app") {
		parts := strings.Split(path, "/")
		if len(parts) >= 3 && parts[1] == "issue" && linearLabel.MatchString(strings.ToUpper(parts[2])) {
			return wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + strings.ToUpper(parts[2])}, base, true
		}
		return wire.LineageNode{}, "", false
	}
	for _, sep := range []string{"/-/issues/", "/issues/"} {
		if repo, num, ok := strings.Cut(path, sep); ok {
			n, err := strconv.Atoi(strings.SplitN(num, "/", 2)[0])
			r := forgeOf(u.Host, repo)
			if err != nil || n <= 0 || r.forge == "" || (sep == "/issues/") != (r.forge == "github") {
				return wire.LineageNode{}, "", false
			}
			return r.issue(n), base, true
		}
	}
	return wire.LineageNode{}, "", false
}

// lineageViewOf is node's section: the walk for who worked on it, the rollup for the cost.
func (d *Daemon) lineageViewOf(node wire.LineageNode, base string) lineageView {
	cost := d.lineageCost(node)
	g := d.lineage().Walk(node, lineage.MostDepth)
	v := lineageView{Ref: node.Ref, Sessions: []lineageViewSession{}, PRs: []lineageViewNode{}, Issues: []lineageViewNode{},
		Limited: g.Limited != nil && *g.Limited}

	parts := map[wire.LineageNode]wire.LineageCostNode{}
	for _, p := range cost.Parts {
		parts[p.Node] = p
	}
	// What it is linked to: an issue's pull requests, a pull request's issues.
	work := map[wire.LineageNode]bool{node: true}
	for _, l := range g.Links {
		if l.Rel != lineage.RelFixes {
			continue
		}
		switch {
		case node.Kind == lineage.KindIssue && l.To == node && l.From.Kind == lineage.KindPR && !work[l.From]:
			work[l.From] = true
			v.PRs = append(v.PRs, d.lineageViewNodeOf(l.From, node, base, parts))
		case node.Kind == lineage.KindPR && l.From == node && l.To.Kind == lineage.KindIssue && !work[l.To]:
			work[l.To] = true
			v.Issues = append(v.Issues, d.lineageViewNodeOf(l.To, node, base, nil))
		}
	}

	// The sessions on it, or on its pull requests, then the helpers they started. The walk's
	// links are newest first, so the newest session comes first.
	seen := map[wire.LineageNode]bool{}
	add := func(s wire.LineageNode, how string) {
		if seen[s] {
			return
		}
		seen[s] = true
		if len(v.Sessions) >= lineageViewSessions {
			v.Limited = true
			return
		}
		v.Sessions = append(v.Sessions, d.lineageViewSessionOf(s, how))
	}
	for _, l := range g.Links {
		if l.From.Kind != lineage.KindSession || !work[l.To] || l.To.Kind == lineage.KindIssue && l.To != node {
			continue
		}
		add(l.From, lineageHow(l, node))
	}
	for range lineage.MostDepth {
		before := len(seen)
		for _, l := range g.Links {
			if l.Rel == lineage.RelStarted && seen[l.From] && l.To.Kind == lineage.KindSession {
				add(l.To, "a helper of "+d.lineageSessionTitle(l.From))
			}
		}
		if len(seen) == before {
			break
		}
	}

	v.Summary = lineageViewSummary(node, len(seen), v.PRs)
	if !lineageCostZero(cost.Total) {
		v.Total = lineageCostLine(cost.Total)
	}
	if !lineageCostZero(cost.Waste) {
		v.Waste = "Waste: " + lineageCostLine(cost.Waste)
	}
	return v
}

// lineageHow is how a session's link l to the page's node, or to one of its pull requests, reads.
func lineageHow(l wire.LineageLink, node wire.LineageNode) string {
	it := "it"
	if l.To != node {
		it = refName(l.To.Ref, node.Ref)
	}
	switch l.Rel {
	case lineage.RelOpens:
		return "opened " + it
	case lineage.RelReviews:
		return "reviews " + it
	}
	return "works on " + it
}

func (d *Daemon) lineageViewNodeOf(n, page wire.LineageNode, base string, parts map[wire.LineageNode]wire.LineageCostNode) lineageViewNode {
	out := lineageViewNode{Ref: n.Ref, Name: refName(n.Ref, page.Ref), URL: refURL(n, base)}
	if n.Kind != lineage.KindPR {
		return out
	}
	out.Outcome = "open"
	if p, ok := parts[n]; ok {
		if p.Outcome != nil {
			out.Outcome = *p.Outcome
		}
		out.Waste = lineage.Wasted(p)
		if !lineageCostZero(p.Banked) {
			out.Words = lineageCostLine(p.Banked)
		}
	}
	return out
}

func (d *Daemon) lineageSessionTitle(s wire.LineageNode) string {
	id, _ := strings.CutPrefix(s.Ref, "session:")
	if a := d.Store.Agent(wire.UUID(id)); a != nil {
		return agentName(a.Title)
	}
	return "a session no longer here"
}

func (d *Daemon) lineageViewSessionOf(s wire.LineageNode, how string) lineageViewSession {
	id, _ := strings.CutPrefix(s.Ref, "session:")
	out := lineageViewSession{ID: id, Title: "A session no longer here", How: how}
	a := d.Store.Agent(wire.UUID(id))
	if a == nil {
		return out
	}
	out.Title = "Untitled session"
	if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
		out.Title = strings.TrimSpace(*a.Title)
	}
	var words []string
	if len(a.CostToDate) > 0 {
		words = append(words, amountsWords(a.CostToDate))
	}
	if a.TokensToDate != nil && *a.TokensToDate > 0 {
		words = append(words, tokenWords(*a.TokensToDate)+" tokens")
	}
	if span := a.LastActivityAt.Time().Sub(a.CreatedAt.Time()); span >= time.Second {
		words = append(words, durationWords(span.Seconds()))
	}
	if a.ArchivedAt != nil {
		words = append(words, "archived")
	}
	out.Words = strings.Join(words, " · ")
	return out
}

// lineageViewSummary is "3 sessions · 2 pull requests (1 merged, 1 waste)".
func lineageViewSummary(node wire.LineageNode, sessions int, prs []lineageViewNode) string {
	if sessions == 0 && len(prs) == 0 {
		return "No session has worked on it yet."
	}
	words := []string{plural(sessions, "session", "sessions")}
	if node.Kind == lineage.KindIssue {
		var merged, waste, open int
		for _, p := range prs {
			switch {
			case p.Waste:
				waste++
			case p.Outcome == lineage.OutcomeMerged:
				merged++
			default:
				open++
			}
		}
		pr := plural(len(prs), "pull request", "pull requests")
		var ends []string
		for _, e := range []struct {
			n    int
			word string
		}{{merged, "merged"}, {open, "open"}, {waste, "waste"}} {
			if e.n > 0 {
				ends = append(ends, fmt.Sprintf("%d %s", e.n, e.word))
			}
		}
		if len(ends) > 0 {
			pr += " (" + strings.Join(ends, ", ") + ")"
		}
		words = append(words, pr)
	}
	return strings.Join(words, " · ")
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// lineageCostLine is "$4.00 · 120.0k in, 30.0k out · 12m agent time".
func lineageCostLine(c wire.LineageCost) string {
	return amountsWords(c.Cost) + " · " + tokenWords(c.InputTokens) + " in, " + tokenWords(c.OutputTokens) + " out · " +
		durationWords(c.WorkingSeconds) + " agent time"
}

func lineageCostZero(c wire.LineageCost) bool {
	for _, v := range c.Cost {
		if v != 0 {
			return false
		}
	}
	return c.InputTokens == 0 && c.OutputTokens == 0 && c.WorkingSeconds == 0
}

// refName is a node as the page names it: #7 or !4 in the page's own repo, owner/repo#7 in
// another, ENG-4 on Linear.
func refName(ref, page string) string {
	if rest, ok := strings.CutPrefix(ref, "linear:"); ok {
		return rest
	}
	return shortRef(ref, page)
}

// refURL is a node's web address: GitHub's, or a GitLab's on the page's own host. Linear's
// pull requests are on GitHub or GitLab; its issues have none here.
func refURL(n wire.LineageNode, base string) string {
	scheme, id, _ := strings.Cut(n.Ref, ":")
	i := strings.LastIndexAny(id, "#!")
	if i <= 0 {
		return ""
	}
	path, num := id[:i], id[i+1:]
	switch scheme {
	case "github":
		if n.Kind == lineage.KindPR {
			return "https://github.com/" + path + "/pull/" + num
		}
		return "https://github.com/" + path + "/issues/" + num
	case "gitlab":
		if base == "" || strings.EqualFold(base, "https://linear.app") {
			base = "https://gitlab.com"
		}
		if n.Kind == lineage.KindPR {
			return base + "/" + path + "/-/merge_requests/" + num
		}
		return base + "/" + path + "/-/issues/" + num
	}
	return ""
}
