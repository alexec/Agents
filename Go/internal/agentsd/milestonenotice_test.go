package agentsd

import (
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// milestoneNotices is the host's notices that a milestone can be late.
func milestoneNotices(d *Daemon) []postedNotice {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	var out []postedNotice
	for _, n := range d.notices {
		if strings.HasPrefix(n.id, milestoneNoticePrefix) {
			out = append(out, n)
		}
	}
	return out
}

// #4654: a milestone whose P85 date is after its due date on GitHub posts one notice on a
// session of its issues, kept as told, so the same due date says nothing again. A P85 date on
// or before the due date, a milestone with no due date, or one whose scope still grows, gets
// none; and spend makes a milestone's forecast again at most once an hour.
func TestAMilestonePastItsDueDateTellsThePerson(t *testing.T) {
	d, _, gh, _ := forgeDaemon(t)
	lane := seeded(t, d, t.TempDir(), nil).ID
	repo := "github:repo:#alexec/agents"
	issue := wire.LineageNode{Kind: lineage.KindIssue, Ref: repo + "#1"}
	planning := "Planning"
	d.workMu.Lock()
	d.costLedgerLocked().Nodes[costKey(issue)] = wire.LineageCostNode{Node: issue, Repo: &repo, Milestone: &planning,
		Sessions: []string{sessionNode(lane).Ref}}
	d.workMu.Unlock()
	gh.milestones = []githubmcp.Milestone{{Title: "Planning", Due: "2026-11-20"}, {Title: "Later"}}
	lands := func(day int, growing bool) wire.LineageForecast {
		return wire.LineageForecast{Lands: &wire.LineageForecastLands{Growing: &growing,
			P85: wire.DateOf(time.Date(2026, 11, day, 12, 0, 0, 0, time.Local))}}
	}
	m := milestoneOf{repo, "planning"}

	d.tellMilestoneLate(m, lands(20, false))
	d.tellMilestoneLate(m, lands(27, true))
	d.tellMilestoneLate(milestoneOf{repo, "Later"}, lands(27, false))
	if n := milestoneNotices(d); len(n) != 0 {
		t.Fatalf("on time, growing or no due date: %+v", n)
	}
	d.tellMilestoneLate(m, lands(27, false))
	n := milestoneNotices(d)
	if len(n) != 1 || n[0].agentID != lane ||
		n[0].h3 != "Milestone Planning can be late: at P85 it lands by Nov 27, after its due date, Nov 20. Trim it or move its due date." {
		t.Fatalf("late: %+v", n)
	}
	d.attentionMu.Lock()
	d.notices = nil
	d.attentionMu.Unlock()
	d.tellMilestoneLate(m, lands(28, false))
	if n := milestoneNotices(d); len(n) != 0 {
		t.Fatalf("told again: %+v", n)
	}
	d.workMu.Lock()
	told := d.costLedgerLocked().MilestonesLate[m.key()]
	now := time.Now()
	first := d.milestonesDueLocked([]wire.LineageNode{issue}, now)
	again := d.milestonesDueLocked([]wire.LineageNode{issue}, now.Add(time.Minute))
	later := d.milestonesDueLocked([]wire.LineageNode{issue}, now.Add(milestoneCheckEvery))
	d.workMu.Unlock()
	if told != "2026-11-20" {
		t.Fatalf("kept as told: %q", told)
	}
	if len(first) != 1 || first[0] != (milestoneOf{repo, planning}) || len(again) != 0 || len(later) != 1 {
		t.Fatalf("checked: %+v, %+v, %+v", first, again, later)
	}
}
