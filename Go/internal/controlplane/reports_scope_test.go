package controlplane

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Report scopes (#1804): a group's lead sees each person's rows in it, or only its totals
// when the policy says so; the organisation and the policy are an admin's; a member who
// leads nothing sees only Me.
func TestReportScopesAndTheGroupLead(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	cy := p.invite(admin, "Cy", wire.UserRoleMember)
	dee := p.invite(admin, "Dee", wire.UserRoleMember)
	beas, cys, dees := p.machine(bea, "BEAS-MAC"), p.machine(cy, "CYS-MAC"), p.machine(dee, "DEES-MAC")
	var platform wire.Group
	json.Unmarshal(call(t, admin, "", "groups/set", wire.GroupSet{Name: "Platform", Members: []string{bea.id, cy.id}}), &platform)

	day := time.Now().UTC().Format(usageDayLayout)
	for _, h := range []*fakeHost{beas, cys, dees} {
		r := wire.UsageRollup{Days: []wire.UsageRollupPeriod{{At: day, Rows: []wire.UsageRollupRow{{Folder: "shop", Runtime: "claude",
			Cost: map[string]float64{"USD": 2}, Turns: 1, WorkingSeconds: 60}}}}}
		params, _ := json.Marshal(r)
		if _, err := p.s.methods.HostSaid(h.member.Host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	group := &wire.ReportScope{Kind: wire.ReportScopeKindGroup, Group: &platform.ID}
	org := &wire.ReportScope{Kind: wire.ReportScopeKindOrg}
	week := func(s *controllink.Session, scope *wire.ReportScope) wire.UsageReport {
		t.Helper()
		var r wire.UsageReport
		json.Unmarshal(call(t, s, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeWeek, Scope: scope}), &r)
		return r
	}

	// Nobody leads Platform yet: Bea sees Me alone, and is refused the group and the organisation.
	var scopes wire.ReportScopes
	json.Unmarshal(call(t, bea.window, "", "reports/scopes", map[string]any{}), &scopes)
	if len(scopes.Scopes) != 1 || scopes.Scopes[0].Scope.Kind != wire.ReportScopeKindMe || scopes.Admin {
		t.Fatalf("%+v", scopes)
	}
	for _, scope := range []*wire.ReportScope{group, org} {
		if e := callError(t, bea.window, "", "reports/usage", wire.ReportQuery{Range: wire.ReportRangeWeek, Scope: scope}); !strings.Contains(e, "Only an admin") {
			t.Fatal(e)
		}
	}
	if e := callError(t, bea.window, "", "reports/setPolicy", wire.ReportPolicy{}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}

	// The admin makes Bea Platform's lead, with a budget.
	var policy wire.ReportPolicy
	json.Unmarshal(call(t, admin, "", "reports/setPolicy", wire.ReportPolicy{Leads: map[string][]string{platform.ID: {bea.id, bea.id}},
		BudgetsUSD: map[string]float64{platform.ID: 400, "org": 0}}), &policy)
	if len(policy.Leads[platform.ID]) != 1 || policy.BudgetsUSD[platform.ID] != 400 || len(policy.BudgetsUSD) != 1 {
		t.Fatalf("%+v", policy)
	}
	if e := callError(t, admin, "", "reports/setPolicy", wire.ReportPolicy{BudgetsUSD: map[string]float64{"nowhere": 1}}); !strings.Contains(e, "No group") {
		t.Fatal(e)
	}
	json.Unmarshal(call(t, bea.window, "", "reports/scopes", map[string]any{}), &scopes)
	if len(scopes.Scopes) != 2 || scopes.Scopes[1].Name != "Platform" {
		t.Fatalf("%+v", scopes)
	}

	// Bea sees Platform's people, Cy among them, and not Dee.
	r := week(bea.window, group)
	people := map[string]bool{}
	for _, row := range r.Rows {
		people[row.PersonName] = true
		if len(row.Groups) != 1 || r.GroupNames[row.Groups[0]] != "Platform" {
			t.Fatalf("%+v", row)
		}
	}
	if len(r.Rows) != 2 || !people["Bea"] || !people["Cy"] || r.PersonsHidden != nil || r.BudgetUSD == nil || *r.BudgetUSD != 400 {
		t.Fatalf("%+v", r)
	}
	// The month's spend beside the budget, added up here (#2057): Bea's and Cy's, not Dee's.
	if r.MonthSpentUSD == nil || *r.MonthSpentUSD != 4 {
		t.Fatalf("%v", r.MonthSpentUSD)
	}

	// Totals only: the same rows, with nobody and no machine named; an admin still sees each.
	call(t, admin, "", "reports/setPolicy", wire.ReportPolicy{TotalsOnly: true, Leads: policy.Leads, BudgetsUSD: policy.BudgetsUSD})
	r = week(bea.window, group)
	if len(r.Rows) != 2 || r.PersonsHidden == nil || !*r.PersonsHidden {
		t.Fatalf("%+v", r)
	}
	for _, row := range r.Rows {
		if row.Person != "" || row.PersonName != "" || row.Host != "" || row.HostName != "" || row.Groups != nil {
			t.Fatalf("%+v", row)
		}
	}
	var csv wire.ReportExport
	json.Unmarshal(call(t, bea.window, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeWeek, Scope: group}), &csv)
	if strings.Contains(csv.Text, "Cy") || csv.Count != 2 {
		t.Fatal(csv.Text)
	}
	if r := week(admin, group); r.PersonsHidden != nil || r.Rows[0].PersonName == "" {
		t.Fatalf("%+v", r)
	}

	// The organisation, for the admin: everyone, each with their groups, in the CSV too.
	r = week(admin, org)
	if len(r.Rows) != 3 || r.Scope.Kind != wire.ReportScopeKindOrg {
		t.Fatalf("%+v", r)
	}
	json.Unmarshal(call(t, admin, "", "reports/export", wire.ReportQuery{Range: wire.ReportRangeWeek, Scope: org}), &csv)
	if !strings.Contains(csv.Text, ",groups\n") || !strings.Contains(csv.Text, ",Platform\n") {
		t.Fatal(csv.Text)
	}
}

// The scopes' methods are their own list, naming no machine (as TestEveryClientMethodChecksTheOwner
// has it for the others).
func TestReportScopeMethodsNameNoMachine(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	for method := range scopeMethods {
		if own[method] || workspaceMethods[method] || hostNamingMethods[method] || consoleMethods[method] || !p.s.methods.Handles(method) {
			t.Errorf("%s: a scope method is the scopes' alone", method)
		}
	}
}
