package agentsd

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/jiramcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

// Plans in Work (#3265, #3267): work has one hierarchy. A feature is the label feature:<name>; an
// epic is a parent issue, labelled epic; its children are stories, tasks and spikes (labels
// story, task and spike), in the order the forge's "blocked by" links say. forge/plan reads an
// epic's children with their blockers and puts them in steps; forge/features lists the features
// with their epics. The plan is the forge's own sub-issues and links, never a file of ours, so it
// cannot go out of date, and other people and tools read it too.

// forgeLevels are the levels a label can say, as the app says them on every forge.
var forgeLevels = []string{"epic", "story", "task", "spike"}

// featurePrefix starts a feature's label.
const featurePrefix = "feature:"

// Features are read from the newest epics and open issues, at most featureEpicPages pages of
// forgeListMost of each.
const featureEpicPages = 5

func (d *Daemon) registerForgePlans() {
	On(d, wire.CallForgePlan, func(ctx context.Context, _ *Client, r wire.ForgePlanRequest) (wire.ForgePlan, error) {
		return d.forgePlan(ctx, r)
	})
	On(d, wire.CallForgeFeatures, func(ctx context.Context, _ *Client, r wire.ForgeFeaturesRequest) (wire.ForgeFeatures, error) {
		return d.forgeFeatures(ctx, r)
	})
	d.registerForgePlanWrites()
}

// withHierarchy sets an issue's level and feature from its labels, and its parent and progress.
func withHierarchy(i *wire.ForgeItem, parent *wire.LineageNode, total, done int) {
	for _, l := range i.Labels {
		name := strings.TrimSpace(l.Name)
		if level := strings.ToLower(name); i.Level == nil && slices.Contains(forgeLevels, level) {
			i.Level = &level
		}
		if f, ok := featureName(name); ok && i.Feature == nil {
			i.Feature = &f
		}
		if strings.EqualFold(name, standingLabel) {
			i.Standing = new(true)
		}
	}
	i.Parent = parent
	if total > 0 {
		i.Progress = &wire.ForgeProgress{Done: int64(done), Total: int64(total)}
	}
}

// featureName is the feature a label names: feature:work is work.
func featureName(label string) (string, bool) {
	if len(label) <= len(featurePrefix) || !strings.EqualFold(label[:len(featurePrefix)], featurePrefix) {
		return "", false
	}
	name := strings.TrimSpace(label[len(featurePrefix):])
	return name, name != ""
}

// planChild is a child as a forge says it, with its blockers, before it has a step.
type planChild struct {
	item      wire.ForgeItem
	blockedBy []planRef
}

type planRef struct {
	node wire.LineageNode
	open bool
}

// forgePlan is an epic's plan: its children in steps, and its lead.
func (d *Daemon) forgePlan(ctx context.Context, r wire.ForgePlanRequest) (wire.ForgePlan, error) {
	const method = "forge/plan"
	if r.Node.Kind != lineage.KindIssue {
		return wire.ForgePlan{}, Invalid("%s: the node's kind is %s, not issue", method, r.Node.Kind)
	}
	key, _ := json.Marshal([]any{method, r.Node.Ref})
	var epic wire.ForgeItem
	var children []planChild
	var standing *wire.ForgeStanding
	if a, ok := d.forgeCached(string(key)); ok && a.plan != nil {
		epic, children, standing = a.plan.epic, a.plan.children, a.plan.standing
	} else {
		var err error
		if f, ref, ok := d.forgeOwning(r.Node); ok {
			var a forgePlanAnswer
			a, err = f.Plan(ctx, ref)
			epic, children, err = a.epic, a.children, forgeCannotErr(method, f, err)
		} else if identifier, ok := strings.CutPrefix(r.Node.Ref, "linear:"); ok && linearLabel.MatchString(identifier) {
			epic, children, err = d.linearPlan(ctx, method, identifier)
		} else if key, ok := strings.CutPrefix(r.Node.Ref, "jira:"); ok && linearLabel.MatchString(key) {
			epic, children, err = d.jiraPlan(ctx, method, key)
		} else if project, id, ok := boardsOfNode(r.Node); ok {
			epic, children, err = d.boardsPlan(ctx, method, project, id)
		} else if repo, number, ok := forgejoOfNode(r.Node); ok {
			epic, children, err = d.forgejoPlan(ctx, method, repo, number)
		} else if _, _, ok := bitbucketOfNode(r.Node); ok {
			return wire.ForgePlan{}, Invalid("%s: %s", method, bitbucketNoPlan)
		} else if repo, number, ok := nodeOfRepo(r.Node); !ok {
			return wire.ForgePlan{}, Invalid("%s: %s is not an issue on GitHub, GitLab, Forgejo, Linear, Jira or Azure Boards", method, r.Node.Ref)
		} else {
			epic, children, err = d.gitlabPlan(ctx, method, repo, number)
		}
		if err != nil {
			return wire.ForgePlan{}, err
		}
		// A standing epic's plan is its query's issues, not its sub-issues (#3661), and it has
		// no "done of total".
		if epic.Standing != nil && *epic.Standing {
			var q wire.ForgeStanding
			if q, children, err = d.standingPlan(ctx, method, epic); err != nil {
				return wire.ForgePlan{}, err
			}
			standing, epic.Progress = &q, nil
		}
		d.forgeRemember(string(key), forgeAnswer{plan: &forgePlanAnswer{epic: epic, children: children, standing: standing}})
		items := []wire.ForgeItem{epic}
		for _, c := range children {
			items = append(items, c.item)
		}
		d.resolvedFromForge(items)
	}
	out := planOf(epic, children, standing != nil)
	out.Standing = standing
	// The lead is this machine's, read each time: it starts and ends more often than a plan changes.
	out.Lead = d.leadOf(r.Node)
	return out, nil
}

// planOf puts children in steps: a child's step is one more than the last step of the children
// that block it, 1 for a child no other child blocks. A blocker outside the plan adds no step,
// but an open one is said. Children in a loop, and those after them, share the step after the
// rest, so a loop in the forge's links still shows every child. A standing epic's plan is one
// step (#3661, #4200): each child is in step 1, and each open blocker is said, in the plan or not.
func planOf(epic wire.ForgeItem, children []planChild, oneStep bool) wire.ForgePlan {
	in := map[wire.LineageNode]int{}
	for n, c := range children {
		if !oneStep {
			in[c.item.Node] = n
		}
	}
	step := make([]int, len(children))
	for left := len(children); left > 0; {
		placed := 0
		for n, c := range children {
			if step[n] > 0 {
				continue
			}
			s, ready := 1, true
			for _, b := range c.blockedBy {
				if m, ok := in[b.node]; ok && m != n {
					if step[m] == 0 {
						ready = false
						break
					}
					s = max(s, step[m]+1)
				}
			}
			if ready {
				step[n] = s
				placed++
			}
		}
		left -= placed
		if placed == 0 {
			last := slices.Max(append(slices.Clone(step), 0))
			for n := range step {
				if step[n] == 0 {
					step[n] = last + 1
				}
			}
			break
		}
	}
	out := wire.ForgePlan{Item: epic, Children: []wire.ForgePlanChild{}, Steps: []wire.ForgePlanStep{}}
	for n, c := range children {
		child := wire.ForgePlanChild{Item: c.item, BlockedBy: []wire.LineageNode{}, Step: int64(step[n])}
		for _, b := range c.blockedBy {
			child.BlockedBy = append(child.BlockedBy, b.node)
			if _, ok := in[b.node]; !ok && b.open {
				child.BlockedOutside = append(child.BlockedOutside, b.node)
			}
		}
		out.Children = append(out.Children, child)
	}
	slices.SortStableFunc(out.Children, func(a, b wire.ForgePlanChild) int { return cmp.Compare(a.Step, b.Step) })
	for _, c := range out.Children {
		if len(out.Steps) == 0 || out.Steps[len(out.Steps)-1].Step != c.Step {
			out.Steps = append(out.Steps, wire.ForgePlanStep{Step: c.Step, Nodes: []wire.LineageNode{}})
		}
		s := &out.Steps[len(out.Steps)-1]
		s.Nodes = append(s.Nodes, c.Item.Node)
	}
	return out
}

// leadOf is the session on this machine that leads the epic: it works on it (from lineage, which
// its #<n> or Linear key label makes) and is labelled lead. A live one before one that ended, and
// the newest of them.
func (d *Daemon) leadOf(epic wire.LineageNode) *wire.ForgeLead {
	var best *wire.Agent
	for _, l := range d.lineage().Links(epic).Links {
		if l.To != epic || l.From.Kind != lineage.KindSession || l.Rel != lineage.RelWorksOn || l.EndedAt != nil {
			continue
		}
		id, ok := strings.CutPrefix(l.From.Ref, "session:")
		if !ok {
			continue
		}
		a := d.Store.Agent(wire.UUID(id))
		if a == nil || a.State == wire.AgentStateArchived || !slices.ContainsFunc(a.Labels, func(s wire.SessionLabel) bool { return s.Value == "lead" }) {
			continue
		}
		if best == nil || holdsRuntime(a.State) && !holdsRuntime(best.State) ||
			holdsRuntime(a.State) == holdsRuntime(best.State) && a.CreatedAt > best.CreatedAt {
			best = a
		}
	}
	if best == nil {
		return nil
	}
	return &wire.ForgeLead{Session: best.ID, Title: best.Title, State: best.State}
}

func (d *Daemon) gitlabPlan(ctx context.Context, method string, repo forgeRepo, number int) (wire.ForgeItem, []planChild, error) {
	gl, project, folder, err := d.gitlabOf(ctx, method, repo)
	if err != nil {
		return wire.ForgeItem{}, nil, err
	}
	p, err := gl.Plan(ctx, project, number)
	if err != nil {
		if gitlabmcp.IsNotFound(err) {
			return wire.ForgeItem{}, nil, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItem{}, nil, err
	}
	epic := gitlabItemOf(p.Epic, folder)
	var children []planChild
	for _, c := range p.Children {
		child := forgeRepo{"gitlab", strings.ToLower(c.Project)}
		pc := planChild{item: gitlabItemOf(c.Item, d.repoFolder(child))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: forgeRepo{"gitlab", strings.ToLower(b.Project)}.issue(b.Number), open: b.Open})
		}
		children = append(children, pc)
	}
	return epic, children, nil
}

func (d *Daemon) linearPlan(ctx context.Context, method, identifier string) (wire.ForgeItem, []planChild, error) {
	l, err := d.forgeLinear()
	if err != nil {
		return wire.ForgeItem{}, nil, err
	}
	p, err := l.Plan(ctx, identifier)
	if err != nil {
		var le *linearmcp.LinearError
		if errors.As(err, &le) && le.Kind == linearmcp.NotFound {
			return wire.ForgeItem{}, nil, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItem{}, nil, err
	}
	folderOf := d.linearFolder
	epic := linearItemOf(p.Epic, folderOf(p.Epic.Team))
	var children []planChild
	for _, c := range p.Children {
		pc := planChild{item: linearItemOf(c.Item, folderOf(c.Team))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + b.Identifier}, open: b.Open})
		}
		children = append(children, pc)
	}
	return epic, children, nil
}

// featurePages reads at most featureEpicPages pages of the issues q asks for, on r's folder and
// board, giving each to each and adding the forges that could not be read to out.Errors.
func (d *Daemon) featurePages(ctx context.Context, r wire.ForgeFeaturesRequest, out *wire.ForgeFeatures, q wire.ForgeListRequest,
	each func(wire.ForgeItem)) error {
	q.Folder, q.Board, q.Limit = r.Folder, r.Board, new(int64(forgeListMost))
	for range featureEpicPages {
		page, err := d.forgeList(ctx, false, q)
		if err != nil {
			return Invalid("forge/features: %v", strings.TrimPrefix(err.Error(), "forge/issues: "))
		}
		for _, e := range page.Errors {
			if !slices.Contains(out.Errors, e) {
				out.Errors = append(out.Errors, e)
			}
		}
		for _, i := range page.Items {
			each(i)
		}
		if page.Cursor == nil {
			return nil
		}
		q.Cursor = page.Cursor
	}
	return nil
}

// jiraPlan is a Jira epic or parent and its children (#3260), each blocked by the issues its
// Blocks links say.
func (d *Daemon) jiraPlan(ctx context.Context, method, key string) (wire.ForgeItem, []planChild, error) {
	j, err := d.forgeJira()
	if err != nil {
		return wire.ForgeItem{}, nil, err
	}
	p, err := j.Plan(ctx, key)
	if err != nil {
		var je *jiramcp.JiraError
		if errors.As(err, &je) && je.Kind == jiramcp.NotFound {
			return wire.ForgeItem{}, nil, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItem{}, nil, err
	}
	epic := jiraItemOf(p.Epic, d.jiraFolder(p.Epic.Project))
	var children []planChild
	for _, c := range p.Children {
		pc := planChild{item: jiraItemOf(c.Item, d.jiraFolder(c.Project))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: wire.LineageNode{Kind: lineage.KindIssue, Ref: "jira:" + b.Key}, open: b.Open})
		}
		children = append(children, pc)
	}
	return epic, children, nil
}

// forgeFeatures are the features on the epics of r.folder, or of every folder: the newest epics,
// open and closed (a closed epic keeps its labels), each counted under its feature:<name> label.
// issues counts each feature's open issues that are not epics (#3741), from the newest open issues,
// so a feature whose epics are closed but that has loose open work is not finished. refs, waiting
// and updatedAt are its open issues and epics, and approvals the pull requests that wait for Alex
// (#4115), so a client matches them with its sessions' labels.
func (d *Daemon) forgeFeatures(ctx context.Context, r wire.ForgeFeaturesRequest) (wire.ForgeFeatures, error) {
	out := wire.ForgeFeatures{Features: []wire.ForgeFeature{}}
	by := map[string]*wire.ForgeFeature{}
	loose := map[string]int64{}
	open := map[string]*featureWork{}
	// Bitbucket's issues have no epics (#3880): its feature:<name> components are features with
	// open issues only.
	bitbucket := map[string]string{}
	err := d.featurePages(ctx, r, &out, wire.ForgeListRequest{State: new("open")}, func(i wire.ForgeItem) {
		if i.Feature == nil {
			return
		}
		key := strings.ToLower(*i.Feature)
		openWork(open, key).add(i)
		if deref(i.Level) != "epic" {
			loose[key]++
			if _, _, ok := bitbucketOfNode(i.Node); ok && bitbucket[key] == "" {
				bitbucket[key] = *i.Feature
			}
		}
	})
	if err != nil {
		return wire.ForgeFeatures{}, err
	}
	err = d.featurePages(ctx, r, &out, wire.ForgeListRequest{State: new("all"), Label: new("epic")}, func(i wire.ForgeItem) {
		if i.Feature == nil {
			return
		}
		f := by[strings.ToLower(*i.Feature)]
		if f == nil {
			f = &wire.ForgeFeature{Name: *i.Feature, Issues: new(loose[strings.ToLower(*i.Feature)])}
			by[strings.ToLower(*i.Feature)] = f
		}
		if f.Color == nil {
			for _, l := range i.Labels {
				if name, ok := featureName(l.Name); ok && strings.EqualFold(name, f.Name) {
					f.Color = l.Color
				}
			}
		}
		f.Epics++
		if i.State == "open" {
			f.Open++
			openWork(open, strings.ToLower(*i.Feature)).add(i)
		}
	})
	if err != nil {
		return wire.ForgeFeatures{}, err
	}
	for key, name := range bitbucket {
		if by[key] == nil {
			by[key] = &wire.ForgeFeature{Name: name, Issues: new(loose[key])}
		}
	}
	for key, f := range by {
		if w := open[key]; w != nil {
			f.Refs, f.Waiting, f.UpdatedAt = w.refs, w.waiting, new(w.at)
		}
		out.Features = append(out.Features, *f)
	}
	slices.SortFunc(out.Features, func(a, b wire.ForgeFeature) int {
		return cmp.Or(cmp.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)), cmp.Compare(a.Name, b.Name))
	})
	// The pull requests that wait for Alex's approval (#3474). A forge with no pull requests, or
	// none labelled so, has none: this read adds no error of its own to the features.
	if prs, err := d.forgeList(ctx, true, wire.ForgeListRequest{Folder: r.Folder, State: new("open"), Label: new("needs-approval"),
		Limit: new(int64(forgeListMost))}); err == nil {
		for _, p := range prs.Items {
			out.Approvals = append(out.Approvals, p.Node.Ref)
		}
	}
	return out, nil
}

// featureWork is a feature's open issues and epics (#4115): each ref once, those labelled
// alex-todo, and the newest update.
type featureWork struct {
	refs, waiting []string
	seen          map[string]bool
	at            wire.Date
}

func openWork(by map[string]*featureWork, key string) *featureWork {
	if by[key] == nil {
		by[key] = &featureWork{seen: map[string]bool{}}
	}
	return by[key]
}

func (w *featureWork) add(i wire.ForgeItem) {
	if w.seen[i.Node.Ref] {
		return
	}
	w.seen[i.Node.Ref] = true
	w.refs = append(w.refs, i.Node.Ref)
	if slices.ContainsFunc(i.Labels, func(l wire.ForgeLabel) bool { return strings.EqualFold(l.Name, "alex-todo") }) {
		w.waiting = append(w.waiting, i.Node.Ref)
	}
	w.at = max(w.at, i.UpdatedAt)
}
