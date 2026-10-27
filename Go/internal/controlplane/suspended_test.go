package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// D13: a suspended person's machine stays connected to stop their work, but nothing of
// theirs runs. Its next delivery holds no org route (and the route comes back when the
// suspension ends), and it cannot start a team workflow, check a channel link, take a git
// credential, open a tunnel or write a backup.
func TestASuspendedPersonsMachineGetsNoRouteAndStartsNothing(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), withKeeper(newKeeperKey()))
	told := newRoutesTold()
	p.told = told.heard
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	box := p.machineSaying(sam, routesHello("MACHINE-S"))
	host := box.member.Host
	p.waitFor(func() bool { _, ok := told.last(host); return ok }, "Sam's machine told at its join")
	setRoute(t, admin, wire.OrgRoute{ID: "org-openai", Name: "Org OpenAI", Kind: wire.OrgRouteKindKey,
		Vendor: vendor(wire.OrgRouteVendorOpenai), Runtimes: []string{"codex"}}, map[string]string{"apiKey": "sk-org-key"}, nil)
	p.waitFor(func() bool { return told.route(host, "org-openai") != nil }, "Sam's machine told the route")

	ctx := context.Background()
	p.s.suspend(ctx, sam.id, records.Suspension{By: "scim", Provider: "acme-okta", At: records.Now(), Why: "made inactive"},
		wire.AuditActor{User: "scim:acme-okta"})
	p.waitFor(func() bool { return told.route(host, "org-openai") == nil }, "Sam's machine told no route")
	delivery, _, err := p.s.orgDelivery(ctx, host)
	if err != nil || len(delivery.Routes) != 0 {
		t.Fatalf("%d routes, %v", len(delivery.Routes), err)
	}
	// The machine asking again gets nothing either.
	if _, err := box.uplink.Ask(t.Context(), wire.CallMachineOrgRoutesAgain.Name, wire.Empty{}); err != nil {
		t.Fatal(err)
	}
	if delivery, _, _ := p.s.orgDelivery(ctx, host); len(delivery.Routes) != 0 {
		t.Fatal("a suspended person's machine may use a route")
	}

	said := map[string]any{
		"workflows/trigger":  wire.TeamTrigger{Workflow: "app/review", Trigger: "schedule:x", RunsOn: []string{"linux"}},
		"links/check":        wire.ChannelSender{},
		"git/credential":     wire.GitCredentialRequest{},
		"tunnel/open":        wire.TunnelOpen{Runtime: "claude"},
		"backups/upload":     map[string]any{},
		"backups/commit":     map[string]any{},
		"workflows/claimRun": wire.WorkflowClaim{},
	}
	for method, params := range said {
		raw, _ := json.Marshal(params)
		_, err := p.s.methods.HostSaid(host, method, raw)
		var refused *RPCError
		if !errors.As(err, &refused) || refused.Code != personSuspended {
			t.Errorf("%s from a suspended person's machine: %v", method, err)
		}
	}
	// What it needs to stop their work still works.
	if _, err := p.s.methods.HostSaid(host, "control/ping", nil); err != nil {
		t.Fatal(err)
	}

	// The suspension ends: the route comes back.
	p.s.unsuspend(ctx, sam.id, "acme-okta", wire.AuditActor{User: "scim:acme-okta"})
	p.waitFor(func() bool { return told.route(host, "org-openai") != nil }, "Sam's machine told the route again")
	raw, _ := json.Marshal(wire.TeamTrigger{Workflow: "app/lint", Trigger: "schedule:y", RunsOn: []string{"linux"}})
	if _, err := p.s.methods.HostSaid(host, "workflows/trigger", raw); err != nil {
		t.Fatal(err)
	}
}
