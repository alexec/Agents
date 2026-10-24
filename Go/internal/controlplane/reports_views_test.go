package controlplane

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Saved views (#2019, R8): each person keeps their own, of a scope they see; a change keeps
// its id, and a delete of one already gone is no fault.
func TestSavedViewsArePersonal(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	views := func(s *controllink.Session, method string, params any) wire.ReportViews {
		t.Helper()
		var v wire.ReportViews
		if err := json.Unmarshal(call(t, s, "", method, params), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	by := "folder"
	org := wire.ReportView{Name: " Monday digest ", Page: wire.ReportPageOutcomes, Scope: wire.ReportScope{Kind: wire.ReportScopeKindOrg},
		Range: wire.ReportRangeWeek, By: &by}
	got := views(admin, "reports/saveView", org)
	if len(got.Views) != 1 || got.Views[0].ID == "" || got.Views[0].Name != "Monday digest" {
		t.Fatalf("%+v", got)
	}
	saved := got.Views[0]
	saved.Range = wire.ReportRangeMonth
	if got = views(admin, "reports/saveView", saved); len(got.Views) != 1 || got.Views[0].Range != wire.ReportRangeMonth || got.Views[0].ID != saved.ID {
		t.Fatalf("%+v", got)
	}

	// Bea sees none of the admin's, and may not save a view of the organisation.
	if got = views(bea.window, "reports/views", map[string]any{}); len(got.Views) != 0 {
		t.Fatalf("%+v", got)
	}
	org.ID = ""
	if e := callError(t, bea.window, "", "reports/saveView", org); !strings.Contains(e, "only of a scope you see") {
		t.Fatal(e)
	}
	mine := wire.ReportView{Name: "Mine", Page: wire.ReportPageTime, Scope: wire.ReportScope{Kind: wire.ReportScopeKindMe}, Range: wire.ReportRangeDay}
	if got = views(bea.window, "reports/saveView", mine); len(got.Views) != 1 {
		t.Fatalf("%+v", got)
	}
	bad := "colour"
	mine.By = &bad
	if e := callError(t, bea.window, "", "reports/saveView", mine); !strings.Contains(e, "way to add up") {
		t.Fatal(e)
	}
	if e := callError(t, bea.window, "", "reports/saveView", wire.ReportView{Name: "x", Page: wire.ReportPageTime, Scope: mine.Scope,
		Range: wire.ReportRangeDay, ID: saved.ID}); !strings.Contains(e, "No saved view") {
		t.Fatal(e)
	}

	if got = views(admin, "reports/deleteView", wire.ReportViewID{ID: saved.ID}); len(got.Views) != 0 {
		t.Fatalf("%+v", got)
	}
	if got = views(admin, "reports/deleteView", wire.ReportViewID{ID: saved.ID}); len(got.Views) != 0 {
		t.Fatalf("%+v", got)
	}
}
