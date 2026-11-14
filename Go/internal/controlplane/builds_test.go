package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/citimings"
	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// buildsRunAt is a first attempt of ci.yml made at, with one job that ran 60 s and one step.
func buildsRunAt(id int64, at time.Time, onDefault bool) citimings.Run {
	r := citimings.Run{Ref: fmt.Sprintf("github:run:alexec/agents#%d", id), ID: id, Attempt: 1, Workflow: "ci.yml",
		Made: at.Unix(), Default: onDefault, Branch: "main", Conclusion: "success", Ended: 70,
		Jobs: []citimings.Job{{Name: "go", Made: 5, Started: 10, Ended: 70, Conclusion: "success", Runner: "ubuntu-latest",
			Steps: []citimings.Step{{Name: "Test", Number: 1, Started: 10, Ended: 70, Conclusion: "success"}}}}}
	if !onDefault {
		r.Branch, r.PR = "feature", 7
	}
	return r
}

func buildsDay(runs ...citimings.Run) wire.BuildsSyncDay {
	d := wire.BuildsSyncDay{Day: citimings.DayOf(runs[0].MadeAt())}
	for _, r := range runs {
		d.Runs = append(d.Runs, citimings.RunToWire(r))
	}
	return d
}

// #5232: the control plane keeps each machine's days of build timings and answers
// builds/historyAll and builds/runAll from them: two machines' runs of one repository count
// once; a member sees only their own machines; a send with no copy to go over asks for all
// again; reset drops the days not sent.
func TestBuildsCopyAnswersOverEveryMachine(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	owner := p.host("OWNERS-MAC")
	_, admin := p.client("Owner's window")
	bea := p.invite(admin, "Bea", wire.UserRoleMember)
	beas := p.machine(bea, "BEAS-MAC")
	send := func(host string, sync wire.BuildsSync) wire.BuildsSyncAnswer {
		t.Helper()
		params, _ := json.Marshal(sync)
		raw, err := p.s.methods.HostSaid(host, "builds/sync", params)
		if err != nil {
			t.Fatal(err)
		}
		var answer wire.BuildsSyncAnswer
		b, _ := json.Marshal(raw)
		_ = json.Unmarshal(b, &answer)
		return answer
	}
	now := time.Now().UTC().Truncate(time.Second)
	yesterday := now.Add(-24 * time.Hour)
	one, two, pr := buildsRunAt(1, yesterday, true), buildsRunAt(2, now.Add(-time.Hour), true), buildsRunAt(3, now.Add(-30*time.Minute), false)
	repo := "github:alexec/agents"
	main := "main"
	readAt := wire.DateOf(now)

	// No copy yet: the machine is asked for all of it.
	if a := send(owner.member.Host, wire.BuildsSync{Repo: repo, Days: []wire.BuildsSyncDay{buildsDay(two)}}); a.Full == nil || !*a.Full {
		t.Fatalf("no copy, not full: %+v", a)
	}
	if a := send(owner.member.Host, wire.BuildsSync{Repo: repo, Reset: new(true), DefaultBranch: &main, ReadAt: &readAt,
		Days: []wire.BuildsSyncDay{buildsDay(one), buildsDay(two, pr)}}); a.Full != nil {
		t.Fatalf("full again: %+v", a)
	}
	// Bea's machine reads the same repository: the same run, and one of its own.
	send(beas.member.Host, wire.BuildsSync{Repo: repo, Reset: new(true), Days: []wire.BuildsSyncDay{buildsDay(two)}})

	history := func(s *controllink.Session, scope *wire.ReportScope) wire.BuildsHistory {
		t.Helper()
		var h wire.BuildsHistory
		if err := json.Unmarshal(call(t, s, "", "builds/historyAll", wire.BuildsHistoryRequest{Repo: repo, Scope: scope,
			From: wire.DateOf(now.Add(-48 * time.Hour)), To: wire.DateOf(now.Add(time.Hour))}), &h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	org := &wire.ReportScope{Kind: wire.ReportScopeKindOrg}
	h := history(admin, org)
	if h.Reader != "github" || h.DefaultBranch == nil || *h.DefaultBranch != "main" || h.ReadAt == nil || *h.ReadAt != readAt {
		t.Fatalf("history %+v", h)
	}
	if h.Total.Runs != 2 || h.Total.Green != 2 || len(h.Workflows) != 1 || len(h.Jobs) != 1 {
		t.Fatalf("total %+v (run 2 is on both machines: once)", h.Total)
	}
	if mine := history(bea.window, nil); mine.Total.Runs != 1 || mine.ReadAt != nil {
		t.Fatalf("Bea's own %+v", mine.Total)
	}
	if e := callError(t, bea.window, "", "builds/historyAll", wire.BuildsHistoryRequest{Repo: repo, Scope: org,
		From: wire.DateOf(now.Add(-time.Hour)), To: wire.DateOf(now)}); e == "" {
		t.Fatal("a member read the organisation")
	}

	var got wire.BuildsRunAnswer
	if err := json.Unmarshal(call(t, admin, "", "builds/runAll", wire.BuildsRunRequest{Repo: repo, Ref: pr.Ref, Scope: org}), &got); err != nil {
		t.Fatal(err)
	}
	if got.Run.ID != 3 || got.Attempts != 1 || len(got.Run.Jobs) != 1 || len(got.Run.Jobs[0].Steps) != 1 || got.Before == nil || got.Before.ID != 2 {
		t.Fatalf("run %+v", got)
	}
	if e := callError(t, admin, "", "builds/runAll", wire.BuildsRunRequest{Repo: repo, Ref: "github:run:alexec/agents#99"}); e == "" {
		t.Fatal("a run no machine sent was answered")
	}

	// A day with no runs is gone; a reset drops every day it does not send.
	send(owner.member.Host, wire.BuildsSync{Repo: repo, Days: []wire.BuildsSyncDay{{Day: citimings.DayOf(one.MadeAt()), Runs: []wire.BuildsRun{}}}})
	if h := history(admin, &wire.ReportScope{Kind: wire.ReportScopeKindMe}); h.Total.Runs != 1 {
		t.Fatalf("after the day went: %+v", h.Total)
	}
	send(owner.member.Host, wire.BuildsSync{Repo: repo, Reset: new(true), Days: []wire.BuildsSyncDay{}})
	if h := history(admin, &wire.ReportScope{Kind: wire.ReportScopeKindMe}); h.Total.Runs != 0 {
		t.Fatalf("after reset: %+v", h.Total)
	}

	// What is refused: a run on another day than its own, and a repository outside the store.
	for _, bad := range []wire.BuildsSync{
		{Repo: repo, Days: []wire.BuildsSyncDay{{Day: citimings.DayOf(yesterday), Runs: []wire.BuildsRun{citimings.RunToWire(two)}}}},
		{Repo: "github:../etc", Days: []wire.BuildsSyncDay{}},
		{Repo: repo, Days: []wire.BuildsSyncDay{{Day: "13 Nov", Runs: []wire.BuildsRun{}}}},
	} {
		params, _ := json.Marshal(bad)
		if _, err := p.s.methods.HostSaid(owner.member.Host, "builds/sync", params); err == nil {
			t.Fatalf("kept %+v", bad)
		}
	}
}

// #5232: the hourly sweep applies the store's bounds to a machine that stopped sending, once
// a day, and leaves one that sends alone.
func TestBuildsSweepBoundsAStoppedMachine(t *testing.T) {
	t.Parallel()
	mem := store.NewMemory()
	p := startPlane(t, mem, controllink.NewPrivateKey())
	host := p.host("OWNERS-MAC").member.Host
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	old := buildsRunAt(1, now.AddDate(0, 0, -citimings.KeepDays-1), true)
	pr20 := buildsRunAt(2, now.AddDate(0, 0, -20), false)
	main20 := buildsRunAt(3, now.AddDate(0, 0, -20).Add(time.Minute), true)
	repo := citimings.Repo{Forge: "github", Path: "alexec/agents"}
	dir := buildsDir(host, repo)
	// As a machine's earlier sends left them: its last send two days ago.
	put := func(key string, v any) {
		t.Helper()
		data, _ := json.Marshal(v)
		if _, err := mem.Put(ctx, key, data, store.Always); err != nil {
			t.Fatal(err)
		}
	}
	twoDays := now.Add(-48 * time.Hour)
	put(dir+citimings.DayOf(old.MadeAt())+".json", map[string]any{"runs": []citimings.Run{old}, "at": records.At(twoDays)})
	put(dir+citimings.DayOf(pr20.MadeAt())+".json", map[string]any{"runs": []citimings.Run{pr20, main20}, "at": records.At(twoDays)})
	put(dir+buildsMeta, map[string]any{"at": records.At(twoDays)})

	n, err := sweepBuildTimings(ctx, mem, p.s.records, now, mostPerSweep)
	if err != nil || n == 0 {
		t.Fatalf("swept %d, %v", n, err)
	}
	if o, _ := mem.Get(ctx, dir+citimings.DayOf(old.MadeAt())+".json"); o != nil {
		t.Fatalf("the day past %d days is kept", citimings.KeepDays)
	}
	o, _ := mem.Get(ctx, dir+citimings.DayOf(pr20.MadeAt())+".json")
	var day storedBuildsDay
	if o == nil || json.Unmarshal(o.Data, &day) != nil || len(day.Runs) != 2 {
		t.Fatalf("the day of 20 days ago: %v", o)
	}
	for _, r := range day.Runs {
		if steps := len(r.Jobs[0].Steps); r.PR > 0 && steps != 0 || r.PR == 0 && steps != 1 {
			t.Fatalf("steps: a PR run's go at %d days, the default branch's stay: %+v", citimings.StepDays, r)
		}
	}
	// Once a day: a second sweep within it writes nothing.
	if n, err := sweepBuildTimings(ctx, mem, p.s.records, now.Add(time.Hour), mostPerSweep); err != nil || n != 0 {
		t.Fatalf("swept again: %d, %v", n, err)
	}

	// A machine removed a day ago: all of its copy goes.
	gone := buildsDir("GONE-MAC", repo)
	put(gone+citimings.DayOf(main20.MadeAt())+".json", map[string]any{"runs": []citimings.Run{main20}, "at": records.At(twoDays)})
	put(gone+buildsMeta, map[string]any{"at": records.At(twoDays)})
	if _, err := sweepBuildTimings(ctx, mem, p.s.records, now, mostPerSweep); err != nil {
		t.Fatal(err)
	}
	if keys, _ := mem.List(ctx, gone); len(keys) != 0 {
		t.Fatalf("a removed machine's copy is kept: %+v", keys)
	}
}
