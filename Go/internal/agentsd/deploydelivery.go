package agentsd

import (
	"cmp"
	"context"
	"slices"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/internal/safe"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// deploys/delivery (#5245, spec 5239-deploy-model, board 5): the four DORA figures of each
// target this machine keeps deploys of (lineage-deploys.json, #5241), for Reports ▸ Planning ▸
// Delivery on the web page. A target is the deploy's component (its repo) in each environment
// it is part-of. Lead time needs what each deploy brings, from the forge's compare: the brings
// cache has it, and the deploys it lacks are worked out in the background, at most
// deliveryAsksAtOnce a read, so the answer says resolving and the next read has more.
//
// Decided (#5245): the machine answers, as builds/history does for the Builds page; the
// control plane's copy of the deploys, for a scope and a machine that sleeps, is its own task.

// deliveryAsksAtOnce bounds the compares one read starts.
const deliveryAsksAtOnce = 20

func (d *Daemon) registerDeploysDelivery() {
	On(d, wire.CallDeploysDelivery, func(_ context.Context, _ *Client, r wire.DeploysDeliveryRequest) (wire.DeploysDelivery, error) {
		return d.deploysDelivery(r, nowFunc()), nil
	})
}

// deliveryDays is a range's days: the last 7 for a day, as for a week.
func deliveryDays(r wire.ReportRange) int {
	switch r {
	case wire.ReportRangeMonth:
		return 30
	case wire.ReportRangeThreeMonths:
		return 90
	}
	return 7
}

// tierOrder puts production first, then staging, testing, development and other.
var tierOrder = map[wire.EnvironmentTier]int{
	wire.EnvironmentTierProduction: 0, wire.EnvironmentTierStaging: 1, wire.EnvironmentTierTesting: 2,
	wire.EnvironmentTierDevelopment: 3, wire.EnvironmentTierOther: 4,
}

// environmentTier is the tier of a deploy's environment: the forge's, when the environment is
// the forge's and the forge says one; else by its name, as the github server's tierOf; other
// when nothing says.
func environmentTier(rec deployRecord, name string) wire.EnvironmentTier {
	if env := rec.Deploy.Target.Environment; env.Name == name && env.Tier != "" && env.Tier != wire.EnvironmentTierOther {
		return env.Tier
	}
	switch strings.ToLower(name) {
	case "production", "prod":
		return wire.EnvironmentTierProduction
	case "staging", "stage":
		return wire.EnvironmentTierStaging
	case "testing", "test", "qa":
		return wire.EnvironmentTierTesting
	case "development", "dev":
		return wire.EnvironmentTierDevelopment
	}
	return wire.EnvironmentTierOther
}

func (d *Daemon) deploysDelivery(r wire.DeploysDeliveryRequest, now time.Time) wire.DeploysDelivery {
	days := deliveryDays(r.Range)
	at := wire.DateOf(now)
	since := wire.DateOf(now.Add(-time.Duration(days) * 24 * time.Hour))
	out := wire.DeploysDelivery{Since: since, At: at, WindowDays: int64(days), Targets: []wire.DeployDeliveryTarget{}}

	// The health signals seen in each deploy, read before the deploys' lock.
	health := map[string][]wire.Date{}
	links, _ := d.lineage().All()
	for _, l := range links {
		if l.Rel == lineage.RelSeenIn && l.To.Kind == lineage.KindDeploy {
			health[l.To.Ref] = append(health[l.To.Ref], l.At)
		}
	}

	type target struct {
		wire.DeployDeliveryTarget
		facts []lineage.DeployFact
	}
	targets := map[string]*target{}
	type ask struct {
		ref, prev, base, head string
		repo                  forgeRepo
		at                    wire.Date
	}
	var asks []ask
	pending := false

	d.deployBookMu.Lock()
	f := d.deploysFileLocked()
	out.Deploys = int64(len(f.Deploys))
	for ref, rec := range f.Deploys {
		r, err := wire.ParseRef(ref)
		if err != nil || r.Topic == "" {
			continue
		}
		fact := lineage.DeployFact{State: rec.Deploy.State, At: wire.DateOf(deployTime(rec)), Health: health[ref]}
		if rec.Deploy.State == wire.DeployStateSucceeded {
			fact.Rollback = rollbackLocked(f, ref, rec)
			if fact.At >= since {
				prev, before, ok := deployBeforeLocked(f, ref, rec)
				base, head := deploySHA(before.Deploy), deploySHA(rec.Deploy)
				e, cached := d.brings[ref]
				switch {
				case cached && e.prev == prev && e.ok:
					for _, n := range e.prs {
						if m, dated := e.merged[n]; dated {
							fact.Merges = append(fact.Merges, wire.DateOf(m))
						}
					}
				case ok && base != "" && head != "" && base != head && !(cached && e.prev == prev):
					pending = true
					if !d.bringsAsking[ref] {
						asks = append(asks, ask{ref, prev, base, head, forgeRepo{r.Provider, r.Topic}, fact.At})
					}
				}
			}
		}
		for _, env := range rec.Environments {
			e, err := wire.ParseRef(env)
			if err != nil || e.ID == "" {
				continue
			}
			key := r.Topic + "\x00" + env
			t := targets[key]
			if t == nil {
				t = &target{DeployDeliveryTarget: wire.DeployDeliveryTarget{Component: r.Topic, Environment: e.ID, EnvironmentRef: env,
					Tier: environmentTier(rec, e.ID)}}
				targets[key] = t
			}
			t.facts = append(t.facts, fact)
		}
	}
	// The newest deploys first, so a page's lead time fills from now back.
	slices.SortFunc(asks, func(a, b ask) int { return cmp.Compare(b.at, a.at) })
	asks = asks[:min(len(asks), deliveryAsksAtOnce)]
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

	for _, t := range targets {
		if r.Tier != nil && t.Tier != *r.Tier {
			continue
		}
		fig := lineage.DeployFiguresOf(t.facts, since, at)
		if fig.Ended == 0 {
			continue
		}
		t.Ended, t.Failed, t.Rollbacks = int64(fig.Ended), int64(fig.Failed), int64(fig.Rollbacks)
		t.DeploymentFrequency, t.LeadTime, t.ChangeFailureRate, t.RecoveryTime = fig.DeploymentFrequency, fig.LeadTime, fig.ChangeFailureRate, fig.RecoveryTime
		out.Targets = append(out.Targets, t.DeployDeliveryTarget)
	}
	slices.SortFunc(out.Targets, func(a, b wire.DeployDeliveryTarget) int {
		return cmp.Or(cmp.Compare(tierOrder[a.Tier], tierOrder[b.Tier]), cmp.Compare(b.Ended, a.Ended),
			cmp.Compare(a.Component, b.Component), cmp.Compare(a.Environment, b.Environment))
	})
	if pending {
		out.Resolving = &pending
	}
	return out
}
