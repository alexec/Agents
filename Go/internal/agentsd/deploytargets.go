package agentsd

import (
	"context"
	"maps"
	"slices"
	"sort"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// deploys/targets (#5270, Work ▸ Deploys): every target this host keeps deploys of, with its
// live and next versions as lineage computes them (#5246), so a page can draw each component in
// each environment. Read from lineage-deploys.json; nothing is stored.

func (d *Daemon) registerDeployTargets() {
	On(d, wire.CallDeploysTargets, func(_ context.Context, _ *Client, _ wire.DeployTargetsRequest) (wire.DeployTargets, error) {
		return d.deployTargets(), nil
	})
}

func (d *Daemon) deployTargets() wire.DeployTargets {
	d.deployBookMu.Lock()
	defer d.deployBookMu.Unlock()
	f := d.deploysFileLocked()
	envs := map[string]bool{}
	for _, o := range f.Deploys {
		for _, e := range o.Environments {
			envs[e] = true
		}
	}
	out := wire.DeployTargets{Targets: []wire.DeployTargetNow{}, At: wire.DateOf(nowFunc())}
	for _, env := range slices.Sorted(maps.Keys(envs)) {
		for _, refs := range targetDeploysLocked(f, env) {
			out.Targets = append(out.Targets, targetNowLocked(f, env, refs))
		}
	}
	sort.SliceStable(out.Targets, func(i, j int) bool {
		a, b := out.Targets[i].Target, out.Targets[j].Target
		if a.Environment.Name != b.Environment.Name {
			return a.Environment.Name < b.Environment.Name
		}
		if ca, cb := componentName(a.Component), componentName(b.Component); ca != cb {
			return ca < cb
		}
		return targetLabels(wire.Deploy{Target: a}) < targetLabels(wire.Deploy{Target: b})
	})
	return out
}

// componentName is what a page calls a component: its name, else its id.
func componentName(c wire.DeployComponent) string {
	if c.Name != nil && *c.Name != "" {
		return *c.Name
	}
	return c.ID
}

// targetNowLocked is one target of env, from its deploys newest first: the newest deploy's
// target, in the environment node's name (a job's notice can name another environment than its
// forge's), with its tier; its live versions, the most traffic first; its next deploys.
func targetNowLocked(f *deploysFile, env string, refs []string) wire.DeployTargetNow {
	target := f.Deploys[refs[0]].Deploy.Target
	if r, err := wire.ParseRef(env); err == nil && r.ID != target.Environment.Name {
		// The tier the forge gave is its own environment's; the notice's goes by its name when
		// its name says one.
		if tier := mcpevents.TierByName(r.ID); tier != wire.EnvironmentTierOther {
			target.Environment.Tier = tier
		}
		target.Environment.Name = r.ID
		target.Environment.URL = nil
	}
	now := wire.DeployTargetNow{Target: target, Live: []wire.DeployOnTarget{}, Next: []wire.DeployOnTarget{}}
	live := liveOfTargetLocked(f, refs)
	sort.SliceStable(live, func(i, j int) bool { return live[i].share > live[j].share })
	for _, l := range live {
		on := deployOnTargetLocked(f, l.ref, l.rec)
		on.Since = new(wire.DateOf(l.since))
		on.Share = new(l.share)
		now.Live = append(now.Live, on)
	}
	for _, k := range nextLocked(f, env) {
		o := f.Deploys[k]
		if targetLabels(o.Deploy) == targetLabels(f.Deploys[refs[0]].Deploy) {
			now.Next = append(now.Next, deployOnTargetLocked(f, k, o))
		}
	}
	return now
}

// deployOnTargetLocked is a kept deploy as the page says it: rollback set when it is one, and
// its release's lineage ref when a v* tag names its version.
func deployOnTargetLocked(f *deploysFile, ref string, rec deployRecord) wire.DeployOnTarget {
	dep := rec.Deploy
	if rollbackLocked(f, ref, rec) {
		dep.Rollback = new(true)
	}
	on := wire.DeployOnTarget{Deploy: dep}
	if v := dep.Version.Name; v != nil && versionTagPattern.MatchString(*v) {
		if r, err := wire.ParseRef(ref); err == nil {
			on.Release = new(forgeRepo{r.Provider, repoPath(r.Topic)}.release(*v).Ref)
		}
	}
	return on
}
