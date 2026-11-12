package agentsd

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

func (f *fakeForgeGitHub) Timeline(_ context.Context, repo, _ string) (githubmcp.Timeline, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.timelines++
	return f.timeline, nil
}

// #4172: work/timeline gives a project's epics that overlap the window, each child with its
// start (lineage's first session, else the first PR, else its close), the epic's segments, and
// the open one's forecast; children that wait for a person are not forecast; the releases in
// the window; the backtest; and a read again within forgeCacheFor asks GitHub nothing.
func TestWorkTimelineForecastsTheOpenEpics(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	var folder string
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).path == "alexec/agents" {
			folder = f
			break
		}
	}
	os.MkdirAll(filepath.Join(folder, ".agents"), 0o755)
	os.WriteFile(filepath.Join(folder, folderConfig), []byte(`{"project":"p1"}`), 0o644)

	now := time.Now().UTC().Truncate(time.Minute)
	stamp := func(h float64) string { return now.Add(time.Duration(h * float64(time.Hour))).Format(time.RFC3339) }
	number := 100
	child := func(filed, closed float64, labels ...string) githubmcp.TimelineChild {
		number++
		c := githubmcp.TimelineChild{Item: githubmcp.Item{Repo: "alexec/Agents", Number: number, State: "open", Title: "child " + strconv.Itoa(number), Labels: labels,
			CreatedAt: stamp(filed)}}
		if closed != 0 {
			c.State, c.ClosedAt, c.StateReason = "closed", stamp(closed), "completed"
			c.PROpenedAt = []string{stamp(closed - 1)}
		}
		return c
	}
	epic := func(n int, closed float64, kids ...githubmcp.TimelineChild) githubmcp.TimelineEpic {
		e := githubmcp.TimelineEpic{Item: githubmcp.Item{Repo: "alexec/Agents", Number: n, State: "open", Title: "epic " + strconv.Itoa(n), Labels: []string{"epic"},
			CreatedAt: stamp(-24 * 40)}, Children: kids}
		if closed != 0 {
			e.State, e.ClosedAt, e.StateReason = "closed", stamp(closed), "completed"
		}
		return e
	}
	var epics []githubmcp.TimelineEpic
	// Four closed epics in the last 30 days, of 4 children each, to learn from.
	for i := range 4 {
		base := float64(-24 * (20 - 4*i))
		epics = append(epics, epic(10+i, base+9, child(base, base+2), child(base, base+4), child(base, base+6), child(base, base+8)))
	}
	open := epic(20, 0, child(-10, -6), child(-10, -3), child(-10, 0), child(-10, 0), child(-10, 0, "alex-todo"))
	open.Children[1].Labels, open.Children[1].LabelColors = []string{"bug", "ui"}, map[string]string{"bug": "#d73a4a"}
	epics = append(epics, open,
		epic(21, 0),                                 // no children: not drawn
		epic(22, -24*60, child(-24*62, -24*61)),     // ended before the window
		epic(23, 0, child(-48, -40), child(-20, 0))) // filed after the first line ended: a second line
	gh.timeline = githubmcp.Timeline{Epics: epics, Releases: []githubmcp.Release{
		{Tag: "v1", PublishedAt: stamp(-5), URL: "u1"}, {Tag: "v0", PublishedAt: stamp(-24 * 9)}}}
	// A session worked on the first open child: it started then, though no PR closes it yet.
	first := forgeRepo{"github", "alexec/agents"}.issue(open.Children[2].Number)
	d.lineage().Link(wire.LineageLinkRequest{From: wire.LineageNode{Kind: lineage.KindSession, Ref: "agents:session:#A"}, To: first,
		Rel: lineage.RelWorksOn, Source: lineage.SourceStart}, now.Add(-8*time.Hour))

	req := wire.WorkTimelineRequest{Project: "p1", From: wire.DateOf(now.Add(-24 * time.Hour)), To: wire.DateOf(now.Add(24 * time.Hour))}
	var tl wire.WorkTimeline
	if err := json.Unmarshal(c.call(t, 1, "work/timeline", req), &tl); err != nil {
		t.Fatal(err)
	}
	if len(tl.Errors) > 0 || len(tl.Releases) != 1 || tl.Releases[0].Tag != "v1" || tl.Releases[0].Repo != "alexec/agents" {
		t.Fatalf("errors %v, releases %+v", tl.Errors, tl.Releases)
	}
	got := map[int]wire.WorkTimelineEpic{}
	for _, e := range tl.Epics {
		n, _ := strconv.Atoi(e.Item.Node.Ref[len("github:issue:alexec/agents#"):])
		got[n] = e
	}
	if len(got) != 2 || got[20].Item.Title == "" || got[23].Item.Title == "" {
		t.Fatalf("epics in the window: %v", tl.Epics)
	}
	e := got[20]
	if e.Forecast == nil || e.Forecast.Waits == nil || !(e.Forecast.Low <= e.Forecast.Mid && e.Forecast.Mid <= e.Forecast.High) || e.Forecast.Low < wire.DateOf(now) {
		t.Fatalf("forecast %+v", e.Forecast)
	}
	if len(e.Segments) != 1 || e.Segments[0].ClosedAt != nil || *e.Segments[0].StartedAt != wire.DateOf(now.Add(-8*time.Hour)) {
		t.Fatalf("segments %+v", e.Segments)
	}
	kids := e.Children
	if *kids[2].StartedAt != wire.DateOf(now.Add(-8*time.Hour)) || kids[3].StartedAt != nil || *kids[0].StartedAt != forgeDate(stamp(-7)) {
		t.Fatalf("starts: %v, %v, %v", kids[2].StartedAt, kids[3].StartedAt, kids[0].StartedAt)
	}
	if kids[2].ForecastAt == nil || kids[3].ForecastAt == nil || kids[4].ForecastAt != nil || kids[4].WaitsForPerson == nil || kids[0].ForecastAt != nil {
		t.Fatalf("children: %+v", kids)
	}
	// The children's labels, with their colours, for the hover card's chips (#4428).
	if l := kids[1].Item.Labels; len(l) != 2 || l[0].Name != "bug" || l[0].Color == nil || *l[0].Color != "#d73a4a" || l[1].Name != "ui" || l[1].Color != nil {
		t.Fatalf("labels %+v", l)
	}
	if s := got[23].Segments; len(s) != 2 || s[0].ClosedAt == nil || s[1].ClosedAt != nil || got[23].Forecast == nil {
		t.Fatalf("a child filed after the line ended starts a second: %+v", got[23])
	}
	if tl.Backtest == nil || tl.Backtest.Cuts == 0 || tl.Backtest.Error < 1 {
		t.Fatalf("backtest %+v", tl.Backtest)
	}
	var again wire.WorkTimeline
	json.Unmarshal(c.call(t, 2, "work/timeline", req), &again)
	gh.mu.Lock()
	reads := gh.timelines
	gh.mu.Unlock()
	// The same seed gives the same forecast; only the clock moved between the reads.
	if reads != 1 || math.Abs(float64(again.Epics[0].Forecast.Mid-tl.Epics[0].Forecast.Mid)) > 1 {
		t.Fatalf("%d reads; forecasts %v and %v", reads, again.Epics[0].Forecast, tl.Epics[0].Forecast)
	}
	if err := c.callError(t, 3, "work/timeline", wire.WorkTimelineRequest{Project: "p1", From: 10, To: 5}); err == nil {
		t.Fatal("to before from is not refused")
	}
}
