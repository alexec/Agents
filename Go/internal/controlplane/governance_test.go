package controlplane

// Catalogue governance (#2019, M5): requests, approvals once per group, and who uses each
// MCP server and skill, each store with its bound.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func governanceReport(t *testing.T, p *plane, host string, items ...wire.CatalogItem) {
	t.Helper()
	params, _ := json.Marshal(wire.MachineCatalog{Items: items})
	if _, err := p.s.methods.HostSaid(host, "governance/report", params); err != nil {
		t.Fatal(err)
	}
}

func usage(t *testing.T, s *controllink.Session) wire.CatalogUsage {
	t.Helper()
	var out wire.CatalogUsage
	json.Unmarshal(call(t, s, "", "governance/usage", wire.Empty{}), &out)
	return out
}

// Each machine's report says who uses which item at which version; a machine removed
// takes its report with it.
func TestGovernanceUsageIsWhatEachMachineReports(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	samBox := p.machine(sam, "Sam's box").member.Host
	beaBox := p.machine(bea, "Bea's box").member.Host
	github := wire.CatalogItem{Kind: wire.CatalogKindMCP, Name: "github", Source: new("io.github/github"), Version: new("1.2.0")}
	older := github
	older.Version = new("1.1.0")
	skill := wire.CatalogItem{Kind: wire.CatalogKindSkills, Name: "review", Source: new("anthropics/skills"), Version: new("abc123")}
	governanceReport(t, p, samBox, github, skill, github)
	governanceReport(t, p, beaBox, older, skill)

	got := usage(t, admin)
	if got.Machines != 2 || len(got.Rows) != 3 {
		t.Fatalf("%+v", got)
	}
	// MCP servers first, then skills; a version each.
	if r := got.Rows[0]; r.Kind != wire.CatalogKindMCP || r.Version != "1.1.0" || r.Machines != 1 || r.People[0].Name != "Bea" {
		t.Fatalf("%+v", r)
	}
	if r := got.Rows[2]; r.Kind != wire.CatalogKindSkills || r.Machines != 2 || len(r.People) != 2 || r.People[0].Name != "Bea" {
		t.Fatalf("%+v", r)
	}
	// A member does not see it.
	if e := callError(t, sam.window, "", "governance/usage", wire.Empty{}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	// Bea's box leaves: its report goes.
	call(t, bea.window, "", "machines/remove", wire.MachineRequest{Host: wire.MachineRef(beaBox)})
	if o, _ := st.Get(context.Background(), governanceHostKey(beaBox)); o != nil {
		t.Fatal("a removed machine's report stayed")
	}
	if got := usage(t, admin); got.Machines != 1 || len(got.Rows) != 2 {
		t.Fatalf("%+v", got)
	}
}

// A machine's report keeps at most governanceItemsMost items.
func TestGovernanceReportIsBounded(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, admin := p.client("Alex's Mac")
	box := p.host("MACHINE-2").member.Host
	items := []wire.CatalogItem{}
	for n := range governanceItemsMost + 20 {
		items = append(items, wire.CatalogItem{Kind: wire.CatalogKindSkills, Name: fmt.Sprintf("skill-%d", n), Version: new(strings.Repeat("v", 400))})
	}
	items = append(items, wire.CatalogItem{Kind: "plugin", Name: "x"})
	governanceReport(t, p, box, items...)
	got := usage(t, admin)
	if len(got.Rows) != governanceItemsMost || len(got.Rows[0].Version) != governanceVersionMost {
		t.Fatalf("%d rows, version %d long", len(got.Rows), len(got.Rows[0].Version))
	}
}

func requests(t *testing.T, s *controllink.Session) []wire.CatalogRequest {
	t.Helper()
	var out wire.CatalogRequestList
	json.Unmarshal(call(t, s, "", "governance/requests", wire.Empty{}), &out)
	return out.Requests
}

func ask(t *testing.T, s *controllink.Session, kind wire.CatalogKind, name string) wire.CatalogRequest {
	t.Helper()
	var out wire.CatalogRequest
	json.Unmarshal(call(t, s, "", "governance/request", wire.CatalogAsk{Kind: kind, Name: name, Why: new("for reviews")}), &out)
	return out
}

// A request waits for an admin; approved for a group, it is approved at once for each of
// the group's members who ask, and the members already waiting are approved with it. A
// person outside the group still waits.
func TestGovernanceApprovesOncePerGroup(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	cy := p.invite(admin, "Cy", wire.UserRoleMember)
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{sam.id, bea.id}}), &platform)

	first := ask(t, sam.window, wire.CatalogKindMCP, "github")
	if first.State != wire.CatalogRequestStateWaiting || first.UserName != "Sam" {
		t.Fatalf("%+v", first)
	}
	// Asking again is the same request.
	if again := ask(t, sam.window, wire.CatalogKindMCP, "GitHub"); again.ID != first.ID {
		t.Fatalf("%+v", again)
	}
	beaWaits := ask(t, bea.window, wire.CatalogKindMCP, "github")
	cyWaits := ask(t, cy.window, wire.CatalogKindMCP, "github")
	if got := requests(t, admin); len(got) != 3 {
		t.Fatalf("%+v", got)
	}
	// A member sees only their own, and may not answer.
	if got := requests(t, sam.window); len(got) != 1 || got[0].ID != first.ID {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, sam.window, "", "governance/decide", wire.CatalogDecide{Request: first.ID, Approve: true}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}

	var decided wire.CatalogRequest
	json.Unmarshal(call(t, admin, "", "governance/decide", wire.CatalogDecide{Request: first.ID, Approve: true, Group: &platform.ID}), &decided)
	if decided.State != wire.CatalogRequestStateApproved || deref(decided.GroupName) != "Platform" {
		t.Fatalf("%+v", decided)
	}
	// Bea, in the group, was approved with it; Cy still waits.
	if got := requests(t, admin); len(got) != 1 || got[0].ID != cyWaits.ID {
		t.Fatalf("%+v", got)
	}
	if got := requests(t, bea.window); got[0].ID != beaWaits.ID || got[0].State != wire.CatalogRequestStateApproved {
		t.Fatalf("%+v", got)
	}
	if e := callError(t, admin, "", "governance/decide", wire.CatalogDecide{Request: first.ID, Approve: false}); !strings.Contains(e, "Another admin answered") {
		t.Fatal(e)
	}
	// Refused for Cy: no approval.
	json.Unmarshal(call(t, admin, "", "governance/decide", wire.CatalogDecide{Request: cyWaits.ID, Approve: false}), &decided)
	if decided.State != wire.CatalogRequestStateRefused {
		t.Fatalf("%+v", decided)
	}

	var approvals wire.CatalogApprovalList
	json.Unmarshal(call(t, admin, "", "governance/approvals", wire.Empty{}), &approvals)
	if len(approvals.Approvals) != 1 || deref(approvals.Approvals[0].Group) != platform.ID {
		t.Fatalf("%+v", approvals)
	}
	// Taken back: the next ask waits again.
	json.Unmarshal(call(t, admin, "", "governance/revoke", wire.CatalogRevoke{Kind: wire.CatalogKindMCP, Name: "github", Group: &platform.ID}), &approvals)
	if len(approvals.Approvals) != 0 {
		t.Fatalf("%+v", approvals)
	}
	if again := ask(t, bea.window, wire.CatalogKindMCP, "github"); again.State != wire.CatalogRequestStateWaiting {
		t.Fatalf("%+v", again)
	}
}

// An approval for one person covers only them; with the group's approval in place, a new
// member's ask is approved at once.
func TestGovernanceApprovedAtOnce(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	r := ask(t, sam.window, wire.CatalogKindSkills, "review")
	call(t, admin, "", "governance/decide", wire.CatalogDecide{Request: r.ID, Approve: true})
	// Sam's own approval: Sam asks for it again, approved at once; Bea waits.
	if again := ask(t, bea.window, wire.CatalogKindMCP, "github"); again.State != wire.CatalogRequestStateWaiting {
		t.Fatalf("%+v", again)
	}
	var group wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Reviewers", Members: []string{sam.id}}), &group)
	r = ask(t, sam.window, wire.CatalogKindMCP, "linear")
	call(t, admin, "", "governance/decide", wire.CatalogDecide{Request: r.ID, Approve: true, Group: &group.ID})
	call(t, admin, "", "groups/set", wire.GroupSet{ID: &group.ID, Name: "Reviewers", Members: []string{sam.id, bea.id}})
	if got := ask(t, bea.window, wire.CatalogKindMCP, "linear"); got.State != wire.CatalogRequestStateApproved || deref(got.GroupName) != "Reviewers" {
		t.Fatalf("%+v", got)
	}
}

// The bounds: at most governanceWaitingMost waiting per person, and a decided request goes
// after governanceDecidedKept.
func TestGovernanceRequestsAreBounded(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	_, admin := p.client("Alex's Mac")
	sam := p.invite(admin, "Sam", wire.UserRoleMember)
	for n := range governanceWaitingMost {
		ask(t, sam.window, wire.CatalogKindSkills, fmt.Sprintf("skill-%d", n))
	}
	if e := callError(t, sam.window, "", "governance/request", wire.CatalogAsk{Kind: wire.CatalogKindSkills, Name: "one more"}); !strings.Contains(e, "requests waiting") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, "", "governance/request", wire.CatalogAsk{Kind: wire.CatalogKindSkills, Name: "  "}); !strings.Contains(e, "Say which") {
		t.Fatal(e)
	}
	first := requests(t, admin)[0]
	call(t, admin, "", "governance/decide", wire.CatalogDecide{Request: first.ID, Approve: false})
	ctx := context.Background()
	later := time.Now().Add(governanceDecidedKept + time.Hour)
	if _, err := p.s.governanceRequests(ctx, later); err != nil {
		t.Fatal(err)
	}
	if o, _ := st.Get(ctx, governanceRequestKey(first.ID)); o != nil {
		t.Fatal("an old decided request stayed")
	}
	// The waiting ones stay.
	if got := requests(t, admin); len(got) != governanceWaitingMost-1 {
		t.Fatalf("%d", len(got))
	}
	// A removed person's go.
	call(t, admin, "", "people/remove", wire.PersonRequest{User: sam.id})
	if got := requests(t, admin); len(got) != 0 {
		t.Fatalf("%d", len(got))
	}
}
