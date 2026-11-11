package agentsd

import (
	"context"
	"log"
	"path/filepath"
	"reflect"
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
//   - A session's work is its active works-on, opens and reviews links to an issue, a PR or
//     a release (a review session's P#n label is a works-on link, so a review counts on its
//     PR; a release session's v1.2.0, on its release, #4524).
//   - A helper with no work of its own works for its parent: the session that started it,
//     and so on up, at most lineage.MostDepth sessions.
//   - A turn with no work, that started sessions, goes on their work (#4524): a Scrum
//     Master's turn that starts a lead or a lane goes on that epic or issue.
//   - A turn with no work at all goes under the session itself, so every turn is
//     somewhere; a repo's rollup says those as unlinked.
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
	// costSessionsSent bounds a node's sessions as they are sent.
	costSessionsSent = 20
	costNodeKeep     = lineage.KeepEnded
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
	// multiplierMerges is the merges the Multiplier counts (#3903), nil until first asked.
	multiplierMerges map[wire.LineageNode]lineage.Merge
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
		repo := ""
		if len(work) == 1 && work[0].Kind == lineage.KindSession {
			repo = d.sessionRepo(folder)
		}
		shares := lineage.Split(add, len(work))
		// After the unlock: a merged PR's comment says the new total (#2352).
		defer d.prCostChanged(work)
		d.workMu.Lock()
		defer d.workMu.Unlock()
		for i, n := range work {
			d.noteCostLocked(n, at, func(c *wire.LineageCostNode) {
				if repo != "" {
					c.Repo = &repo
				}
				lineage.AddCost(&c.Banked, shares[i])
			})
		}
		d.costChangedLocked()
	})
}

// sessionRepo is a session's repo: its folder's repo, or folder:<name> without one.
func (d *Daemon) sessionRepo(folder string) string {
	if r := d.folderRepo(folder); r.forge != "" {
		return r.forge + ":" + r.path
	}
	if folder == "" || folder == "/" {
		return ""
	}
	return "folder:" + filepath.Base(folder)
}

// workOf is what a session works on now: its own work, else its parent's, else the work of
// the sessions it started in this turn (#4524), else itself.
func (d *Daemon) workOf(id wire.UUID) []wire.LineageNode {
	s := sessionNode(id)
	seen := map[wire.LineageNode]bool{}
	for range lineage.MostDepth {
		seen[s] = true
		work, parent := d.ownWork(s, seen)
		if len(work) > 0 {
			return work
		}
		if parent == nil {
			break
		}
		s = *parent
	}
	if work := d.startedWork(sessionNode(id)); len(work) > 0 {
		return work
	}
	return []wire.LineageNode{sessionNode(id)}
}

// isWork says n is work a turn's cost can go on: an issue, a PR, or a release (#4524).
func isWork(n wire.LineageNode) bool {
	return n.Kind == lineage.KindIssue || n.Kind == lineage.KindPR || n.Kind == lineage.KindRelease
}

// ownWork is what s works on itself, by its active works-on, opens and reviews links, each not
// seen yet, in order; and the session that started it, when one did and is not seen.
func (d *Daemon) ownWork(s wire.LineageNode, seen map[wire.LineageNode]bool) ([]wire.LineageNode, *wire.LineageNode) {
	var work []wire.LineageNode
	var parent *wire.LineageNode
	for _, l := range d.lineage().Links(s).Links {
		switch {
		case l.From == s && l.EndedAt == nil && isWork(l.To) &&
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
	sort.Slice(work, func(i, j int) bool { return costKey(work[i]) < costKey(work[j]) })
	return work, parent
}

// startedWork is the work of the sessions s started in its turn now (#4524): a Scrum Master's
// turn that starts a lead or a lane goes on that epic or issue. Each started session counts by
// its own work only. None when s has no turn on record.
func (d *Daemon) startedWork(s wire.LineageNode) []wire.LineageNode {
	links := d.lineage().Links(s)
	start, ok := turnStart(links.States)
	if !ok {
		return nil
	}
	seen := map[wire.LineageNode]bool{s: true}
	var work []wire.LineageNode
	for _, l := range links.Links {
		if l.From != s || l.Rel != lineage.RelStarted || l.To.Kind != lineage.KindSession || l.At < start || seen[l.To] {
			continue
		}
		seen[l.To] = true
		w, _ := d.ownWork(l.To, seen)
		work = append(work, w...)
	}
	sort.Slice(work, func(i, j int) bool { return costKey(work[i]) < costKey(work[j]) })
	return work
}

// turnStart is when the newest turn in states began, newest first: the oldest of the newest
// run of working and needs-you, as a question in a turn is still the turn. Not ok with no
// working state.
func turnStart(states []wire.LineageSessionState) (wire.Date, bool) {
	var start wire.Date
	found := false
	for _, st := range states {
		switch {
		case st.State == wire.LineageSessionStateNameWorking:
			start, found = st.At, true
		case st.State == wire.LineageSessionStateNameNeedsYou && found:
			start = st.At
		case found:
			return start, true
		}
	}
	return start, found
}

// noteCostLocked changes a node's total, made when it is new, and marks it unsent.
func (d *Daemon) noteCostLocked(n wire.LineageNode, at time.Time, change func(*wire.LineageCostNode)) {
	f := d.costLedgerLocked()
	k := costKey(n)
	c, ok := f.Nodes[k]
	if !ok {
		c = wire.LineageCostNode{Node: n, Banked: wire.LineageCost{Cost: map[string]float64{}}}
		if p := lineage.RepoOf(n); p != "" {
			c.Repo = &p
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
	// The Multiplier, live on the window (#3903): a merge or a merged revert the agents worked on.
	if event != "checks.failed" && d.noteMergeLocked(d.costLedgerLocked().Nodes[costKey(pr)]) && event == "pr.merged" {
		d.multiplierChanged(pr)
	}
}

// refreshCostLinksLocked sets each node's fixes, partOf and sessions from the graph, and its
// start (#3562), marking the nodes whose links changed unsent. Ended links count: a PR closed
// without a merge stays against its issue, as waste, and a session that worked on a node stays
// one of its sessions. The start is kept the earliest seen, so it outlives the links it came
// from, and a node already banked gets it from the links still kept.
func (d *Daemon) refreshCostLinksLocked() {
	f := d.costLedgerLocked()
	for k, c := range f.Nodes {
		var fixes, partOf, sessions []string
		started := c.StartedAt
		seen := map[string]bool{}
		for _, l := range d.lineage().Links(c.Node).Links {
			if startsWork(c.Node, l) && (started == nil || l.At < *started) {
				at := l.At
				started = &at
			}
			if l.To == c.Node && l.From.Kind == lineage.KindSession && !seen["session "+l.From.Ref] &&
				(l.Rel == lineage.RelWorksOn || l.Rel == lineage.RelOpens || l.Rel == lineage.RelReviews) {
				seen["session "+l.From.Ref] = true
				sessions = append(sessions, l.From.Ref)
			}
			if l.From != c.Node || seen[l.Rel+" "+l.To.Ref] {
				continue
			}
			seen[l.Rel+" "+l.To.Ref] = true
			switch {
			case c.Node.Kind == lineage.KindPR && l.Rel == lineage.RelFixes && l.To.Kind == lineage.KindIssue:
				fixes = append(fixes, l.To.Ref)
			case l.Rel == lineage.RelPartOf && l.To.Kind == lineage.KindRelease:
				partOf = append(partOf, l.To.Ref)
			}
		}
		sort.Strings(fixes)
		sort.Strings(partOf)
		sort.Strings(sessions)
		// reports/nodes counts them (#3118); a node more sessions worked on says the first.
		sessions = sessions[:min(len(sessions), costSessionsSent)]
		if slices.Equal(fixes, c.Fixes) && slices.Equal(partOf, c.PartOf) && slices.Equal(sessions, c.Sessions) &&
			reflect.DeepEqual(started, c.StartedAt) {
			continue
		}
		c.Fixes, c.PartOf, c.Sessions, c.StartedAt = fixes, partOf, sessions, started
		f.Nodes[k] = c
		f.Seq++
		f.Unsent[k] = f.Seq
	}
}

// startsWork says l starts work on n (#3562): a session's works-on, opens or started link to
// it, or a PR's fixes link to an issue.
func startsWork(n wire.LineageNode, l wire.LineageLink) bool {
	if l.To != n {
		return false
	}
	switch l.From.Kind {
	case lineage.KindSession:
		return l.Rel == lineage.RelWorksOn || l.Rel == lineage.RelOpens || l.Rel == lineage.RelStarted
	case lineage.KindPR:
		return n.Kind == lineage.KindIssue && l.Rel == lineage.RelFixes
	}
	return false
}

// refreshCostResolvedLocked puts on each issue and PR node the title, state and
// labels the resolve cache has for it (#3118), for reports/nodes, and on an issue its level,
// feature, area and epic (#3562), marking the nodes whose answer changed unsent. A level,
// feature, area or epic once known is kept: the cache forgets, and a closed issue keeps them.
// It asks the forge only for the issues with no level yet that nothing has resolved, at most
// resolvePerWalk at a time, so the issues already banked get one (the backfill).
func (d *Daemon) refreshCostResolvedLocked() {
	f := d.costLedgerLocked()
	d.resolveMu.Lock()
	defer d.resolveMu.Unlock()
	var ask []wire.LineageNode
	now := nowFunc()
	for k, c := range f.Nodes {
		e, ok := d.resolveCache[c.Node]
		if !ok || !e.ok {
			if c.Node.Kind == lineage.KindIssue && c.Level == nil && c.Resolved == nil && len(ask) < resolvePerWalk &&
				!d.resolveAsking[c.Node] && (!ok || now.Sub(e.at) >= resolveRecheck) {
				if _, _, can := askedNode(c.Node); can {
					ask = append(ask, c.Node)
				}
			}
			continue
		}
		before := c
		r := e.resolved
		c.Resolved = &r
		if c.Node.Kind == lineage.KindIssue {
			keep := func(have **string, v string) {
				if v != "" {
					*have = &v
				}
			}
			keep(&c.Level, lineage.LevelOf(r.Labels))
			keep(&c.Feature, lineage.LabelValue(r.Labels, "feature:"))
			if e.parent != nil {
				keep(&c.Parent, e.parent.Ref)
			}
			keep(&c.Milestone, e.milestone)
		}
		if reflect.DeepEqual(before, c) {
			continue
		}
		f.Nodes[k] = c
		f.Seq++
		f.Unsent[k] = f.Seq
	}
	if len(ask) > 0 {
		d.askResolveLocked(ask)
	}
}

// keepEstimatesLocked keeps on each issue whose work has started the estimate it had then
// (#3561): from the issues merged before its start, once its labels are known, marking it
// unsent. It is made once, so an issue that closes is set against what was said at its start.
// An epic (labelled epic, or another issue's parent) has none here: lineage/estimate makes an
// epic's from its plan.
//
// An estimate kept before #4525 has no cycleTimeSeconds: it is made again here, so it gets the
// P10 to P90 of each figure, the cycle time and landsAt too (the backfill). When the issue
// still has too little cycle history to say, the figures do not change, and nothing is marked
// unsent again.
func (d *Daemon) keepEstimatesLocked() {
	f := d.costLedgerLocked()
	var history []lineage.Past
	var parents map[string]bool
	for k, c := range f.Nodes {
		start := lineage.StartOf(c)
		if c.Node.Kind != lineage.KindIssue || start == nil || c.Resolved == nil ||
			(c.Level != nil && *c.Level == "epic") || (c.Estimate != nil && c.Estimate.CycleTimeSeconds != nil) {
			continue
		}
		if parents == nil {
			nodes := ledgerNodes(f)
			history = lineage.History(nodes)
			parents = map[string]bool{}
			for _, n := range nodes {
				if n.Parent != nil {
					parents[*n.Parent] = true
				}
			}
		}
		if parents[c.Node.Ref] {
			continue
		}
		kept := lineage.KeepIssue(history, c.Node, c.Resolved.Labels, *start)
		if c.Estimate != nil && reflect.DeepEqual(kept, *c.Estimate) {
			continue
		}
		d.keepEstimateLocked(k, kept)
	}
}

// keepEstimateLocked puts kept on the node at k and marks it unsent.
func (d *Daemon) keepEstimateLocked(k string, kept wire.LineageEstimateKept) {
	f := d.costLedgerLocked()
	c, ok := f.Nodes[k]
	if !ok {
		return
	}
	c.Estimate = &kept
	f.Nodes[k] = c
	f.Seq++
	f.Unsent[k] = f.Seq
}

func ledgerNodes(f *costLedgerFile) []wire.LineageCostNode {
	nodes := make([]wire.LineageCostNode, 0, len(f.Nodes))
	for _, c := range f.Nodes {
		nodes = append(nodes, c)
	}
	return nodes
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
	d.refreshCostResolvedLocked()
	d.keepEstimatesLocked()
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

// lineageEstimate is lineage/estimate (#3559): an issue or an epic estimated from the closed
// issues in this machine's totals. Its labels, children, their state and steps come from the
// forge's plan (forge/plan, cached); an issue with children, or labelled epic, is an epic.
// With it go the estimate it had when its work started and, once closed, what it took (#3561).
func (d *Daemon) lineageEstimate(ctx context.Context, r wire.LineageEstimateRequest) (wire.LineageEstimate, error) {
	plan, err := d.forgePlan(ctx, wire.ForgePlanRequest{Node: r.Node})
	if err != nil {
		return wire.LineageEstimate{}, err
	}
	start := wire.DateOf(nowFunc())
	if r.StartAt != nil {
		start = *r.StartAt
	}
	d.lineageSettle(2 * time.Second)
	d.workMu.Lock()
	d.refreshCostLinksLocked()
	d.refreshCostResolvedLocked()
	d.keepEstimatesLocked()
	f := d.costLedgerLocked()
	nodes := ledgerNodes(f)
	own, haveOwn := f.Nodes[costKey(r.Node)]
	d.workMu.Unlock()
	history := lineage.History(nodes)
	// The overhead, loaded into the cost as "about $165 all in" (#4524).
	overhead := lineage.Overhead(nodes, nowFunc())
	labels := forgeLabelNames(plan.Item.Labels)
	closed := plan.Item.State == "closed" || plan.Item.State == "merged"
	if len(plan.Children) == 0 && lineage.LevelOf(labels) != "epic" {
		e := lineage.EstimateIssue(history, r.Node, labels, start)
		lineage.Load(&e, overhead, false)
		if haveOwn {
			e.Kept = own.Estimate
		}
		if closed {
			actual := lineage.Rollup(nodes, r.Node).Total
			e.Actual = &actual
		}
		return e, nil
	}
	children := make([]lineage.EpicChild, 0, len(plan.Children))
	for _, c := range plan.Children {
		children = append(children, lineage.EpicChild{Node: c.Item.Node, Labels: forgeLabelNames(c.Item.Labels), Step: c.Step,
			Open: c.Item.State != "closed" && c.Item.State != "merged"})
	}
	e := lineage.EstimateEpic(history, nodes, r.Node, labels, children, start)
	lineage.Load(&e, overhead, true)
	e.Kept = d.keptEpic(history, nodes, own, haveOwn, r.Node, labels, children)
	if closed {
		actual := lineage.Rollup(nodes, r.Node).Total
		for _, c := range children {
			lineage.AddCost(&actual, lineage.Rollup(nodes, c.Node).Total)
		}
		e.Actual = &actual
	}
	return e, nil
}

// keptEpic is the estimate an epic had when its work started (#3561): the one kept on its
// node, else one made now from its plan, every child open, and the issues merged before the
// first start on it or any child; kept on its node when the store has one. None before work
// starts. An estimate kept as an issue's (it had no children yet) is made again. One kept
// before #4525, with no cycleTimeSeconds, is made again too (the backfill).
func (d *Daemon) keptEpic(history []lineage.Past, nodes []wire.LineageCostNode, own wire.LineageCostNode, haveOwn bool,
	of wire.LineageNode, labels []string, children []lineage.EpicChild) *wire.LineageEstimateKept {
	if haveOwn && own.Estimate != nil && own.Estimate.MatchedBy == nil && own.Estimate.CycleTimeSeconds != nil {
		return own.Estimate
	}
	in := map[wire.LineageNode]bool{of: true}
	for _, c := range children {
		in[c.Node] = true
	}
	var start *wire.Date
	for _, n := range nodes {
		if s := lineage.StartOf(n); in[n.Node] && s != nil && (start == nil || *s < *start) {
			start = s
		}
	}
	if start == nil {
		return nil
	}
	kept := lineage.KeepEpic(history, of, labels, children, *start)
	if haveOwn && (own.Estimate == nil || !reflect.DeepEqual(kept, *own.Estimate)) {
		d.workMu.Lock()
		d.keepEstimateLocked(costKey(of), kept)
		d.costChangedLocked()
		d.workMu.Unlock()
	}
	return &kept
}

func forgeLabelNames(labels []wire.ForgeLabel) []string {
	out := make([]string, 0, len(labels))
	for _, l := range labels {
		out = append(out, l.Name)
	}
	return out
}

func (d *Daemon) registerLineageCost() {
	On(d, wire.CallLineageCost, func(_ context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageCostRollup, error) {
		return d.lineageCost(r.Node), nil
	})
	On(d, wire.CallMultiplierState, func(ctx context.Context, _ *Client, _ wire.Empty) (wire.Multiplier, error) {
		return d.multiplierState(ctx), nil
	})
	On(d, wire.CallLineageEstimate, func(ctx context.Context, _ *Client, r wire.LineageEstimateRequest) (wire.LineageEstimate, error) {
		return d.lineageEstimate(ctx, r)
	})
	On(d, wire.CallLineageForecast, func(ctx context.Context, _ *Client, r wire.LineageForecastRequest) (wire.LineageForecast, error) {
		return d.lineageForecast(ctx, r)
	})
}
