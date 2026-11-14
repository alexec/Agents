package agentsd

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Issues an agent files (#3582), so a dictated idea reaches the issues it became:
//
//   - A tool call that files a forge issue (`gh issue create`, `glab issue create`, Gitea's
//     `tea issues create`, Forgejo's `fj issue create` (#3850), or a forge server's
//     create-issue tool) links session opens issue, source agent, for each
//     issue address in what the call gave back. fj gives back no address, only
//     `created issue #12`: its issue is on its `--repo`, or else on the folder's Forgejo
//     repository.
//   - The issue is asked of the forge at once and again filedRecheck later
//     (lineageparent.go), for its parent and its sub-issues: an epic's
//     children are often filed, and made its sub-issues, just after it.

const (
	// filingHeld bounds the open issue-filing calls one session keeps.
	filingHeld = 64
	// filedIssuesMax bounds the issues one call links.
	filedIssuesMax = 20
)

// filedRecheck is how long after an issue is filed it is asked again.
var filedRecheck = 5 * time.Minute

// filedRecheckDue, when a test closes it, makes each filed issue's second ask due at once,
// so the test, not a timer, says when the forge has changed (#3965). Nil in the daemon.
var filedRecheckDue chan struct{}

var (
	// issueCreateCommand lets flags stand before the command, as fj's --host and tea's --login.
	issueCreateCommand = regexp.MustCompile(`\b(?:gh|glab|tea|fj)(?:\s+--?[\w-]+(?:[= ][^-\s]\S*)?)*\s+issues?\s+create\b`)
	issueCreateTool    = regexp.MustCompile(`(?i)\bcreate[_ -]?issue\b|\bissue[_ -]?create\b`)
	// fjIssueCreate is Forgejo's fj, which says `created issue #12: Title`, with no address.
	fjIssueCreate = regexp.MustCompile(`\bfj(?:\s+--?[\w-]+(?:[= ][^-\s]\S*)?)*\s+issues?\s+create\b`)
	fjRepoFlag    = regexp.MustCompile(`(?:^|\s)(?:--repo|-r)[= ]['"]?([\w.-]+/[\w.-]+)`)
	fjCreated     = regexp.MustCompile(`\bcreated issue #([0-9]{1,9})\b`)
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

// issuesIn is the forge issues whose addresses what a tool call gave back names, each once:
// on the Forgejo whose root is forgejoRoot too, the connected one's ("" for none).
func issuesIn(call wire.ToolCall, forgejoRoot string) []wire.LineageNode {
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
			repo, n, ok := issueOfURLOn(strings.TrimRight(raw, ".,;:!?"), forgejoRoot)
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
	// fjRepo may ask git, so not under l.mu.
	starts := filesIssue(call)
	var fj forgeRepo
	if starts {
		fj = d.fjRepo(l.id, call)
	}
	l.mu.Lock()
	held, filing := l.filing[id]
	if filing {
		fj = held
	}
	filing = filing || starts
	switch {
	case !filing:
	case toolEnded(call.Status):
		delete(l.filing, id)
	case len(l.filing) < filingHeld:
		if l.filing == nil {
			l.filing = map[string]forgeRepo{}
		}
		l.filing[id] = fj
	}
	l.mu.Unlock()
	if !filing {
		return
	}
	_, root := d.forgejoRoot()
	issues := issuesIn(call, root)
	if fj.path != "" {
		issues = append(issues, fjIssuesIn(call, fj)...)
	}
	if len(issues) > 0 {
		d.noteFiledIssues(l.id, issues)
	}
}

// fjRepo is the Forgejo repository an `fj issue create` call files on: its --repo, or else
// the session's folder's, when that is on Forgejo. It is none for any other call.
func (d *Daemon) fjRepo(id wire.UUID, call wire.ToolCall) forgeRepo {
	text := string(call.RawInput) + "\n" + call.Title
	at := fjIssueCreate.FindStringIndex(text)
	if at == nil {
		return forgeRepo{}
	}
	if m := fjRepoFlag.FindStringSubmatch(strings.SplitN(text[at[0]:], "\n", 2)[0]); m != nil {
		return forgeRepo{"forgejo", repoPath(m[1])}
	}
	if a := d.Store.Agent(id); a != nil {
		if r := d.folderRepo(folderPath(a)); r.forge == "forgejo" {
			return r
		}
	}
	return forgeRepo{}
}

// fjIssuesIn is the issue that fj's `created issue #12` names, on repo.
func fjIssuesIn(call wire.ToolCall, repo forgeRepo) []wire.LineageNode {
	texts := []string{string(call.RawOutput)}
	for _, c := range call.Content {
		if c.Content != nil && c.Content.Text != nil {
			texts = append(texts, *c.Content.Text)
		}
	}
	for _, text := range texts {
		if m := fjCreated.FindStringSubmatch(text); m != nil {
			if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
				return []wire.LineageNode{repo.issue(n)}
			}
		}
	}
	return nil
}

// noteFiledIssues links session id opens each issue, and asks the forge for each now and
// again filedRecheck later.
func (d *Daemon) noteFiledIssues(id wire.UUID, issues []wire.LineageNode) {
	a := d.Store.Agent(id)
	if a == nil || a.Purpose != nil {
		return
	}
	own := folderPath(a)
	d.lineageDo(func() {
		s := d.sessionNode(id)
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
			d.noteIssueParent(folder, repo, n)
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
		case <-filedRecheckDue:
		}
		d.issueMu.Lock()
		delete(d.issueAsked, repo.issue(n))
		d.issueMu.Unlock()
		d.noteIssueParent(folder, repo, n)
	})
}
