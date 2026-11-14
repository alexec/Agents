package agentsd

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// ciStepRuns is 200 default-branch runs of ci.yml, an hour apart up to end: go-darwin's
// run time steps from before to after at run 121.
func ciStepRuns(end time.Time, before, after float64) []citimings.Run {
	rng := rand.New(rand.NewPCG(1, 2))
	start := end.Add(-199 * time.Hour)
	var runs []citimings.Run
	for i := range 200 {
		ran := before
		if i >= 120 {
			ran = after
		}
		ran *= 1 + (rng.Float64()-0.5)*0.1
		runs = append(runs, citimings.Run{Ref: fmt.Sprintf("github:run:alexec/agents#%d", i+1), ID: int64(i + 1), Attempt: 1,
			Workflow: "ci.yml", Made: start.Add(time.Duration(i) * time.Hour).Unix(), Default: true, Conclusion: "success",
			Branch: "main", URL: fmt.Sprintf("https://github.com/alexec/agents/actions/runs/%d", i+1),
			Jobs: []citimings.Job{{Name: "go-darwin", Made: 10, Started: 15, Ended: 15 + ran, Conclusion: "success"}}})
	}
	return runs
}

func ciSlowedEvents(d *Daemon) []wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	var out []wire.Event
	for _, e := range d.eventList {
		if e.Name == ciSlowedName {
			out = append(out, e)
		}
	}
	return out
}

func ciSlowedDaemon(t *testing.T) (*Daemon, string) {
	t.Helper()
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Shutdown)
	folder := t.TempDir()
	if err := os.MkdirAll(filepath.Join(folder, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := d.Store.SaveFolders([]wire.Folder{{Folder: store.FolderURL(folder), AddedAt: now()}}); err != nil {
		t.Fatal(err)
	}
	d.repoMu.Lock()
	d.repos = map[string]forgeRepo{store.FolderPath(store.FolderURL(folder)): {"github", "alexec/agents"}}
	d.repoMu.Unlock()
	d.ciMu.Lock()
	d.ciRepoLocked("github:alexec/agents").Default = "main"
	d.ciMu.Unlock()
	return d, folder
}

func TestCISlowedIsSentOnceForAStepUp(t *testing.T) {
	d, _ := ciSlowedDaemon(t)
	repo := citimings.Repo{Forge: "github", Path: "alexec/agents"}
	end := time.Now().UTC().Truncate(time.Second)
	if err := d.ciTimings().Put(repo, ciStepRuns(end, 290, 380)...); err != nil {
		t.Fatal(err)
	}
	d.ciChanged(repo.String())
	d.ciSendSlowed(repo)
	got := ciSlowedEvents(d)
	if len(got) != 1 {
		t.Fatalf("ci.slowed sent %d times, want 1: %+v", len(got), got)
	}
	e := got[0]
	want := map[string]string{"repo": "alexec/agents", "workflow": "ci.yml", "job": "go-darwin", "branch": "main",
		"first_slow_run": "github:run:alexec/agents#121", "last_fast_run": "github:run:alexec/agents#120",
		"first_slow_run_url": "https://github.com/alexec/agents/actions/runs/121",
		"last_fast_run_url":  "https://github.com/alexec/agents/actions/runs/120"}
	for k, v := range want {
		if e.Details[k] != v {
			t.Errorf("%s = %q, want %q", k, e.Details[k], v)
		}
	}
	for _, k := range []string{"median_before", "median_after", "score"} {
		if e.Details[k] == "" {
			t.Errorf("no %s", k)
		}
	}
	if e.Scope.Folder == nil {
		t.Fatalf("scope %+v, want the folder", e.Scope)
	}
	// The same on every machine, so the bus keeps one copy.
	if e.ID == nil || *e.ID != "github:run:alexec/agents#121@ci.slowed/ci.yml/go-darwin" {
		t.Fatalf("envelope id %v", e.ID)
	}
	if kindNamed(ciSlowedName) == nil || isServerEventName(ciSlowedName) {
		t.Fatal("ci.slowed is not the app's event in the catalogue")
	}

	// The finder again, and after a restart of what it found: nothing more.
	d.ciChanged(repo.String())
	d.ciSendSlowed(repo)
	if n := len(ciSlowedEvents(d)); n != 1 {
		t.Fatalf("sent %d times after the finder ran again", n)
	}

	// builds/history says when it was sent.
	hist, err := d.buildsHistory(wire.BuildsHistoryRequest{Repo: repo.String(),
		From: wire.DateOf(end.Add(-10 * 24 * time.Hour)), To: wire.DateOf(end.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	if len(hist.Changes) != 1 || hist.Changes[0].SlowedSent == nil {
		t.Fatalf("changes %+v", hist.Changes)
	}
}

func TestCISlowedNotSentForASpeedUpOrAnOldChange(t *testing.T) {
	for name, tc := range map[string]struct {
		end           time.Time
		before, after float64
	}{
		"a speed-up":    {time.Now().UTC(), 380, 290},
		"an old change": {time.Now().UTC().Add(-20 * 24 * time.Hour), 290, 380},
	} {
		t.Run(name, func(t *testing.T) {
			d, _ := ciSlowedDaemon(t)
			repo := citimings.Repo{Forge: "github", Path: "alexec/agents"}
			if err := d.ciTimings().Put(repo, ciStepRuns(tc.end.Truncate(time.Second), tc.before, tc.after)...); err != nil {
				t.Fatal(err)
			}
			changes, err := d.ciChangesOf(repo)
			if err != nil || len(changes) != 1 {
				t.Fatalf("changes %+v %v", changes, err)
			}
			d.ciSendSlowed(repo)
			if got := ciSlowedEvents(d); len(got) != 0 {
				t.Fatalf("sent %+v", got)
			}
		})
	}
}

func TestCISlowedTheSameChangeARunAwayIsNotSentAgain(t *testing.T) {
	c := citimings.Change{Workflow: "ci.yml", Job: "go-darwin", FirstSlow: citimings.Run{Ref: "github:run:alexec/agents#122", Made: 1000 + 3600}}
	sent := map[string]ciSlowedSent{"github:run:alexec/agents#121@ci.slowed/ci.yml/go-darwin": {Workflow: "ci.yml", Job: "go-darwin", Made: 1000}}
	if !ciSlowedHas(sent, c) {
		t.Fatal("a run away was sent again")
	}
	c.Job = "lint"
	if ciSlowedHas(sent, c) {
		t.Fatal("another job's change counted as sent")
	}
}
