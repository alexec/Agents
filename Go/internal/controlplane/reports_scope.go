package controlplane

import (
	"context"
	"encoding/json"
	"math"
	"slices"
	"sort"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Report scopes (#1804): one report, three zoom levels. Me is the caller's own machines;
// a group is its people's and its bots' machines, for an admin and the group's leads; the
// organisation is every machine, for an admin. A group lead sees each person's spend and
// time, unless an admin's policy says totals only (Alex, decision 2).
//
// The policy is one object, v1/reports/policy.json, read on each call, so every copy of
// the control plane answers the same.

// scopeMethods are the scopes', their policy's (#1804) and the saved views' (#2019): each
// names no machine and checks its caller itself; reports/policy and reports/setPolicy are
// an admin's.
var scopeMethods = map[string]bool{"reports/scopes": true, "reports/policy": true, "reports/setPolicy": true,
	"reports/views": true, "reports/saveView": true, "reports/deleteView": true}

const reportPolicyKey = "v1/reports/policy.json"

// orgBudget is the organisation's key among the budgets.
const orgBudget = "org"

// mostBudgetUSD bounds a budget, so a slip of the keyboard is refused.
const mostBudgetUSD = 10_000_000

func (s *Service) reportPolicy(ctx context.Context) (wire.ReportPolicy, error) {
	policy := wire.ReportPolicy{Leads: map[string][]string{}, BudgetsUSD: map[string]float64{}}
	object, err := s.cfg.Store.Get(ctx, reportPolicyKey)
	if err != nil {
		return policy, fail(storeUnavailable, "The report policy could not be read: %v", err)
	}
	if object != nil {
		json.Unmarshal(object.Data, &policy)
	}
	if policy.Leads == nil {
		policy.Leads = map[string][]string{}
	}
	if policy.BudgetsUSD == nil {
		policy.BudgetsUSD = map[string]float64{}
	}
	return policy, nil
}

// setReportPolicy keeps an admin's policy: leads of groups that are there and are people,
// budgets of groups that are there or the organisation, each above nothing.
func (s *Service) setReportPolicy(ctx context.Context, p wire.ReportPolicy) (wire.ReportPolicy, error) {
	out := wire.ReportPolicy{TotalsOnly: p.TotalsOnly, Leads: map[string][]string{}, BudgetsUSD: map[string]float64{}}
	for group, leads := range p.Leads {
		if s.records.Group(group) == nil {
			return out, fail(invalidParams, "No group has the id %s.", group)
		}
		kept := []string{}
		for _, user := range leads {
			person := s.records.Person(user)
			if person == nil || person.IsRemoved() || person.IsBot() {
				return out, fail(invalidParams, "Only a person can lead a group.")
			}
			if !slices.Contains(kept, user) {
				kept = append(kept, user)
			}
		}
		if len(kept) > 0 {
			sort.Strings(kept)
			out.Leads[group] = kept
		}
	}
	for key, usd := range p.BudgetsUSD {
		if key != orgBudget && s.records.Group(key) == nil {
			return out, fail(invalidParams, "No group has the id %s.", key)
		}
		if math.IsNaN(usd) || usd < 0 || usd > mostBudgetUSD {
			return out, fail(invalidParams, "A budget is from $0 to $%d a month.", mostBudgetUSD)
		}
		if usd > 0 {
			out.BudgetsUSD[key] = usd
		}
	}
	data, err := records.Encode(out)
	if err != nil {
		return out, err
	}
	if _, err := s.cfg.Store.Put(ctx, reportPolicyKey, data, store.Always); err != nil {
		return out, fail(storeUnavailable, "The report policy could not be kept: %v", err)
	}
	return out, nil
}

// leads says whether a user leads a group, by the policy.
func leads(policy wire.ReportPolicy, group, user string) bool {
	return slices.Contains(policy.Leads[group], user)
}

// reportScopes is reports/scopes: Me, the groups the caller may see, and the
// organisation for an admin.
func (s *Service) reportScopes(ctx context.Context, user string) (wire.ReportScopes, error) {
	admin := s.isAdmin(user)
	policy, err := s.reportPolicy(ctx)
	if err != nil {
		return wire.ReportScopes{}, err
	}
	out := wire.ReportScopes{Admin: admin, Scopes: []wire.ReportScopeOption{{Scope: wire.ReportScope{Kind: wire.ReportScopeKindMe}, Name: "Me"}}}
	for _, g := range s.records.Groups() {
		if admin || leads(policy, g.ID, user) {
			id := g.ID
			out.Scopes = append(out.Scopes, wire.ReportScopeOption{Scope: wire.ReportScope{Kind: wire.ReportScopeKindGroup, Group: &id}, Name: g.Name})
		}
	}
	if admin {
		name := s.cfg.Name
		if settings := s.records.Settings(); settings != nil && settings.Name != "" {
			name = settings.Name
		}
		if name == "" {
			name = "Everyone"
		}
		out.Scopes = append(out.Scopes, wire.ReportScopeOption{Scope: wire.ReportScope{Kind: wire.ReportScopeKindOrg}, Name: name})
	}
	return out, nil
}

// reportScope is whose rows a scope keeps, and the group it names, or why the caller may
// not see it. With no scope, an admin's is the organisation and a member's their own.
func (s *Service) reportScope(ctx context.Context, scope *wire.ReportScope, user string, admin bool) (*wire.ReportScope, func(person string) bool, *records.Group, error) {
	if scope == nil {
		// Before scopes (#1811): an admin every person, a member their own.
		kind := wire.ReportScopeKindMe
		if admin {
			kind = wire.ReportScopeKindOrg
		}
		scope = &wire.ReportScope{Kind: kind}
	}
	switch scope.Kind {
	case wire.ReportScopeKindMe:
		return scope, func(person string) bool { return person == user }, nil, nil
	case wire.ReportScopeKindOrg:
		if !admin {
			return nil, nil, nil, fail(notPermitted, "Only an admin sees the whole organisation's reports.")
		}
		return scope, func(string) bool { return true }, nil, nil
	case wire.ReportScopeKindGroup:
		var group *records.Group
		if scope.Group != nil {
			group = s.records.Group(*scope.Group)
		}
		if group == nil {
			return nil, nil, nil, fail(invalidParams, "Say a group that is there.")
		}
		if !admin {
			policy, err := s.reportPolicy(ctx)
			if err != nil {
				return nil, nil, nil, err
			}
			if !leads(policy, group.ID, user) {
				return nil, nil, nil, fail(notPermitted, "Only an admin or a lead of %s sees its reports.", group.Name)
			}
		}
		// A member, or a bot of the group (groups.go).
		return scope, func(person string) bool { return person != "" && s.inGroup(person, group.ID) }, group, nil
	}
	return nil, nil, nil, fail(invalidParams, "Say a scope: me, group or org.")
}

// scopedReport is reports/usage for a scope: the rows the caller may see, each person's
// groups for a group or the organisation, and nobody named for a group lead when the
// policy says totals only.
func (s *Service) scopedReport(ctx context.Context, r wire.ReportRange, scope *wire.ReportScope, user string) (wire.UsageReport, error) {
	admin := s.isAdmin(user)
	scope, keep, group, err := s.reportScope(ctx, scope, user, admin)
	if err != nil {
		return wire.UsageReport{}, err
	}
	policy, err := s.reportPolicy(ctx)
	if err != nil {
		return wire.UsageReport{}, err
	}
	hidden, budgetKey := false, ""
	switch scope.Kind {
	case wire.ReportScopeKindOrg:
		budgetKey = orgBudget
	case wire.ReportScopeKindGroup:
		hidden, budgetKey = !admin && policy.TotalsOnly, group.ID
	}
	rows, err := s.report(ctx, r, keep, time.Now())
	if err != nil {
		return wire.UsageReport{}, err
	}
	out := wire.UsageReport{Range: r, Rows: rows, Admin: admin, Scope: scope}
	if scope.Kind != wire.ReportScopeKindMe {
		groups := s.records.Groups()
		names := map[string]string{}
		of := map[string][]string{}
		for i := range rows {
			person := rows[i].Person
			if hidden {
				rows[i].Person, rows[i].PersonName, rows[i].Host, rows[i].HostName = "", "", "", ""
				continue
			}
			ids, known := of[person]
			if !known {
				ids = []string{}
				for _, g := range groups {
					if person != "" && s.inGroup(person, g.ID) {
						ids = append(ids, g.ID)
						names[g.ID] = g.Name
					}
				}
				of[person] = ids
			}
			rows[i].Groups = ids
		}
		if len(names) > 0 {
			out.GroupNames = names
		}
		if hidden {
			out.PersonsHidden = &hidden
		}
	}
	if usd, ok := policy.BudgetsUSD[budgetKey]; ok && budgetKey != "" {
		out.BudgetUSD = &usd
		if spent, err := s.monthSpentUSD(ctx, keep, time.Now()); err == nil {
			out.MonthSpentUSD = &spent
		}
	}
	return out, nil
}
