package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// A node's title, state and labels from its connector (#3089): github:owner/repo#12 becomes
// its real title rather than a guess from the ref, for lineage/walk's answer. Resolved with
// the person's own gh or glab, in a folder signed in to the node's repo, as the milestone
// lookup already does (lineagemilestone.go, #2935). Resolved on demand, not polled: a
// lineage walk is read far less often than a sidebar list, so each node is asked again only
// when it is walked again after resolveRecheck, and never when no folder is signed in to ask
// with. Linear, milestones and releases are not resolved yet; a GitHub or GitLab issue or
// pull request is.
//
// Never on the walk's own path (#3102): a walk answers at once with what the cache holds
// (a node past resolveRecheck keeps its old answer while it is asked again), and the nodes it
// lacks are asked in the background, resolveWorkers at a time, each node once however many
// walks want it. The answer says resolving while any are still being asked, and the clients
// walk again shortly to pick them up.
const (
	resolveRecheck = 10 * time.Minute
	// resolvedCached bounds the cache: the nodes asked longest ago go first.
	resolvedCached = 2_000
	// resolveWorkers is how many gh or glab processes resolve nodes at once.
	resolveWorkers = 4
	// resolvePerWalk is how many nodes one walk sends to be asked, the nearest first; the
	// rest go on the next walk, which resolving asks for.
	resolvePerWalk = 50
)

// resolveLookup asks the forge for a node's title, state and labels. Tests set a daemon's
// resolveLookup in place of forgeResolveNode.
type resolveLookup func(ctx context.Context, folder string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error)

type resolvedEntry struct {
	resolved wire.LineageResolved
	ok       bool
	at       time.Time
}

type lineageResolveBook struct {
	resolveMu    sync.Mutex
	resolveCache map[wire.LineageNode]resolvedEntry
	// resolveAsking is the nodes being asked now, so two walks ask each one once.
	resolveAsking map[wire.LineageNode]bool
	// resolveSlots holds a place for each gh or glab running, at most resolveWorkers.
	resolveSlots chan struct{}
	// resolveWait counts the nodes being asked, for tests and shutdown to wait on.
	resolveWait sync.WaitGroup
	// resolveLookup, when set, is asked in place of forgeResolveNode.
	resolveLookup resolveLookup
}

// resolvedGraph is g with resolved filled in from the cache, at once. The nodes the cache
// lacks, or holds past resolveRecheck, are sent to be asked in the background, and resolving
// says some are still to come.
func (d *Daemon) resolvedGraph(g wire.LineageGraph) wire.LineageGraph {
	resolved := map[string]wire.LineageResolved{}
	var ask []wire.LineageNode
	pending := false
	now := nowFunc()
	d.resolveMu.Lock()
	for _, n := range g.Nodes {
		if _, _, ok := nodeOfRepo(n); !ok {
			continue
		}
		e, cached := d.resolveCache[n]
		if cached && e.ok {
			resolved[n.Ref] = e.resolved
		}
		if cached && now.Sub(e.at) < resolveRecheck {
			continue
		}
		if !cached {
			pending = true
		}
		if d.resolveAsking[n] || len(ask) >= resolvePerWalk {
			continue
		}
		if d.resolveAsking == nil {
			d.resolveAsking = map[wire.LineageNode]bool{}
		}
		d.resolveAsking[n] = true
		ask = append(ask, n)
	}
	if d.resolveSlots == nil {
		d.resolveSlots = make(chan struct{}, resolveWorkers)
	}
	d.resolveWait.Add(len(ask))
	d.resolveMu.Unlock()
	for _, n := range ask {
		go d.resolveInBackground(n)
	}
	if len(resolved) > 0 {
		g.Resolved = resolved
	}
	if pending {
		g.Resolving = &pending
	}
	return g
}

// resolveInBackground asks for n once a place is free, and caches the answer.
func (d *Daemon) resolveInBackground(n wire.LineageNode) {
	defer d.resolveWait.Done()
	d.resolveSlots <- struct{}{}
	defer func() { <-d.resolveSlots }()
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	d.resolveNode(ctx, n)
	d.resolveMu.Lock()
	delete(d.resolveAsking, n)
	d.resolveMu.Unlock()
}

// resolveSettle waits up to wait for the nodes being asked.
func (d *Daemon) resolveSettle(wait time.Duration) {
	done := make(chan struct{})
	go func() { d.resolveWait.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(wait):
	}
}

// resolveNode asks for n's title, state and labels and caches them; the answer is not ok when
// n is not a GitHub or GitLab issue or pull request, or no folder is signed in to ask with.
func (d *Daemon) resolveNode(ctx context.Context, n wire.LineageNode) {
	repo, num, ok := nodeOfRepo(n)
	if !ok {
		return
	}
	d.resolveMu.Lock()
	ask := d.resolveLookup
	d.resolveMu.Unlock()
	folder := d.repoFolder(repo)
	var r wire.LineageResolved
	var err error
	if folder == "" {
		err = errors.New("no folder is signed in to " + repo.forge + ":" + repo.path)
	} else {
		if ask == nil {
			ask = forgeResolveNode
		}
		r, err = ask(ctx, folder, repo, n.Kind, num)
	}
	if err != nil {
		log.Printf("lineage: resolving %s: %v", n.Ref, err)
	}
	d.resolveMu.Lock()
	defer d.resolveMu.Unlock()
	if d.resolveCache == nil {
		d.resolveCache = map[wire.LineageNode]resolvedEntry{}
	}
	if _, cached := d.resolveCache[n]; !cached && len(d.resolveCache) >= resolvedCached {
		d.dropOldestResolvedLocked()
	}
	d.resolveCache[n] = resolvedEntry{resolved: r, ok: err == nil, at: nowFunc()}
}

// dropOldestResolvedLocked makes room for one more cached node.
func (d *Daemon) dropOldestResolvedLocked() {
	var oldest wire.LineageNode
	var at time.Time
	for n, e := range d.resolveCache {
		if at.IsZero() || e.at.Before(at) {
			oldest, at = n, e.at
		}
	}
	delete(d.resolveCache, oldest)
}

// nodeOfRepo is the repo and number of a GitHub or GitLab issue or pull request node:
// github:o/r#12, gitlab:g/p!4.
func nodeOfRepo(n wire.LineageNode) (forgeRepo, int, bool) {
	if n.Kind != lineage.KindIssue && n.Kind != lineage.KindPR {
		return forgeRepo{}, 0, false
	}
	forge, rest, ok := strings.Cut(n.Ref, ":")
	if !ok || (forge != "github" && forge != "gitlab") {
		return forgeRepo{}, 0, false
	}
	sep := "#"
	if n.Kind == lineage.KindPR && forge == "gitlab" {
		sep = "!"
	}
	path, num, ok := strings.Cut(rest, sep)
	i, err := strconv.Atoi(num)
	if !ok || err != nil || i <= 0 || path == "" {
		return forgeRepo{}, 0, false
	}
	return forgeRepo{forge, path}, i, true
}

// forgeResolveNode asks gh or glab, in folder, for an issue's or pull request's title, state
// and labels.
func forgeResolveNode(ctx context.Context, folder string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error) {
	var exe, path string
	switch {
	case repo.forge == "github" && kind == lineage.KindIssue:
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/issues/%d", repo.path, n)
	case repo.forge == "github" && kind == lineage.KindPR:
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/pulls/%d", repo.path, n)
	case repo.forge == "gitlab" && kind == lineage.KindIssue:
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/issues/%d", url.PathEscape(repo.path), n)
	case repo.forge == "gitlab" && kind == lineage.KindPR:
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/merge_requests/%d", url.PathEscape(repo.path), n)
	default:
		return wire.LineageResolved{}, fmt.Errorf("no issues or pull requests on %s", repo.forge)
	}
	if exe == "" {
		return wire.LineageResolved{}, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return wire.LineageResolved{}, err
	}
	return resolvedOf(kind, out)
}

// forgeIssueOrPR is the shape of GitHub's and GitLab's own JSON for an issue or a pull
// request/merge request that resolvedOf reads from. labels is a GitHub issue's or pull
// request's array of {name}, or a GitLab issue's or merge request's array of plain strings;
// rawLabel below reads either.
type forgeIssueOrPR struct {
	Title    string            `json:"title"`
	State    string            `json:"state"`
	MergedAt *string           `json:"merged_at"`
	Labels   []json.RawMessage `json:"labels"`
}

// resolvedOf is a node's title, state and labels from the forge's own JSON for it. state is
// normalized to open, closed or merged: GitLab's issues say "opened" for open, and a GitHub
// pull request's own state says only open or closed, merged_at telling merged apart from
// closed.
func resolvedOf(kind string, out []byte) (wire.LineageResolved, error) {
	var j forgeIssueOrPR
	if err := json.Unmarshal(out, &j); err != nil || j.Title == "" {
		return wire.LineageResolved{}, errors.New("the forge did not say its title")
	}
	state := j.State
	if state == "opened" {
		state = "open"
	}
	if kind == lineage.KindPR && j.MergedAt != nil && *j.MergedAt != "" {
		state = "merged"
	}
	var labels []string
	for _, raw := range j.Labels {
		if name := rawLabel(raw); name != "" {
			labels = append(labels, name)
		}
	}
	r := wire.LineageResolved{Title: j.Title, Labels: labels}
	if state != "" {
		r.State = &state
	}
	return r, nil
}

// rawLabel is a label's name, from GitHub's {name, color} or GitLab's plain string.
func rawLabel(raw json.RawMessage) string {
	var name string
	if json.Unmarshal(raw, &name) == nil {
		return name
	}
	var obj struct {
		Name string `json:"name"`
	}
	if json.Unmarshal(raw, &obj) == nil {
		return obj.Name
	}
	return ""
}
