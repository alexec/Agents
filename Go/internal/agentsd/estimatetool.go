package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// estimate_issue (#3590): the app's tool over lineage/estimate (#3559), so an agent can say
// what an issue or an epic will probably cost and take, and once it is closed, its estimate
// against what it took (#3561), as Work's page says it. The lead says that line when it closes
// an epic; the Product Owner can say the estimate when it files one. It only reads.

// estimateToolTimeout bounds one call: the forge's plan, then the store.
const estimateToolTimeout = 60 * time.Second

// issueNumberRef is "7", "#7", "owner/repo#7", or GitLab's "group/sub/repo#7".
var issueNumberRef = regexp.MustCompile(`^(?:([\w.-]+(?:/[\w.-]+)+))?#?(\d+)$`)

// estimateNode is the issue an agent names: a ref (github:owner/repo#7, linear:ENG-4,
// jira:KEY-1), owner/repo#7, or a number in its own folder's repo.
func (d *Daemon) estimateNode(caller wire.UUID, issue string) (wire.LineageNode, error) {
	issue = strings.TrimSpace(issue)
	if issue == "" {
		return wire.LineageNode{}, Invalid("Nothing estimated: give the issue or epic, such as #12, in issue.")
	}
	for _, forge := range []string{"github:", "gitlab:", "linear:", "jira:", "azureboards:"} {
		if strings.HasPrefix(issue, forge) {
			return wire.LineageNode{Kind: lineage.KindIssue, Ref: issue}, nil
		}
	}
	m := issueNumberRef.FindStringSubmatch(issue)
	if m == nil {
		return wire.LineageNode{}, Invalid("Nothing estimated: %q is not an issue. Give #12, owner/repo#12, or a ref such as github:owner/repo#12.", issue)
	}
	n, _ := strconv.Atoi(m[2])
	a := d.Store.Agent(caller)
	if a == nil {
		return wire.LineageNode{}, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was estimated."}
	}
	repo := d.folderRepo(folderPath(a))
	if m[1] != "" {
		repo.path = m[1]
	}
	if repo.forge == "" {
		return wire.LineageNode{}, Invalid("Nothing estimated: this folder's repo is not on GitHub, GitLab or Forgejo. Give a ref such as linear:ENG-4.")
	}
	return repo.issue(n), nil
}

// estimateIssueTool is estimate_issue.
func (d *Daemon) estimateIssueTool(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	node, err := d.estimateNode(caller, argString(args, "issue"))
	if err != nil {
		return "", err
	}
	// The plan read fresh, not the minute's copy: a lead asks just after it closes the epic.
	key, _ := json.Marshal([]any{"forge/plan", node.Ref})
	d.forgeMu.Lock()
	delete(d.forgeCache, string(key))
	d.forgeMu.Unlock()
	ctx, cancel := context.WithTimeout(d.ctx, estimateToolTimeout)
	defer cancel()
	e, err := d.lineageEstimate(ctx, wire.LineageEstimateRequest{Node: node})
	if err != nil {
		return "", toolWords(err, "forge/plan: ")
	}
	return estimateWords(e), nil
}

// estimateWords is an estimate as the agent reads it: the figures, what an epic spent, and once
// closed the line "Estimated $X, Zh of work; actual $A, Hh of work" to say as it is.
func estimateWords(e wire.LineageEstimate) string {
	var b strings.Builder
	head := e.Node.Ref
	if e.Level != nil {
		head += " (" + *e.Level + ")"
	}
	fmt.Fprintf(&b, "%s\n", head)
	if e.OpenChildren != nil || e.ClosedChildren != nil {
		fmt.Fprintf(&b, "Children: %d open, %d closed.\n", countOf(e.OpenChildren), countOf(e.ClosedChildren))
	}
	if e.Actual != nil {
		if line := actualLine(e); line != "" {
			fmt.Fprintf(&b, "Closed. %s.\n", line)
		} else {
			fmt.Fprintf(&b, "Closed: it took %s, %s of work. No estimate was kept when its work started.\n",
				amountsWords(e.Actual.Cost), durationWords(e.Actual.WorkingSeconds))
		}
	}
	if e.Spent != nil {
		fmt.Fprintf(&b, "Spent on its closed children: %s.\n", amountsWords(e.Spent.Cost))
	}
	if !estimateHasFigures(e) {
		if e.OpenChildren != nil && *e.OpenChildren == 0 {
			b.WriteString("No open children, so nothing is left to estimate.")
		} else {
			fmt.Fprintf(&b, "Not enough past work to estimate: %d closed issues on this machine, and an estimate needs 5 like it.", e.ClosedIssues)
		}
		return b.String()
	}
	what := "Estimate"
	if e.OpenChildren != nil {
		what = fmt.Sprintf("Estimate for the %d open children", *e.OpenChildren)
	}
	fmt.Fprintf(&b, "%s, the median and in brackets the range 8 in 10 like it land in, from %d closed issues (matched by %s):\n",
		what, e.Matches, estimateMatchedWords(e.MatchedBy))
	for _, c := range sortedKeys(e.Cost) {
		r := e.Cost[c]
		fmt.Fprintf(&b, "- Cost: %s (%s to %s)\n", costWords(r.Median, c), costWords(r.P10, c), costWords(r.P90, c))
	}
	if r := e.OutputTokens; r != nil {
		fmt.Fprintf(&b, "- Output tokens: %s (%s to %s)\n", tokenWords(int64(r.Median)), tokenWords(int64(r.P10)), tokenWords(int64(r.P90)))
	}
	if r := e.WorkingSeconds; r != nil {
		fmt.Fprintf(&b, "- Agents' work: %s (%s to %s)\n", durationWords(r.Median), durationWords(r.P10), durationWords(r.P90))
	}
	if r := e.CycleTimeSeconds; r != nil {
		fmt.Fprintf(&b, "- Cycle time, start to last PR merged: %s (%s to %s)\n", durationWords(r.Median), durationWords(r.P10), durationWords(r.P90))
	}
	if l := e.LandsAt; l != nil {
		day := func(d wire.Date) string { return d.Time().Local().Format("Mon 2 Jan") }
		fmt.Fprintf(&b, "- Lands: %s (%s to %s), if work starts today\n", day(l.Median), day(l.P10), day(l.P90))
	}
	return strings.TrimRight(b.String(), "\n")
}

// actualLine is Work's line for a closed issue or epic (#3561): "Estimated $3.20, 2h 10m of
// work; actual $4.10, 3h 0m of work". Empty when no estimate was kept, or it had no figures.
func actualLine(e wire.LineageEstimate) string {
	kept := e.Kept
	if kept == nil || e.Actual == nil {
		return ""
	}
	var said []string
	if len(kept.Cost) > 0 {
		said = append(said, amountsWords(kept.Cost))
	}
	if kept.WorkingSeconds != nil {
		said = append(said, durationWords(*kept.WorkingSeconds)+" of work")
	}
	if len(said) == 0 {
		return ""
	}
	took := []string{amountsWords(e.Actual.Cost)}
	if kept.WorkingSeconds != nil {
		took = append(took, durationWords(e.Actual.WorkingSeconds)+" of work")
	}
	return "Estimated " + strings.Join(said, ", ") + "; actual " + strings.Join(took, ", ")
}

func estimateHasFigures(e wire.LineageEstimate) bool {
	return len(e.Cost) > 0 || e.OutputTokens != nil || e.WorkingSeconds != nil
}

func estimateMatchedWords(by *string) string {
	switch {
	case by == nil:
		return "each open child's own type and level"
	case *by == "level":
		return "the same type and level"
	case *by == "type":
		return "the same type"
	}
	return "all closed issues"
}

func countOf(n *int64) int64 {
	if n == nil {
		return 0
	}
	return *n
}
