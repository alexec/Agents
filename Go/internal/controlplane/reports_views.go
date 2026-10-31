package controlplane

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Saved views of Reports (#2019, R8): a page with its scope, range and way to add up, kept
// for the person who saved it, in one object per person, v1/reports/views/<user>.json. A view
// names a scope the person could see when it was saved; reports/usage checks it again
// each time, so a lead who is a lead no longer sees nothing.

const (
	reportViewsPrefix = "v1/reports/views/"
	mostReportViews   = 50
	mostViewName      = 80
)

var reportPages = map[wire.ReportPage]bool{wire.ReportPageSpend: true, wire.ReportPageOutcomes: true, wire.ReportPageTime: true,
	wire.ReportPageRuntimes: true, wire.ReportPageAdoption: true, wire.ReportPageWorkflows: true}

var reportWays = map[string]bool{"person": true, "folder": true, "machine": true, "runtime": true, "group": true, "workflow": true}

func reportViewsKey(user string) string { return reportViewsPrefix + strings.ToLower(user) + ".json" }

func (s *Service) reportViews(ctx context.Context, user string) (wire.ReportViews, error) {
	out := wire.ReportViews{Views: []wire.ReportView{}}
	object, err := s.cfg.Store.Get(ctx, reportViewsKey(user))
	if err != nil {
		return out, fail(storeUnavailable, "The saved views could not be read: %v", err)
	}
	if object != nil && json.Unmarshal(object.Data, &out) != nil || out.Views == nil {
		out.Views = []wire.ReportView{}
	}
	return out, nil
}

func (s *Service) keepReportViews(ctx context.Context, user string, views wire.ReportViews) (wire.ReportViews, error) {
	data, err := records.Encode(views)
	if err != nil {
		return views, err
	}
	// Only the person writes their own views.
	if _, err := s.cfg.Store.Put(ctx, reportViewsKey(user), data, store.Always); err != nil {
		return views, fail(storeUnavailable, "The saved views could not be kept: %v", err)
	}
	return views, nil
}

// saveReportView is reports/saveView: a new view with no id, or the one with its id changed.
func (s *Service) saveReportView(ctx context.Context, user string, v wire.ReportView) (wire.ReportViews, error) {
	v.Name = strings.TrimSpace(v.Name)
	if v.Name == "" || utf8.RuneCountInString(v.Name) > mostViewName {
		return wire.ReportViews{}, fail(invalidParams, "Name the view in 1 to %d characters.", mostViewName)
	}
	if !reportPages[v.Page] {
		return wire.ReportViews{}, fail(invalidParams, "Say a page of Reports.")
	}
	if _, ok := map[wire.ReportRange]bool{wire.ReportRangeDay: true, wire.ReportRangeWeek: true, wire.ReportRangeMonth: true,
		wire.ReportRangeThreeMonths: true}[v.Range]; !ok {
		return wire.ReportViews{}, fail(invalidParams, "Say a range: day, week, month or threeMonths.")
	}
	if v.By != nil && !reportWays[*v.By] {
		return wire.ReportViews{}, fail(invalidParams, "Say a way to add up: person, folder, machine, runtime, group or workflow.")
	}
	scopes, err := s.reportScopes(ctx, user)
	if err != nil {
		return wire.ReportViews{}, err
	}
	if !slices.ContainsFunc(scopes.Scopes, func(o wire.ReportScopeOption) bool { return sameReportScope(o.Scope, v.Scope) }) {
		return wire.ReportViews{}, fail(notPermitted, "You can save a view only of a scope you see.")
	}
	views, err := s.reportViews(ctx, user)
	if err != nil {
		return views, err
	}
	if v.ID == "" {
		if len(views.Views) >= mostReportViews {
			return views, fail(invalidParams, "Keep at most %d saved views. Delete one first.", mostReportViews)
		}
		b := make([]byte, 8)
		rand.Read(b)
		v.ID = hex.EncodeToString(b)
		views.Views = append(views.Views, v)
		return s.keepReportViews(ctx, user, views)
	}
	i := slices.IndexFunc(views.Views, func(o wire.ReportView) bool { return o.ID == v.ID })
	if i < 0 {
		return views, fail(invalidParams, "No saved view has the id %s.", v.ID)
	}
	views.Views[i] = v
	return s.keepReportViews(ctx, user, views)
}

// deleteReportView is reports/deleteView; a view already gone is no fault.
func (s *Service) deleteReportView(ctx context.Context, user, id string) (wire.ReportViews, error) {
	views, err := s.reportViews(ctx, user)
	if err != nil {
		return views, err
	}
	kept := slices.DeleteFunc(slices.Clone(views.Views), func(o wire.ReportView) bool { return o.ID == id })
	if len(kept) == len(views.Views) {
		return views, nil
	}
	views.Views = kept
	return s.keepReportViews(ctx, user, views)
}

func sameReportScope(a, b wire.ReportScope) bool {
	if a.Kind != b.Kind {
		return false
	}
	if a.Kind != wire.ReportScopeKindGroup {
		return true
	}
	return a.Group != nil && b.Group != nil && *a.Group == *b.Group
}

// viewMethod answers reports/views, reports/saveView and reports/deleteView for the caller.
func (m *Methods) viewMethod(ctx context.Context, method string, params json.RawMessage, user string) (any, error) {
	if user == "" {
		return nil, fail(notPermitted, "Sign in to save views of Reports.")
	}
	if method == "reports/views" {
		return m.s.reportViews(ctx, user)
	}
	m.mu.Lock()
	frozen := m.frozen
	m.mu.Unlock()
	if frozen {
		return nil, fail(storeUnavailable, "The control plane is moving to another machine. Nothing was changed; try again in a minute.")
	}
	if method == "reports/saveView" {
		v, err := require[wire.ReportView](params, "ReportView")
		if err != nil {
			return nil, err
		}
		return m.s.saveReportView(ctx, user, v)
	}
	id, err := require[wire.ReportViewID](params, "ReportViewID")
	if err != nil {
		return nil, err
	}
	return m.s.deleteReportView(ctx, user, id.ID)
}
