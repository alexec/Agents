package agentsd

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The approval wait per PR (#4553, epic #4551): how long work waits on the person. A PR's
// node keeps when it was opened (pr.opened), when it was labelled needs-approval
// (pr.labelled) and its first answer by a person (pr.reviewed or pr.commented). The wait is
// from the label, else the opening, to that answer (lineage.ApprovalWait); lineage/figures
// gives its median, P90 and the share of merged PRs that waited, and time/history its
// median for Reports ▸ Time.
//
// A person's answer is one not by a bot (an author that ends in [bot], as the agents' bot,
// alexec-agents[bot]) and not a comment that starts with <!-- agent -->, which an agent
// posting as the person writes (AGENTS.md, "Who an agent posts as"). The events already leave
// both out unless a subscription asked for anyone's; this holds for those too.
//
// Decided: the events reach the store only when a subscription raises them (a lane's wait, a
// workflow), as pr.opened and pr.merged do, not by a poll of its own, because every PR that
// waits for the person has a lane waiting on pr.reviewed and pr.commented (#2838). Alex can
// overrule.

// agentMarker starts a comment an agent posts as the person.
const agentMarker = "<!-- agent -->"

type approvalPayload struct {
	PR struct {
		URL string `json:"url"`
	} `json:"pr"`
	Label  string `json:"label"`
	Review *struct {
		Author string `json:"author"`
		Body   string `json:"body"`
	} `json:"review"`
	Comment *struct {
		Author string `json:"author"`
		Body   string `json:"body"`
	} `json:"comment"`
	LabelledAt  string `json:"labelledAt"`
	ReviewedAt  string `json:"reviewedAt"`
	CommentedAt string `json:"commentedAt"`
}

// lineageApprovalEvent notes a needs-approval label, or a person's review or comment, on its PR.
func (d *Daemon) lineageApprovalEvent(e wire.Event) {
	var p approvalPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil {
		return
	}
	repo, n, ok := d.prOfURLHere(p.PR.URL)
	if !ok {
		return
	}
	pr := repo.pr(n)
	switch e.Name {
	case "pr.labelled":
		at, ok := payloadTime(p.LabelledAt)
		if !ok || p.Label != reviewLabel {
			return
		}
		d.lineageDo(func() { d.notePRAsked(pr, at) })
	case "pr.reviewed", "pr.commented":
		stamp, author, body := p.ReviewedAt, "", ""
		switch {
		case p.Review != nil:
			author, body = p.Review.Author, p.Review.Body
		case p.Comment != nil:
			stamp, author, body = p.CommentedAt, p.Comment.Author, p.Comment.Body
		default:
			return
		}
		at, ok := payloadTime(stamp)
		if !ok || !personsAnswer(author, body) {
			return
		}
		d.lineageDo(func() { d.notePRAnswered(pr, at) })
	}
}

// personsAnswer says a review or comment is a person's: not a bot's, not an agent's.
func personsAnswer(author, body string) bool {
	return author != "" && !strings.HasSuffix(strings.ToLower(author), "[bot]") &&
		!strings.HasPrefix(strings.TrimSpace(body), agentMarker)
}

// payloadTime is an event payload's RFC 3339 time.
func payloadTime(stamp string) (wire.Date, bool) {
	t, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		return 0, false
	}
	return wire.DateOf(t), true
}

// notePROpened keeps the earliest opening of a PR.
func (d *Daemon) notePROpened(pr wire.LineageNode, at wire.Date) {
	d.noteApproval(pr, func(c *wire.LineageCostNode) bool {
		if c.OpenedAt != nil && *c.OpenedAt <= at {
			return false
		}
		c.OpenedAt = &at
		return true
	})
}

// notePRAsked keeps the first needs-approval label of a PR. An answer before it was not an
// answer to it, so it goes.
func (d *Daemon) notePRAsked(pr wire.LineageNode, at wire.Date) {
	d.noteApproval(pr, func(c *wire.LineageCostNode) bool {
		if c.AskedAt != nil && *c.AskedAt <= at {
			return false
		}
		c.AskedAt = &at
		if c.AnsweredAt != nil && *c.AnsweredAt < at {
			c.AnsweredAt = nil
		}
		return true
	})
}

// notePRAnswered keeps a PR's first answer by a person at or after its wait's start, while
// it was open.
func (d *Daemon) notePRAnswered(pr wire.LineageNode, at wire.Date) {
	d.noteApproval(pr, func(c *wire.LineageCostNode) bool {
		start := c.AskedAt
		if start == nil {
			start = c.OpenedAt
		}
		if start != nil && at < *start || c.EndedAt != nil && at > *c.EndedAt ||
			c.AnsweredAt != nil && *c.AnsweredAt <= at {
			return false
		}
		c.AnsweredAt = &at
		return true
	})
}

// noteApproval changes a PR's node when change says it changed it, made when it is new.
func (d *Daemon) noteApproval(pr wire.LineageNode, change func(*wire.LineageCostNode) bool) {
	d.workMu.Lock()
	defer d.workMu.Unlock()
	c, ok := d.costLedgerLocked().Nodes[costKey(pr)]
	if !ok {
		c = wire.LineageCostNode{Node: pr}
	}
	if !change(&c) {
		return
	}
	d.noteCostLocked(pr, nowFunc(), func(n *wire.LineageCostNode) {
		n.OpenedAt, n.AskedAt, n.AnsweredAt = c.OpenedAt, c.AskedAt, c.AnsweredAt
	})
	d.costChangedLocked()
}

// approvalWait is time/history's approvalWait: this machine's PRs, every repo.
func (d *Daemon) approvalWait() *wire.LineageDeliveryFigure {
	d.workMu.Lock()
	nodes := ledgerNodes(d.costLedgerLocked())
	d.workMu.Unlock()
	f := lineage.ApprovalWaitOf(nodes, nowFunc())
	return &f
}
