package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// #5272: a machine's machine/hello at a new version keeps an observed deploy of Agents to the
// machines, its target labelled with the machine, from the last time the old version was seen
// to the hello; machines/versions answers it, newest first, to the machine's person only.
func TestMachineVersionsKeepEachChangeAsAnObservedDeploy(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("OWNERS-MAC")
	host := box.member.Host
	_, owner := p.client("Owner's window")
	bea := p.invite(owner, "Bea", wire.UserRoleMember)
	hello := func(version string) {
		t.Helper()
		params, _ := json.Marshal(wire.MachineHello{Version: version, Platform: "macOS", MachineID: "OWNERS-MAC"})
		if _, err := p.s.methods.HostSaid(host, "machine/hello", params); err != nil {
			t.Fatal(err)
		}
	}
	versions := func() wire.MachineVersions {
		t.Helper()
		var v wire.MachineVersions
		if err := json.Unmarshal(call(t, owner, "", "machines/versions", wire.MachineRequest{Host: wire.MachineRef(host)}), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}

	// The fake host said its own hello at connect; the same version again is no deploy.
	hello("0.18.0")
	base := len(versions().Deploys)
	hello("0.18.0")
	before := versions()
	if before.Version != "0.18.0" || before.FirstSeen == nil || before.Seen == nil || len(before.Deploys) != base {
		t.Fatalf("the same version, no new deploy: %+v", before)
	}
	p.s.uplinkEnded(host)
	ended := versions().Seen
	if ended == nil || *ended < *before.Seen {
		t.Fatalf("the uplink's end is when it was last seen: %v, before %v", ended, before.Seen)
	}

	hello("0.18.1-dev.544+g8162a5a06")
	after := versions()
	if after.Version != "0.18.1-dev.544+g8162a5a06" || len(after.Deploys) != base+1 {
		t.Fatalf("one change: %+v", after)
	}
	d := after.Deploys[0]
	if d.System != "agents" || d.State != wire.DeployStateSucceeded || d.Observed == nil || !*d.Observed ||
		d.Target.Component.ID != "agents" || d.Target.Environment.Name != "machines" || d.Target.Labels["machine"] != host {
		t.Fatalf("deploy %+v", d)
	}
	if d.Started == nil || *d.Started != *ended || d.Finished == nil || *d.Finished != *after.FirstSeen {
		t.Fatalf("from the last time 0.18.0 was seen (%v) to the hello (%v): %+v", *ended, after.FirstSeen, d)
	}
	if a := d.Version.Artifacts; len(a) != 1 || a[0].Kind != "commit" || a[0].ID != "8162a5a06" ||
		d.Version.Name == nil || *d.Version.Name != "0.18.1-dev.544+g8162a5a06" {
		t.Fatalf("the version's commit is the sha after +g: %+v", d.Version)
	}

	// Someone else's machine is no machine of theirs.
	if e := callError(t, bea.window, "", "machines/versions", wire.MachineRequest{Host: wire.MachineRef(host)}); e == "" {
		t.Fatal("Bea read the owner's machine")
	}
	// A removed machine's versions go with it.
	if gone, err := p.s.methods.removeHost(context.Background(), host, Caller{}); err != nil || !gone {
		t.Fatal(gone, err)
	}
	if object, _ := p.s.cfg.Store.Get(context.Background(), machineVersionsKey(host)); object != nil {
		t.Fatal("kept after the machine went")
	}
}

// #5272: at most 20 deploys a machine, the oldest go first.
func TestMachineVersionsAreBounded(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx, at := context.Background(), time.Date(2026, 11, 13, 15, 0, 0, 0, time.UTC)
	for i := range mostMachineVersions + 5 {
		if err := p.s.noteVersion(ctx, "BOX", fmt.Sprintf("0.%d.0", i), at.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	v, err := p.s.machineVersions(ctx, "BOX")
	if err != nil || len(v.Deploys) != mostMachineVersions {
		t.Fatalf("%d deploys, %v", len(v.Deploys), err)
	}
	newest, oldest := v.Deploys[0], v.Deploys[len(v.Deploys)-1]
	if *newest.Version.Name != "0.24.0" || *oldest.Version.Name != "0.5.0" {
		t.Fatalf("newest %s, oldest %s", *newest.Version.Name, *oldest.Version.Name)
	}
	if a := newest.Version.Artifacts[0]; a.ID != "v0.24.0" || newest.Version.Ref == nil || *newest.Version.Ref != "github:release:"+agentsRepo+"#v0.24.0" {
		t.Fatalf("a tagged version's commit is its tag: %+v", newest.Version)
	}
}

func TestAgentsVersionOfAnotherFormHasNoCommit(t *testing.T) {
	t.Parallel()
	if a := agentsVersion("local").Artifacts; len(a) != 1 || a[0].Kind != "version" || a[0].ID != "local" {
		t.Fatalf("%+v", a)
	}
}
