package agentsd

import (
	"context"
	"log"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Cost on the link (#2350): each turn's cost, tokens and time go under the session's links
// that are active then, split evenly, in <root>/lineage-cost.json, one total per node.
//
//   - A session's work is its active works-on, opens and reviews links to an issue or a PR
//     (a review session's P#n label is a works-on link, so a review counts on its PR).
//   - A helper with no work of its own works for its parent: the session that started it,
//     and so on up, at most lineage.MostDepth sessions.
//   - A turn with no work at all goes under the session itself, so every turn is
//     somewhere; a project's rollup says those as unlinked.
//   - What is banked stays: a label changed later moves nothing (#829).
//
// The banking is done on the linker's goroutine, after the links given before it, so the
// links a turn sees are the ones made before it. The totals are saved at most every
// reportSaveAfter, and go to the control plane with usage/rollup (work).

const (
	// costNodesKept bounds the file: the nodes banked longest ago go first.
	costNodesKept = 5_000
	// costNodesSent bounds one send.
	costNodesSent = 1_000
	costNodeKeep  = lineage.KeepEnded
)

type costLedgerFile struct {
	// Nodes is each node's total, by costKey.
	Nodes map[string]wire.LineageCostNode `json:"nodes"`
	// Unsent is the nodes that changed since the control plane last took them, each with
	// the change it was last at.
	Unsent map[string]int64 `json:"unsent,omitempty"`
	Seq    int64            `json:"seq,omitempty"`
}

type costLedgerBook struct {
	workMu     sync.Mutex
	workLedger *costLedgerFile
	workSave   *time.Timer
	workClosed bool
}

func costKey(n wire.LineageNode) string { return n.Kind + "\t" + n.Ref }

func (d *Daemon) costLedgerPath() string { return filepath.Join(d.Store.Loc.Root, "lineage-cost.json") }

func (d *Daemon) costLedgerLocked() *costLedgerFile {
	if d.workLedger == nil {
		d.workLedger = &costLedgerFile{}
		readStore(d.costLedgerPath(), d.workLedger, "the cost on links starts again from now")
		if d.workLedger.Nodes == nil {
			d.workLedger.Nodes = map[string]wire.LineageCostNode{}
		}
		if d.workLedger.Unsent == nil {
			d.workLedger.Unsent = map[string]int64{}
		}
	}
	return d.workLedger
}

// bankWork banks add under the work agent a is on now.
func (d *Daemon) bankWork(a *wire.Agent, add wire.LineageCost) {
	if a == nil {
		return
	}
	id, folder := a.ID, folderPath(a)
	at := nowFunc()
	d.lineageDo(func() {
		work := d.workOf(id)
		project := ""
		if len(work) == 1 && work[0].Kind == lineage.KindSession {
			project = d.sessionProject(folder)
		}
		shares := lineage.Split(add, len(work))
		d.workMu.Lock()
		defer d.workMu.Unlock()
		for i, n := range work {
			d.noteCostLocked(n, at, func(c *wire.LineageCostNode) {
				if project != "" {
					c.Project = &project
				}
				lineage.AddCost(&c.Banked, shares[i])
			})
		}
		d.costChangedLocked()
	})
}

// sessionProject is a session's project: its folder's repo, or folder:<name> without one.
func (d *Daemon) sessionProject(folder string) string {
	if r := d.folderRepo(folder); r.forge != "" {
		return r.forge + ":" + r.path
	}
	if folder == "" || folder == "/" {
		return ""
	}
	return "folder:" + filepath.Base(folder)
}

// workOf is what a session works on now: its own work, else its parent's, else itself.
func (d *Daemon) workOf(id wire.UUID) []wire.LineageNode {
	s := sessionNode(id)
	seen := map[wire.LineageNode]bool{}
	for range lineage.MostDepth {
		seen[s] = true
		var work []wire.LineageNode
		var parent *wire.LineageNode
		for _, l := range d.lineage().Links(s).Links {
			switch {
			case l.From == s && l.EndedAt == nil && (l.To.Kind == lineage.KindIssue || l.To.Kind == lineage.KindPR) &&
				(l.Rel == lineage.RelWorksOn || l.Rel == lineage.RelOpens || l.Rel == lineage.RelReviews):
				if !seen[l.To] {
					seen[l.To] = true
					work = append(work, l.To)
				}
			case l.To == s && l.Rel == lineage.RelStarted && l.From.Kind == lineage.KindSession && parent == nil && !seen[l.From]:
				p := l.From
				parent = &p
			}
		}
		if len(work) > 0 {
			sort.Slice(work, func(i, j int) bool { return costKey(work[i]) < costKey(work[j]) })
			return work
		}
		if parent == nil {
			break
		}
		s = *parent
	}
	return []wire.LineageNode{sessionNode(id)}
}

// noteCostLocked changes a node's total, made when it is new, and marks it unsent.
func (d *Daemon) noteCostLocked(n wire.LineageNode, at time.Time, change func(*wire.LineageCostNode)) {
	f := d.costLedgerLocked()
	k := costKey(n)
	c, ok := f.Nodes[k]
	if !ok {
		c = wire.LineageCostNode{Node: n, Banked: wire.LineageCost{Cost: map[string]float64{}}}
		if p := lineage.ProjectOf(n); p != "" {
			c.Project = &p
		}
		// The start of the work on it, for Reports ▸ Value's lead time (#2351).
		first := wire.DateOf(at)
		c.FirstAt = &first
	}
	change(&c)
	c.LastAt = wire.DateOf(at)
	f.Nodes[k] = c
	f.Seq++
	f.Unsent[k] = f.Seq
}

// notePROutcome keeps how a PR ended, and counts its failed CI rounds.
func (d *Daemon) notePROutcome(pr wire.LineageNode, event, title string) {
	d.workMu.Lock()
	defer d.workMu.Unlock()
	now := nowFunc()
	ended := wire.DateOf(now)
	d.noteCostLocked(pr, now, func(c *wire.LineageCostNode) {
		switch event {
		case "pr.merged":
			o := lineage.OutcomeMerged
			// A revert, as Reports counts prsReverted.
			if strings.HasPrefix(title, "Revert") {
				o = lineage.OutcomeReverted
			}
			c.Outcome, c.EndedAt = &o, &ended
		case "pr.closed":
			o := lineage.OutcomeClosed
			c.Outcome, c.EndedAt = &o, &ended
		case "pr.opened":
			// Reopened: open again.
			c.Outcome, c.EndedAt = nil, nil
		case "checks.failed":
			n := int64(1)
			if c.FailedChecks != nil {
				n += *c.FailedChecks
			}
			c.FailedChecks = &n
		}
	})
	d.costChangedLocked()
}

// refreshCostLinksLocked sets each node's fixes and partOf from the graph, marking the
// nodes whose links changed unsent. Ended links count: a PR closed without a merge stays
// against its issue, as waste.
func (d *Daemon) refreshCostLinksLocked() {
	f := d.costLedgerLocked()
	for k, c := range f.Nodes {
		var fixes, partOf []string
		seen := map[string]bool{}
		for _, l := range d.lineage().Links(c.Node).Links {
			if l.From != c.Node || seen[l.Rel+" "+l.To.Ref] {
				continue
			}
			seen[l.Rel+" "+l.To.Ref] = true
			switch {
			case c.Node.Kind == lineage.KindPR && l.Rel == lineage.RelFixes && l.To.Kind == lineage.KindIssue:
				fixes = append(fixes, l.To.Ref)
			case l.Rel == lineage.RelPartOf && l.To.Kind == lineage.KindMilestone:
				partOf = append(partOf, l.To.Ref)
			}
		}
		sort.Strings(fixes)
		sort.Strings(partOf)
		if slices.Equal(fixes, c.Fixes) && slices.Equal(partOf, c.PartOf) {
			continue
		}
		c.Fixes, c.PartOf = fixes, partOf
		f.Nodes[k] = c
		f.Seq++
		f.Unsent[k] = f.Seq
	}
}

// costChangedLocked saves within reportSaveAfter, or at once after shutdown.
func (d *Daemon) costChangedLocked() {
	if d.workClosed {
		d.saveCostLocked()
		return
	}
	if d.workSave == nil {
		d.workSave = time.AfterFunc(reportSaveAfter, d.flushCost)
	}
}

func (d *Daemon) flushCost() {
	d.workMu.Lock()
	defer d.workMu.Unlock()
	if d.workSave != nil {
		d.saveCostLocked()
	}
}

// closeCost saves what is unsaved at shutdown.
func (d *Daemon) closeCost() {
	d.flushCost()
	d.workMu.Lock()
	d.workClosed = true
	d.workMu.Unlock()
}

func (d *Daemon) saveCostLocked() {
	if d.workSave != nil {
		d.workSave.Stop()
		d.workSave = nil
	}
	f := d.costLedgerLocked()
	pruneCost(f, nowFunc())
	if err := writeStore(d.costLedgerPath(), f); err != nil {
		log.Printf("lineage-cost.json: could not save: %v", err)
	}
}

// pruneCost drops the nodes banked longer ago than costNodeKeep, then the oldest past
// costNodesKept. The control plane keeps what it was sent.
func pruneCost(f *costLedgerFile, now time.Time) {
	oldest := wire.DateOf(now.Add(-costNodeKeep))
	for k, c := range f.Nodes {
		if c.LastAt < oldest {
			delete(f.Nodes, k)
		}
	}
	if over := len(f.Nodes) - costNodesKept; over > 0 {
		keys := make([]string, 0, len(f.Nodes))
		for k := range f.Nodes {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool { return f.Nodes[keys[i]].LastAt < f.Nodes[keys[j]].LastAt })
		for _, k := range keys[:over] {
			delete(f.Nodes, k)
		}
	}
	for k := range f.Unsent {
		if _, ok := f.Nodes[k]; !ok {
			delete(f.Unsent, k)
		}
	}
}

// unsentCost is the nodes to send, oldest change first, at most costNodesSent, and the
// change each was at, to mark them sent.
func (d *Daemon) unsentCost() ([]wire.LineageCostNode, map[string]int64) {
	d.workMu.Lock()
	defer d.workMu.Unlock()
	d.refreshCostLinksLocked()
	f := d.costLedgerLocked()
	keys := make([]string, 0, len(f.Unsent))
	for k := range f.Unsent {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return f.Unsent[keys[i]] < f.Unsent[keys[j]] })
	if len(keys) > costNodesSent {
		keys = keys[:costNodesSent]
	}
	out := make([]wire.LineageCostNode, 0, len(keys))
	sent := map[string]int64{}
	for _, k := range keys {
		out = append(out, f.Nodes[k])
		sent[k] = f.Unsent[k]
	}
	return out, sent
}

// costSent marks the nodes sent; one that changed while on its way is sent again.
func (d *Daemon) costSent(sent map[string]int64) {
	if len(sent) == 0 {
		return
	}
	d.workMu.Lock()
	defer d.workMu.Unlock()
	f := d.costLedgerLocked()
	for k, seq := range sent {
		if f.Unsent[k] == seq {
			delete(f.Unsent, k)
		}
	}
	d.saveCostLocked()
}

// lineageCost is lineage/cost: of's cost, rolled up from this machine's totals.
func (d *Daemon) lineageCost(of wire.LineageNode) wire.LineageCostRollup {
	d.lineageSettle(2 * time.Second)
	d.workMu.Lock()
	defer d.workMu.Unlock()
	d.refreshCostLinksLocked()
	f := d.costLedgerLocked()
	nodes := make([]wire.LineageCostNode, 0, len(f.Nodes))
	for _, c := range f.Nodes {
		nodes = append(nodes, c)
	}
	return lineage.Rollup(nodes, of)
}

func (d *Daemon) registerLineageCost() {
	On(d, wire.CallLineageCost, func(_ context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageCostRollup, error) {
		return d.lineageCost(r.Node), nil
	})
}
