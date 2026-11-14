package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"maps"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/internal/safe"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Deploys in lineage (#5241, spec 5239-deploy-model, "Lineage"): the deploy.started,
// deploy.succeeded and deploy.failed events (the wire's DeployEvent, #5262) make the nodes.
//
//   - A deploy node is one try: github:deploy:<owner>/<repo>#<deployment id>. It deploys its
//     release (a v* tag names its version) or its commit, it is part-of its environment,
//     github:environment:<owner>/<repo>#<name>, and the CI run that ran its job builds it.
//   - The environment's name is the job's deploy notice's, <environment>=<artifact>, when the
//     job wrote one (an ended deploy's event says its job's notices); the old form,
//     <target>:<id>/<version>, names the target's kind (testflight). Else it is the job's forge
//     environment. A deploy that a notice moves to another environment leaves the forge one.
//   - Its details (the artifacts, the state, the start and the end) are not links: each deploy's
//     last event is kept in <root>/lineage-deploys.json, at most deploysKept, and a walk says them
//     as the deploy's resolved title, state and labels.
//   - Computed, never stored: a succeeded deploy is replaced when it is live in none of its
//     environments (#5246, below); it is a rollback when its release is older than the one it replaced;
//     and what it brings is the PRs between the last deploy that succeeded in the same
//     environment and it, from the forge's compare of their commits, as a release's are.
//   - Old target nodes and deployed-as links (#3584, #3657) are read until they age out.

const (
	// deploysKept bounds lineage-deploys.json: the deploys seen longest ago go first.
	deploysKept = 1_000
	// bringsCached bounds the brings cache: the deploys asked longest ago go first.
	bringsCached = 500
	// mostBroughtShown bounds the PRs a walk's answer says one deploy brings.
	mostBroughtShown = 100
	// bringsWorkers is how many compares run at once.
	bringsWorkers = 2
)

// deployRecord is one deploy's last event, and the environments it is part-of.
type deployRecord struct {
	Deploy wire.Deploy `json:"deploy"`
	// Environments are the environment nodes' refs.
	Environments []string `json:"environments"`
	// Seen is when the last event came.
	Seen wire.Date `json:"seen"`
}

type deploysFile struct {
	Deploys map[string]deployRecord `json:"deploys,omitempty"`
}

// bringsEntry is what a deploy brings, worked out from prev, the deploy before it.
type bringsEntry struct {
	prev string
	prs  []int
	ok   bool
	at   time.Time
}

type lineageDeployBook struct {
	deployBookMu sync.Mutex
	deployFile   *deploysFile
	brings       map[string]bringsEntry
	// bringsAsking is the deploys being worked out now; bringsSlots bounds them.
	bringsAsking map[string]bool
	bringsSlots  chan struct{}
	// bringsIdle is closed when the last deploy being worked out is done, for tests to wait on.
	bringsIdle chan struct{}
}

// deployEventPayload is a deploy.* event's details: the wire's DeployEvent, and the notices
// the job wrote, once it ended.
type deployEventPayload struct {
	wire.DeployEvent
	Notices []string `json:"notices"`
}

func (d *Daemon) deploysPath() string {
	return filepath.Join(d.Store.Loc.Root, "lineage-deploys.json")
}

func (d *Daemon) deploysFileLocked() *deploysFile {
	if d.deployFile == nil {
		d.deployFile = &deploysFile{}
		readStore(d.deploysPath(), d.deployFile, "the deploys' details start again from the next deploy events")
		if d.deployFile.Deploys == nil {
			d.deployFile.Deploys = map[string]deployRecord{}
		}
	}
	return d.deployFile
}

// deployEnded is whether a state is the end of a deploy.
func deployEnded(s wire.DeployState) bool {
	return s == wire.DeployStateSucceeded || s == wire.DeployStateFailed || s == wire.DeployStateCancelled
}

// deployNotice is one notice's environment and artifact: <environment>=<system>:<topic>/<id>,
// or <system>:<topic>/<id>, whose environment is its system (testflight).
func deployNotice(notice string) (env string, a wire.DeployArtifact, ok bool) {
	env, said, named := strings.Cut(notice, "=")
	if !named {
		said = notice
	}
	system, rest, found := strings.Cut(said, ":")
	slash := strings.LastIndex(rest, "/")
	if !found || system == "" || slash <= 0 || slash == len(rest)-1 || strings.ContainsAny(notice, " \t\n") {
		return "", a, false
	}
	if !named {
		env = system
	}
	if env == "" {
		return "", a, false
	}
	topic, id := rest[:slash], rest[slash+1:]
	ref := wire.Ref{Provider: system, Type: "artifact", Topic: topic, ID: id}.String()
	return env, wire.DeployArtifact{Kind: "build", System: system, ID: topic + "/" + id, Ref: &ref}, true
}

// runOfJob is the Actions run of a job's url, …/actions/runs/<run>/job/<job>.
var runOfJob = regexp.MustCompile(`/actions/runs/([0-9]+)(/|$)`)

// lineageDeployEvent keeps a deploy.* event's deploy and links its nodes.
func (d *Daemon) lineageDeployEvent(e wire.Event) {
	var p deployEventPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Deploy.Ref == nil {
		return
	}
	r, err := wire.ParseRef(*p.Deploy.Ref)
	if err != nil || r.Type != "deploy" || r.Topic == "" || r.ID == "" {
		return
	}
	if _, known := kindOf(r.Provider); !known {
		return
	}
	repo := forgeRepo{r.Provider, repoPath(r.Topic)}
	envs := []string{}
	for _, n := range p.Notices {
		env, a, ok := deployNotice(n)
		if !ok {
			continue
		}
		if ref := repo.node(lineage.KindEnvironment, "environment", env).Ref; !slices.Contains(envs, ref) {
			envs = append(envs, ref)
		}
		if !slices.ContainsFunc(p.Deploy.Version.Artifacts, func(x wire.DeployArtifact) bool { return x.Ref != nil && *x.Ref == *a.Ref }) {
			p.Deploy.Version.Artifacts = append(p.Deploy.Version.Artifacts, a)
		}
	}
	if len(envs) == 0 && p.Deploy.Target.Environment.Name != "" {
		envs = append(envs, repo.node(lineage.KindEnvironment, "environment", p.Deploy.Target.Environment.Name).Ref)
	}
	deploy := repo.node(lineage.KindDeploy, "deploy", r.ID)
	rec := d.keepDeploy(deploy.Ref, deployRecord{Deploy: p.Deploy, Environments: envs, Seen: wire.DateOf(nowFunc())})
	at := deployTime(rec)
	var version wire.LineageNode
	if v := rec.Deploy.Version; v.Name != nil && *v.Name != "" {
		version = repo.release(*v.Name)
	} else if sha := deploySHA(rec.Deploy); sha != "" {
		version = repo.node(lineage.KindCommit, "commit", sha)
	}
	var run wire.LineageNode
	if rec.Deploy.URL != nil {
		if m := runOfJob.FindStringSubmatch(*rec.Deploy.URL); m != nil {
			if id, err := strconv.ParseInt(m[1], 10, 64); err == nil {
				run = repo.ciRun(id)
			}
		}
	}
	d.lineageDo(func() {
		if version.Ref != "" {
			d.linkAt(deploy, version, lineage.RelDeploys, lineage.SourceForge, at)
		}
		for _, env := range rec.Environments {
			d.linkAt(deploy, wire.LineageNode{Kind: lineage.KindEnvironment, Ref: env}, lineage.RelPartOf, lineage.SourceForge, at)
		}
		// A notice that names another environment moves the deploy there.
		d.endLinks(deploy, func(l wire.LineageLink) bool {
			return l.From == deploy && l.Rel == lineage.RelPartOf && l.To.Kind == lineage.KindEnvironment &&
				!slices.Contains(rec.Environments, l.To.Ref)
		})
		if run.Ref != "" {
			d.linkAt(run, deploy, lineage.RelBuilds, lineage.SourceForge, at)
		}
	})
}

// keepDeploy keeps rec as ref's last event, and says the record kept: an event that comes
// after the deploy's end (a started polled late) does not take back its state, its artifacts
// or the environments its job's notices named.
func (d *Daemon) keepDeploy(ref string, rec deployRecord) deployRecord {
	d.deployBookMu.Lock()
	defer d.deployBookMu.Unlock()
	f := d.deploysFileLocked()
	if old, ok := f.Deploys[ref]; ok && deployEnded(old.Deploy.State) && !deployEnded(rec.Deploy.State) {
		if old.Deploy.Started == nil {
			old.Deploy.Started = rec.Deploy.Started
		}
		old.Seen = rec.Seen
		rec = old
	}
	f.Deploys[ref] = rec
	if len(f.Deploys) > deploysKept {
		refs := make([]string, 0, len(f.Deploys))
		for k := range f.Deploys {
			refs = append(refs, k)
		}
		sort.Slice(refs, func(i, j int) bool { return f.Deploys[refs[i]].Seen < f.Deploys[refs[j]].Seen })
		for _, k := range refs[:len(refs)-deploysKept] {
			delete(f.Deploys, k)
		}
	}
	if err := writeStore(d.deploysPath(), f); err != nil {
		log.Printf("lineage-deploys.json: could not save: %v", err)
	}
	return rec
}

// deployTime is when a deploy happened: its end, else its start, else when it was seen.
func deployTime(rec deployRecord) time.Time {
	switch {
	case rec.Deploy.Finished != nil:
		return rec.Deploy.Finished.Time()
	case rec.Deploy.Started != nil:
		return rec.Deploy.Started.Time()
	}
	return rec.Seen.Time()
}

// deployStart is when a deploy began, for "the deploy before it": its start, else its end.
func deployStart(rec deployRecord) time.Time {
	if rec.Deploy.Started != nil {
		return rec.Deploy.Started.Time()
	}
	return deployTime(rec)
}

// deploySHA is the commit a deploy puts out: its version's commit artifact.
func deploySHA(dep wire.Deploy) string {
	for _, a := range dep.Version.Artifacts {
		if a.Kind == "commit" {
			return a.ID
		}
	}
	return ""
}

// deployBeforeLocked is the last deploy that succeeded in one of rec's environments before rec
// began, and its ref; ok is false when there is none.
func deployBeforeLocked(f *deploysFile, ref string, rec deployRecord) (string, deployRecord, bool) {
	start := deployStart(rec)
	var best string
	var bestRec deployRecord
	for k, o := range f.Deploys {
		if k == ref || o.Deploy.State != wire.DeployStateSucceeded || !deployTime(o).Before(start) ||
			!slices.ContainsFunc(o.Environments, func(e string) bool { return slices.Contains(rec.Environments, e) }) {
			continue
		}
		if best == "" || deployTime(o).After(deployTime(bestRec)) {
			best, bestRec = k, o
		}
	}
	return best, bestRec, best != ""
}

// replacedLocked is whether a succeeded deploy is live in none of its environments: a newer
// one took all of its target's traffic (#5246).
func replacedLocked(f *deploysFile, ref string, rec deployRecord) bool {
	if rec.Deploy.State != wire.DeployStateSucceeded || len(rec.Environments) == 0 {
		return false
	}
	return liveShareLocked(f, ref, rec) == nil
}

// liveShareLocked is the share of the traffic that ref has where it is live, in per cent, the
// most of its environments'; nil when it is live in none.
func liveShareLocked(f *deploysFile, ref string, rec deployRecord) *float64 {
	var most *float64
	for _, env := range rec.Environments {
		for _, l := range liveLocked(f, env) {
			if l.ref == ref && (most == nil || l.share > *most) {
				most = new(l.share)
			}
		}
	}
	return most
}

// rollbackLocked is whether rec is a rollback: its system says so, or it succeeded with a
// release older than the one it replaced.
func rollbackLocked(f *deploysFile, ref string, rec deployRecord) bool {
	if rec.Deploy.Rollback != nil {
		return *rec.Deploy.Rollback
	}
	if rec.Deploy.State != wire.DeployStateSucceeded || rec.Deploy.Version.Name == nil {
		return false
	}
	_, before, ok := deployBeforeLocked(f, ref, rec)
	if !ok || before.Deploy.Version.Name == nil {
		return false
	}
	now, was := *rec.Deploy.Version.Name, *before.Deploy.Version.Name
	return versionTagPattern.MatchString(now) && versionTagPattern.MatchString(was) && versionLess(versionOf(now), versionOf(was))
}

// deployResolvedLocked is a deploy's details as a walk says them: its version and environments as the
// title, its state (replaced for a succeeded deploy a newer one replaced), rollback as a label,
// share:<per cent> as a label when it is live with less than all the traffic, its start, and the
// deploy itself, for the Work pages' Deployed and Live in rows (#5243).
func deployResolvedLocked(f *deploysFile, ref string, rec deployRecord) wire.LineageResolved {
	what := ""
	if v := rec.Deploy.Version; v.Name != nil {
		what = *v.Name
	} else if sha := deploySHA(rec.Deploy); sha != "" {
		what = sha[:min(len(sha), 7)]
	}
	var where []string
	for _, env := range rec.Environments {
		if r, err := wire.ParseRef(env); err == nil {
			where = append(where, r.ID)
		}
	}
	title := strings.TrimSpace(what + " to " + strings.Join(where, ", "))
	state := string(rec.Deploy.State)
	if replacedLocked(f, ref, rec) {
		state = "replaced"
	}
	dep := rec.Deploy
	out := wire.LineageResolved{Title: title, State: &state, CreatedAt: rec.Deploy.Started, Deploy: &dep}
	if rollbackLocked(f, ref, rec) {
		out.Labels = []string{"rollback"}
	}
	if share := liveShareLocked(f, ref, rec); share != nil && *share < 100 {
		out.Labels = append(out.Labels, "share:"+strconv.FormatFloat(*share, 'f', -1, 64))
	}
	return out
}

// deployGraph adds to g the details of each deploy in it and what each brings, from the cache,
// and each environment's live and next deploys as live and next links (#5246).
// A deploy whose brings the cache lacks, or holds for another deploy before it, or past
// resolveRecheck, is worked out in the background, and resolving says some are still to come.
func (d *Daemon) deployGraph(g wire.LineageGraph) wire.LineageGraph {
	type ask struct {
		ref, prev string
		repo      forgeRepo
		base      string
		head      string
	}
	var asks []ask
	pending := false
	now := nowFunc()
	in := map[wire.LineageNode]bool{}
	for _, n := range g.Nodes {
		in[n] = true
	}
	d.deployBookMu.Lock()
	f := d.deploysFileLocked()
	// An environment's live and next deploys (#5246), so the deploy pass resolves them and
	// works out what each brings.
	for _, n := range slices.Clone(g.Nodes) {
		if n.Kind != lineage.KindEnvironment {
			continue
		}
		add := func(ref, rel string, at time.Time) {
			dep := wire.LineageNode{Kind: lineage.KindDeploy, Ref: ref}
			if !in[dep] {
				in[dep] = true
				g.Nodes = append(g.Nodes, dep)
			}
			g.Links = append(g.Links, wire.LineageLink{From: n, To: dep, Rel: rel, Source: lineage.SourceComputed, At: wire.DateOf(at)})
		}
		for _, l := range liveLocked(f, n.Ref) {
			add(l.ref, lineage.RelLive, l.since)
		}
		for _, k := range nextLocked(f, n.Ref) {
			add(k, lineage.RelNext, deployStart(f.Deploys[k]))
		}
	}
	for _, n := range slices.Clone(g.Nodes) {
		rec, ok := f.Deploys[n.Ref]
		if n.Kind != lineage.KindDeploy || !ok {
			continue
		}
		if g.Resolved == nil {
			g.Resolved = map[string]wire.LineageResolved{}
		}
		g.Resolved[n.Ref] = deployResolvedLocked(f, n.Ref, rec)
		prev, before, ok := deployBeforeLocked(f, n.Ref, rec)
		r, err := wire.ParseRef(n.Ref)
		base, head := deploySHA(before.Deploy), deploySHA(rec.Deploy)
		if !ok || err != nil || base == "" || head == "" || base == head {
			continue
		}
		repo := forgeRepo{r.Provider, r.Topic}
		e, cached := d.brings[n.Ref]
		if cached && e.prev == prev && e.ok {
			at := wire.DateOf(deployTime(rec))
			shown := e.prs[:min(len(e.prs), mostBroughtShown)]
			if len(shown) < len(e.prs) {
				g.Limited = new(true)
			}
			for _, num := range shown {
				pr := repo.pr(num)
				if !in[pr] {
					in[pr] = true
					g.Nodes = append(g.Nodes, pr)
				}
				g.Links = append(g.Links, wire.LineageLink{From: n, To: pr, Rel: lineage.RelBrings, Source: lineage.SourceComputed, At: at})
			}
		}
		if cached && e.prev == prev && now.Sub(e.at) < resolveRecheck {
			continue
		}
		if !cached || e.prev != prev {
			pending = true
		}
		if !d.bringsAsking[n.Ref] {
			asks = append(asks, ask{n.Ref, prev, repo, base, head})
		}
	}
	if len(asks) > 0 {
		if d.bringsAsking == nil {
			d.bringsAsking = map[string]bool{}
			d.bringsSlots = make(chan struct{}, bringsWorkers)
		}
		if d.bringsIdle == nil {
			d.bringsIdle = make(chan struct{})
		}
		for _, a := range asks {
			d.bringsAsking[a.ref] = true
			safe.Go("deploy brings", func() { d.workOutBrings(a.ref, a.prev, a.repo, a.base, a.head) })
		}
	}
	d.deployBookMu.Unlock()
	if pending {
		g.Resolving = &pending
	}
	return g
}

// workOutBrings asks the forge for the commits between base and head, once a place is free,
// and caches their PRs as what ref brings after prev.
func (d *Daemon) workOutBrings(ref, prev string, repo forgeRepo, base, head string) {
	d.bringsSlots <- struct{}{}
	defer func() { <-d.bringsSlots }()
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	prs, ok := d.prsBetween(ctx, repo, base, head)
	d.deployBookMu.Lock()
	defer d.deployBookMu.Unlock()
	if d.brings == nil {
		d.brings = map[string]bringsEntry{}
	}
	d.brings[ref] = bringsEntry{prev: prev, prs: prs, ok: ok, at: nowFunc()}
	if len(d.brings) > bringsCached {
		oldest := ""
		for k, e := range d.brings {
			if oldest == "" || e.at.Before(d.brings[oldest].at) {
				oldest = k
			}
		}
		delete(d.brings, oldest)
	}
	delete(d.bringsAsking, ref)
	if len(d.bringsAsking) == 0 && d.bringsIdle != nil {
		close(d.bringsIdle)
		d.bringsIdle = nil
	}
}

// prsBetween is the PRs of the commits after base up to head, by their squash titles or the
// forge's commits/<sha>/pulls, as a release's (lineagerelease.go); ok is false when the forge
// could not say.
func (d *Daemon) prsBetween(ctx context.Context, repo forgeRepo, base, head string) ([]int, bool) {
	folder := d.repoFolder(repo)
	if folder == "" {
		return nil, false
	}
	compare, commitPR := forgeCompareCommits, forgeCommitPR
	if c, ok := d.connectionAsks(repo.forge); ok {
		compare, commitPR = c.compare, c.commitPR
	}
	if d.releaseCompare != nil {
		compare = d.releaseCompare
	}
	if d.releaseCommitPR != nil {
		commitPR = d.releaseCommitPR
	}
	commits, err := compare(ctx, folder, repo, base, head)
	if err != nil {
		log.Printf("lineage: the commits of %s %s..%s: %v", repo.path, base, head, err)
		return nil, false
	}
	commits = commits[:min(len(commits), releaseCommitsMax)]
	var prs []int
	for _, c := range commits {
		n, found := squashPRNumber(repo.forge, c.Message)
		if !found {
			if asked, err := commitPR(ctx, folder, repo, c.SHA); err == nil {
				n = asked
			}
		}
		if n > 0 && !slices.Contains(prs, n) {
			prs = append(prs, n)
		}
	}
	return prs, true
}

// deploySettle waits up to wait for the deploys whose brings are being worked out.
func (d *Daemon) deploySettle(wait time.Duration) {
	d.deployBookMu.Lock()
	idle := d.bringsIdle
	d.deployBookMu.Unlock()
	if idle == nil {
		return
	}
	select {
	case <-idle:
	case <-time.After(wait):
	}
}

// A target's live and next versions (#5246, spec 5239-deploy-model, "What is computed, not
// stored"), as GitOps Promoter's active and proposed. Computed from the kept deploys, never
// stored, because a deploy found late changes them. A target is one environment node (the
// repo × the environment) with the deploy's target labels (region, cluster…); with none, the
// environment node is the target.
//
//   - Live: the newest succeeded deploy's version, at its share (100 % with none), then older
//     succeeded deploys of other versions until the shares make 100 % (a canary, a Cloud Run
//     split). Since is the first of the newest unbroken run of deploys of that version.
//   - Next: the deploys waiting or running there that began after the newest live deploy
//     began. What one brings is its brings: the PRs from the live version before it.
//   - The live version of the target before it in a path comes when promotion order does.

// liveVersion is one version live in a target: the deploy that put it there, since when, and
// its share of the traffic in per cent.
type liveVersion struct {
	ref   string
	rec   deployRecord
	since time.Time
	share float64
}

// targetLabels is a deploy's target labels as one string, to tell the targets of one
// environment node apart.
func targetLabels(dep wire.Deploy) string {
	keys := slices.Sorted(maps.Keys(dep.Target.Labels))
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + dep.Target.Labels[k] + "\n")
	}
	return b.String()
}

// deployVersionKey is what tells two versions apart: the name, else the commit, else the
// artifacts' ids.
func deployVersionKey(dep wire.Deploy) string {
	if v := dep.Version.Name; v != nil && *v != "" {
		return "name:" + *v
	}
	if sha := deploySHA(dep); sha != "" {
		return "commit:" + sha
	}
	ids := make([]string, 0, len(dep.Version.Artifacts))
	for _, a := range dep.Version.Artifacts {
		ids = append(ids, a.Kind+":"+a.ID)
	}
	return "artifacts:" + strings.Join(ids, ",")
}

// targetDeploysLocked is env's deploys for each target, by its labels, newest first (by
// deployTime, then by ref so the order is stable).
func targetDeploysLocked(f *deploysFile, env string) map[string][]string {
	out := map[string][]string{}
	for k, o := range f.Deploys {
		if slices.Contains(o.Environments, env) {
			t := targetLabels(o.Deploy)
			out[t] = append(out[t], k)
		}
	}
	for _, refs := range out {
		sort.Slice(refs, func(i, j int) bool {
			a, b := deployTime(f.Deploys[refs[i]]), deployTime(f.Deploys[refs[j]])
			if !a.Equal(b) {
				return a.After(b)
			}
			return refs[i] > refs[j]
		})
	}
	return out
}

// liveOfTargetLocked is the live versions of one target, from its deploys newest first.
func liveOfTargetLocked(f *deploysFile, refs []string) []liveVersion {
	var live []liveVersion
	at := map[string]int{}
	total := 0.0
	for _, k := range refs {
		o := f.Deploys[k]
		if o.Deploy.State != wire.DeployStateSucceeded {
			continue
		}
		v := deployVersionKey(o.Deploy)
		if i, ok := at[v]; ok {
			live[i].since = deployTime(o)
			continue
		}
		if total >= 100 {
			// Older deploys of a live version move its since back, until another version.
			break
		}
		share := 100.0
		if o.Deploy.Share != nil && *o.Deploy.Share > 0 && *o.Deploy.Share < 100 {
			share = *o.Deploy.Share
		}
		share = min(share, 100-total)
		total += share
		at[v] = len(live)
		live = append(live, liveVersion{ref: k, rec: o, since: deployTime(o), share: share})
	}
	return live
}

// liveLocked is the versions live in env now, in each of its targets.
func liveLocked(f *deploysFile, env string) []liveVersion {
	var out []liveVersion
	for _, refs := range targetDeploysLocked(f, env) {
		out = append(out, liveOfTargetLocked(f, refs)...)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ref < out[j].ref })
	return out
}

// nextLocked is the deploys that will put the next versions in env, in each of its targets:
// those waiting or running that began after its newest live deploy began, oldest first.
func nextLocked(f *deploysFile, env string) []string {
	var out []string
	for _, refs := range targetDeploysLocked(f, env) {
		var after time.Time
		if live := liveOfTargetLocked(f, refs); len(live) > 0 {
			after = deployStart(live[0].rec)
		}
		for _, k := range refs {
			o := f.Deploys[k]
			if (o.Deploy.State == wire.DeployStateWaiting || o.Deploy.State == wire.DeployStateRunning) && !deployStart(o).Before(after) {
				out = append(out, k)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := deployStart(f.Deploys[out[i]]), deployStart(f.Deploys[out[j]])
		if !a.Equal(b) {
			return a.Before(b)
		}
		return out[i] < out[j]
	})
	return out
}
