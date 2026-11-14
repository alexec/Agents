package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The control plane's copy of the build timings (#5232, spec 5166, "Where"): this machine
// stays the system of record (citimings.go) and sends the control plane each day of runs that
// changed (builds/sync) a short time after the change, as lineage/sync sends links (#4275), so
// the Builds page works while it sleeps (principle 1). Each day goes whole, as the store has
// it now, so a sweep's change goes the same way as a new run, and a day with no runs is gone.
// The repository's default branch, last read and backfill reach go with each send. Only refs,
// times, attempts, conclusions, runner labels and names (principle 7).
//
// What is unsent is in <root>/ci-timings/sync.json: for each repository the days to send
// (at most ciMostRepos repositories of 90 days).
// The first send, and the one after the control plane says it has no copy of a repository,
// is every day the store keeps of it, the first with reset.

const (
	ciSyncAfter = 2 * time.Second
	// ciSyncRuns bounds the runs of one send (about 3 MB with their steps); a day with more
	// goes alone.
	ciSyncRuns = 1_000
	// ciSyncDays bounds the days of one send, as the control plane does.
	ciSyncDays = 31
)

type ciSyncFile struct {
	// Kept is true in every file written; a file without it is a whole send of every
	// repository to make.
	Kept  bool                   `json:"kept"`
	Repos map[string]*ciSyncRepo `json:"repos,omitempty"`
}

// ciSyncRepo is what is unsent of one repository.
type ciSyncRepo struct {
	// Full is a whole send to make: every day, the first send with reset.
	Full bool `json:"full,omitempty"`
	// Reset is that the next send starts the control plane's copy again.
	Reset bool `json:"reset,omitempty"`
	// Meta is the generation at which the default branch, last read or backfill reach moved.
	Meta int `json:"meta,omitempty"`
	// Days is each day to send, with the generation at which it last changed.
	Days map[string]int `json:"days,omitempty"`
}

type ciSyncBook struct {
	ciSyncMu    sync.Mutex
	ciSyncFile  *ciSyncFile
	ciSyncTimer *time.Timer
	// ciSyncGen moves with each change noted, so a send takes off only what did not change
	// again on its way.
	ciSyncGen int
	// ciSyncSending keeps one send at a time.
	ciSyncSending sync.Mutex
}

func (d *Daemon) ciSyncPath() string { return filepath.Join(d.ciTimingsDir(), "sync.json") }

// ciSyncLocked is the file, read on first use. None, or one that cannot be read, is a whole
// send of every repository the store has.
func (d *Daemon) ciSyncLocked() *ciSyncFile {
	if d.ciSyncFile == nil {
		f := &ciSyncFile{}
		readStore(d.ciSyncPath(), f, "the build timings all go to the control plane again")
		if !f.Kept {
			f = &ciSyncFile{Kept: true, Repos: map[string]*ciSyncRepo{}}
			for _, r := range d.ciTimings().Repos() {
				f.Repos[r.String()] = &ciSyncRepo{Full: true}
			}
		}
		if f.Repos == nil {
			f.Repos = map[string]*ciSyncRepo{}
		}
		d.ciSyncFile = f
	}
	return d.ciSyncFile
}

// ciSyncRepoLocked is what is unsent of key. A repository new to the file has never been
// sent: its first send is all of it, with reset.
func (d *Daemon) ciSyncRepoLocked(key string) *ciSyncRepo {
	f := d.ciSyncLocked()
	if f.Repos[key] == nil {
		f.Repos[key] = &ciSyncRepo{Full: true}
	}
	return f.Repos[key]
}

// noteCIDays keeps repo's days for the next send.
func (d *Daemon) noteCIDays(repo citimings.Repo, days ...string) {
	if len(days) == 0 {
		return
	}
	d.ciSyncMu.Lock()
	r := d.ciSyncRepoLocked(repo.String())
	if !r.Full {
		if r.Days == nil {
			r.Days = map[string]int{}
		}
		for _, day := range days {
			d.ciSyncGen++
			r.Days[day] = d.ciSyncGen
		}
	}
	d.ciSyncMu.Unlock()
	d.ciSyncSoon()
}

// noteCIMeta notes that key's default branch, last read or backfill reach moved.
func (d *Daemon) noteCIMeta(key string) {
	d.ciSyncMu.Lock()
	d.ciSyncGen++
	d.ciSyncRepoLocked(key).Meta = d.ciSyncGen
	d.ciSyncMu.Unlock()
	d.ciSyncSoon()
}

// ciSyncSoon sends within ciSyncAfter, with what else changes by then.
func (d *Daemon) ciSyncSoon() {
	if d.askControl.Load() == nil {
		return
	}
	d.ciSyncMu.Lock()
	defer d.ciSyncMu.Unlock()
	if d.ciSyncTimer == nil {
		d.ciSyncTimer = time.AfterFunc(ciSyncAfter, func() {
			d.ciSyncMu.Lock()
			d.ciSyncTimer = nil
			d.ciSyncMu.Unlock()
			d.sendCITimings()
		})
	}
}

// ciSent is what one send took: its repository, and the generation of each part.
type ciSent struct {
	key   string
	reset bool
	meta  int
	days  map[string]int
}

// sendCITimings sends what is unsent, if this host has a control plane that takes it, until
// none is left or a send fails; a failed send is tried again on the next change, the next
// hour or the next connection.
func (d *Daemon) sendCITimings() {
	ask := d.askControl.Load()
	if ask == nil || !d.controlHas(wire.CapBuildsCopy1) {
		return
	}
	d.ciSyncSending.Lock()
	defer d.ciSyncSending.Unlock()
	defer d.saveCISync()
	for d.ctx.Err() == nil {
		send, took, ok, err := d.unsentCITimings()
		if err != nil {
			log.Printf("builds/sync: %s: not sent: %v", took.key, err)
			return
		}
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
		raw, err := (*ask)(ctx, wire.CallBuildsSync.Name, send)
		cancel()
		var answer wire.BuildsSyncAnswer
		if err == nil && len(raw) > 0 {
			err = json.Unmarshal(raw, &answer)
		}
		if err != nil {
			log.Printf("builds/sync: not sent, tried again later: %v", err)
			return
		}
		d.ciTimingsSent(took, answer.Full != nil && *answer.Full)
	}
}

// unsentCITimings is the next send: the first repository with something unsent, its oldest
// days first, at most a send's bound.
func (d *Daemon) unsentCITimings() (wire.BuildsSync, ciSent, bool, error) {
	d.ciSyncMu.Lock()
	f := d.ciSyncLocked()
	keys := make([]string, 0, len(f.Repos))
	for k, r := range f.Repos {
		// Not a repository the store can have. One with nothing to send stays, so it is not
		// new to the file the next time.
		if _, err := citimings.ParseRepo(k); err != nil {
			delete(f.Repos, k)
			continue
		}
		if r.Full || r.Reset || r.Meta > 0 || len(r.Days) > 0 {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		d.ciSyncMu.Unlock()
		return wire.BuildsSync{}, ciSent{}, false, nil
	}
	sort.Strings(keys)
	key := keys[0]
	repo, _ := citimings.ParseRepo(key)
	r := f.Repos[key]
	if r.Full {
		d.ciSyncMu.Unlock()
		// Read outside ciSyncMu, which the store's writers take to note a change.
		all, err := d.ciTimings().DayList(repo)
		if err != nil {
			return wire.BuildsSync{}, ciSent{key: key}, false, err
		}
		d.ciSyncMu.Lock()
		r = d.ciSyncRepoLocked(key)
		if r.Full {
			r.Full, r.Reset = false, true
			if r.Days == nil {
				r.Days = map[string]int{}
			}
			d.ciSyncGen++
			r.Meta = d.ciSyncGen
			for _, day := range all {
				if _, ok := r.Days[day]; !ok {
					r.Days[day] = d.ciSyncGen
				}
			}
		}
	}
	took := ciSent{key: key, reset: r.Reset, meta: r.Meta, days: map[string]int{}}
	days := make([]string, 0, len(r.Days))
	for day := range r.Days {
		days = append(days, day)
	}
	sort.Strings(days)
	gens := make(map[string]int, len(r.Days))
	for day, gen := range r.Days {
		gens[day] = gen
	}
	d.ciSyncMu.Unlock()

	send := wire.BuildsSync{Repo: key, Days: []wire.BuildsSyncDay{}}
	if took.reset {
		send.Reset = new(true)
	}
	d.ciMu.Lock()
	if st := d.ciFileLocked().Repos[key]; st != nil {
		send.DefaultBranch, send.ReadAt, send.FilledFrom = st.wireMeta()
	}
	d.ciMu.Unlock()
	runs := 0
	for _, day := range days {
		if len(send.Days) >= ciSyncDays {
			break
		}
		kept, err := d.ciTimings().Day(repo, day)
		if err != nil {
			return wire.BuildsSync{}, took, false, err
		}
		if len(send.Days) > 0 && runs+len(kept) > ciSyncRuns {
			break
		}
		runs += len(kept)
		w := wire.BuildsSyncDay{Day: day, Runs: make([]wire.BuildsRun, 0, len(kept))}
		for _, run := range kept {
			w.Runs = append(w.Runs, citimings.RunToWire(run))
		}
		send.Days = append(send.Days, w)
		took.days[day] = gens[day]
	}
	return send, took, true, nil
}

// ciTimingsSent drops what went, but a day that changed on its way. When the control plane
// had no copy of the repository, the next send of it is every day again.
func (d *Daemon) ciTimingsSent(took ciSent, full bool) {
	d.ciSyncMu.Lock()
	defer d.ciSyncMu.Unlock()
	r := d.ciSyncRepoLocked(took.key)
	if full {
		*r = ciSyncRepo{Full: true}
		return
	}
	if took.reset {
		r.Reset = false
	}
	if r.Meta == took.meta {
		r.Meta = 0
	}
	for day, gen := range took.days {
		if r.Days[day] == gen {
			delete(r.Days, day)
		}
	}
}

// saveCISync writes the file.
func (d *Daemon) saveCISync() {
	d.ciSyncMu.Lock()
	defer d.ciSyncMu.Unlock()
	if d.ciSyncFile == nil {
		return
	}
	if err := writeStore(d.ciSyncPath(), d.ciSyncFile); err != nil {
		log.Printf("ci-timings/sync.json: could not save: %v", err)
	}
}

// closeCISync saves what is unsent at shutdown.
func (d *Daemon) closeCISync() {
	d.ciSyncMu.Lock()
	if d.ciSyncTimer != nil {
		d.ciSyncTimer.Stop()
		d.ciSyncTimer = nil
	}
	d.ciSyncMu.Unlock()
	d.saveCISync()
}
