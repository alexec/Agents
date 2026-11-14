package controlplane

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Reports ▸ Planning's Delivery row (#4555): reports/value has the delivery figures of the
// repos the scope merged most in, with the release tags' times from the merged links; a
// member sees their own machines' only; the Read API and the OTLP export say the same.
func TestReportsValueHasTheDeliveryFigures(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")

	now := time.Now()
	at := func(ago time.Duration) *wire.Date { d := wire.DateOf(now.Add(-ago)); return &d }
	str := func(s string) *string { return &s }
	const repo, other = "github:repo:#o/r", "github:repo:#o/s"
	day := 24 * time.Hour
	pr := func(r, ref string, merged time.Duration) wire.LineageCostNode {
		n := wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: ref}, Repo: str(r), Outcome: str("merged"),
			EndedAt: at(merged), FirstAt: at(merged + time.Hour), LastAt: *at(merged),
			Banked: wire.LineageCost{Cost: map[string]float64{"USD": 1}, Turns: 1}}
		return n
	}
	a := pr(repo, "github:issue:o/r#2", 3*day)
	a.PartOf = []string{"github:release:o/r#v1.0.0"}
	b := pr(repo, "github:issue:o/r#3", 2*day)
	b.PartOf = []string{"github:release:o/r#v1.1.0"}
	// Out of the 4 weeks: no figure.
	old := pr(repo, "github:issue:o/r#4", 40*day)
	theirs := pr(other, "github:issue:o/s#5", day)

	send := func(host string, work ...wire.LineageCostNode) {
		t.Helper()
		params, _ := json.Marshal(wire.UsageRollup{Hours: []wire.UsageRollupPeriod{}, Days: []wire.UsageRollupPeriod{}, Work: work})
		if _, err := p.s.methods.HostSaid(host, "usage/rollup", params); err != nil {
			t.Fatal(err)
		}
	}
	send(owner.member.Host, a, b, old)
	send(beas.member.Host, theirs)
	// The tags' links, at their commit times; the earliest of a release's is its time.
	link := func(from string, release string, ago time.Duration) wire.LineageLink {
		return wire.LineageLink{From: wire.LineageNode{Kind: "pr", Ref: from}, To: wire.LineageNode{Kind: "release", Ref: release},
			Rel: "part-of", At: *at(ago)}
	}
	if _, err := p.s.keepSyncLinks(t.Context(), owner.member.Host, []wire.LineageLink{
		link("github:issue:o/r#2", "github:release:o/r#v1.0.0", 2*day+time.Hour),
		link("github:issue:o/r#3", "github:release:o/r#v1.1.0", day),
	}, true, now); err != nil {
		t.Fatal(err)
	}

	value := func(s *controllink.Session, scope *wire.ReportScope) wire.ReportValue {
		t.Helper()
		var v wire.ReportValue
		if err := json.Unmarshal(call(t, s, "", "reports/value", wire.ReportQuery{Range: wire.ReportRangeDay, Scope: scope}), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	org := value(admin, &wire.ReportScope{Kind: wire.ReportScopeKindOrg})
	// The repo with two merges first, whatever the day's range.
	if len(org.Delivery) != 2 || org.Delivery[0].Repo != repo || org.Delivery[1].Repo != other {
		t.Fatalf("%+v", org.Delivery)
	}
	d := org.Delivery[0].Figures
	if d.WindowDays != 28 || d.DeploymentFrequency.Count != 2 || d.DeploymentFrequency.Value == nil || *d.DeploymentFrequency.Value != 0.5 ||
		d.ChangeFailureRate.Count != 2 || len(d.DeploymentFrequency.Weeks) != 4 {
		t.Fatalf("%+v", d)
	}
	if o := org.Delivery[1].Figures; o.DeploymentFrequency.Count != 0 || o.ChangeFailureRate.Count != 1 {
		t.Fatalf("%+v", o)
	}

	// Bea's own machine: the other repo only.
	if mine := value(bea.window, nil); len(mine.Delivery) != 1 || mine.Delivery[0].Repo != other {
		t.Fatalf("%+v", mine.Delivery)
	}

	// The Read API, with an admin's token: the organisation's, in JSON only.
	var made wire.ReadTokenMade
	json.Unmarshal(call(t, admin, "", "readApi/make", wire.ReadTokenMake{Name: "Looker"}), &made)
	code, body := readReports(t, p, made.Value, "?report=delivery")
	var read struct {
		Delivery []wire.ReportDelivery `json:"delivery"`
	}
	if code != http.StatusOK || json.Unmarshal([]byte(body), &read) != nil || len(read.Delivery) != 2 || read.Delivery[0].Repo != repo {
		t.Fatalf("%d %s", code, body)
	}
	if code, _ := readReports(t, p, made.Value, "?report=delivery&format=csv"); code != http.StatusBadRequest {
		t.Fatal(code)
	}

	// OTLP: a gauge a figure, by repo, and no machine or person named.
	raw, err := p.s.otlpBody(t.Context(), now)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, want := range []string{`"agents.delivery.deployment_frequency"`, `"agents.delivery.change_failure_rate"`, `"gauge"`,
		`"stringValue":"github:repo:#o/s"`} {
		if !strings.Contains(text, want) {
			t.Fatalf("no %s in %s", want, text)
		}
	}
	for _, never := range []string{"OWNERS-MAC", "BEAS-MAC", "Bea"} {
		if strings.Contains(text, never) {
			t.Fatalf("%s named in %s", never, text)
		}
	}
}
