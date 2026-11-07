package agentsd

import (
	"context"
	"regexp"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Issues an agent files (#3582), so a dictated idea reaches the issues it became:
//
//   - A tool call that files a forge issue (`gh issue create`, `glab issue create`, or a
//     forge server's create-issue tool) links session opens issue, source agent, for each
//     issue address in what the call gave back.
//   - The issue is asked of the forge at once and again filedRecheck later
//     (lineagemilestone.go), for its milestone, its parent and its sub-issues: an epic's
//     children are often filed, and made its sub-issues, just after it.

const (
	// filingHeld bounds the open issue-filing calls one session keeps.
	filingHeld = 64
	// filedIssuesMax bounds the issues one call links.
	filedIssuesMax = 20
)

// filedRecheck is how long after an issue is filed it is asked again. Tests set it.
var filedRecheck = 5 * time.Minute

var (
	issueCreateCommand = regexp.MustCompile(`\b(?:gh|glab)\s+issue\s+create\b`)
	issueCreateTool    = regexp.MustCompile(`(?i)\bcreate[_ -]?issue\b|\bissue[_ -]?create\b`)
	// issueWriteCreate is GitHub's own server's issue_write, asked to create.
	issueWriteCreate = regexp.MustCompile(`"method"\s*:\s*"create"`)
)

// filesIssue says a tool call files a forge issue, from its command or its tool's name.
func filesIssue(call wire.ToolCall) bool {
	name := call.Title
	if call.Name != nil {
		name += " " + *call.Name
	}
	in := string(call.RawInput)
	switch {
	case issueCreateCommand.MatchString(in) || issueCreateCommand.MatchString(call.Title):
		return true
	case issueCreateTool.MatchString(strings.ReplaceAll(name, "__", " ")):
		return true
	}
	return strings.Contains(name, "issue_write") && issueWriteCreate.MatchString(in)
}

// issuesIn is the forge issues whose addresses what a tool call gave back names, each once.
func issuesIn(call wire.ToolCall) []wire.LineageNode {
	texts := []string{string(call.RawOutput)}
	for _, c := range call.Content {
		if c.Content != nil && c.Content.Text != nil {
			texts = append(texts, *c.Content.Text)
		}
	}
	var out []wire.LineageNode
	seen := map[wire.LineageNode]bool{}
	for _, text := range texts {
		if !strings.Contains(text, "/issues/") {
			continue
		}
		for _, raw := range urlSaid.FindAllString(text, filedIssuesMax) {
			repo, n, ok := issueOfURL(strings.TrimRight(raw, ".,;:!?"))
			if !ok {
				continue
			}
			if issue := repo.issue(n); !seen[issue] && len(out) < filedIssuesMax {
				seen[issue] = true
				out = append(out, issue)
			}
		}
	}
	return out
}

// noteIssueFiled links session l to the issues a tool call of its filed: the call's start
// says it files one, and an update, or the start itself, gives the issue's address.
func (d *Daemon) noteIssueFiled(l *live, call wire.ToolCall) {
	if call.ToolCallID == nil {
		return
	}
	id := *call.ToolCallID
	l.mu.Lock()
	filing := l.filing[id] || filesIssue(call)
	switch {
	case !filing:
	case toolEnded(call.Status):
		delete(l.filing, id)
	case !l.filing[id] && len(l.filing) < filingHeld:
		if l.filing == nil {
			l.filing = map[string]bool{}
		}
		l.filing[id] = true
	}
	l.mu.Unlock()
	if !filing {
		return
	}
	if issues := issuesIn(call); len(issues) > 0 {
		d.noteFiledIssues(l.id, issues)
	}
}

// noteFiledIssues links session id opens each issue, and asks the forge for each now and
// again filedRecheck later.
func (d *Daemon) noteFiledIssues(id wire.UUID, issues []wire.LineageNode) {
	a := d.Store.Agent(id)
	if a == nil || a.Purpose != nil {
		return
	}
	own, s := folderPath(a), sessionNode(id)
	d.lineageDo(func() {
		for _, issue := range issues {
			d.link(s, issue, lineage.RelOpens, lineage.SourceAgent)
			repo, n, ok := issueOfNode(issue)
			if !ok || !repo.asks() {
				continue
			}
			folder := d.repoFolder(repo)
			if folder == "" {
				folder = own
			}
			d.noteIssueMilestone(folder, repo, n)
			d.askIssueAgain(folder, repo, n)
		}
	})
}

// askIssueAgain asks the forge for an issue again filedRecheck from now, whenever it was
// last asked, unless the host stops first.
func (d *Daemon) askIssueAgain(folder string, repo forgeRepo, n int) {
	d.goLoop("lineage filed issue", func(ctx context.Context) {
		wait := time.NewTimer(filedRecheck)
		defer wait.Stop()
		select {
		case <-ctx.Done():
			return
		case <-wait.C:
		}
		d.issueMu.Lock()
		delete(d.issueAsked, repo.issue(n))
		d.issueMu.Unlock()
		d.noteIssueMilestone(folder, repo, n)
	})
}
