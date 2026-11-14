package agentsd

import (
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/citimings"
	"github.com/agentloops-dev/agents/Go/wire"
)

// ci.slowed (#5200, specs/5166-build-deploy-trends/spec.md, "A slowdown makes an event"): when
// the change finder (citimings.Changes) finds a step up in a job's run time on the default
// branch, this machine raises ci.slowed in each folder that pushes to the repository, once for
// each change. A speed-up raises nothing, and so does a change in queue time: the finder never
// looks at it, because it is load, not a commit.
//
//   - Once: each change sent is kept in state.json (ciRepoState.Slowed) by its id, so the
//     finder running again sends nothing. A change of the same job whose first slow run is
//     within ciSlowedNear of one sent is the same change, found again a run or two away as
//     more runs came in, and is not sent again either.
//   - New changes only: a change whose first slow run is older than ciSlowedRecent is not
//     sent, so the first backfill of 90 days does not send every old change at once.
//   - Two machines that watch one repository find the same change. The event's envelope id is
//     the same on both (<first slow run's ref>@ci.slowed/<workflow>/<job>), so the bus keeps
//     the first copy and drops the other: a workflow on a third machine starts once. Each
//     machine still records its own copy, as for any event it raises.
//
// Decided: the name ci.slowed, and details in the catalogue's own style (snake_case, every
// value text): repo (owner/name, as checks.passed's repo filter), workflow, job, branch,
// first_slow_run and last_fast_run (ci-run refs) with their _url, median_before and
// median_after (seconds), and score; repo, workflow and job narrow a wait or a trigger. It is
// an app event (source app, in Packages/Wire/event-catalogue.json), not a forge server's,
// because this machine's daemon finds it from its own timing store. Alex can overrule.

const (
	ciSlowedRecent = 7 * 24 * time.Hour
	ciSlowedNear   = 24 * time.Hour
	ciSlowedName   = "ci.slowed"
)

// ciSlowedSent is a change that ci.slowed was sent for.
type ciSlowedSent struct {
	Workflow string `json:"workflow"`
	Job      string `json:"job"`
	// Made is when the first slow run was made, in Unix seconds.
	Made int64     `json:"made"`
	At   time.Time `json:"at"`
}

// ciSlowedID is the change's id: the same on every machine that finds it.
func ciSlowedID(c citimings.Change) string {
	return c.FirstSlow.Ref + "@" + ciSlowedName + "/" + c.Workflow + "/" + c.Job
}

// ciSendSlowed raises ci.slowed for each new step up in repo's change points.
func (d *Daemon) ciSendSlowed(repo citimings.Repo) {
	changes, err := d.ciChangesOf(repo)
	if err != nil {
		log.Printf("build timings: %s: changes: %v", repo.Path, err)
		return
	}
	now := nowFunc()
	key := repo.String()
	var send []citimings.Change
	d.ciMu.Lock()
	st := d.ciRepoLocked(key)
	branch := st.Default
	for id, s := range st.Slowed {
		if now.Sub(time.Unix(s.Made, 0)) > citimings.KeepDays*24*time.Hour {
			delete(st.Slowed, id)
		}
	}
	for _, c := range changes {
		if !c.Slower() || now.Sub(c.FirstSlow.MadeAt()) > ciSlowedRecent || ciSlowedHas(st.Slowed, c) {
			continue
		}
		if st.Slowed == nil {
			st.Slowed = map[string]ciSlowedSent{}
		}
		st.Slowed[ciSlowedID(c)] = ciSlowedSent{Workflow: c.Workflow, Job: c.Job, Made: c.FirstSlow.Made, At: now}
		send = append(send, c)
	}
	if len(send) > 0 {
		d.saveCIFileLocked()
	}
	d.ciMu.Unlock()
	if len(send) == 0 {
		return
	}
	folders := d.ciFoldersOf(repo)
	for _, c := range send {
		for _, f := range folders {
			d.raise(ciSlowedDraft(repo, branch, c, f))
		}
	}
}

// ciSlowedHas says c, or the same change found a run or two away, was sent.
func ciSlowedHas(sent map[string]ciSlowedSent, c citimings.Change) bool {
	if _, ok := sent[ciSlowedID(c)]; ok {
		return true
	}
	for _, s := range sent {
		if s.Workflow == c.Workflow && s.Job == c.Job && time.Duration(abs64(s.Made-c.FirstSlow.Made))*time.Second < ciSlowedNear {
			return true
		}
	}
	return false
}

func abs64(n int64) int64 {
	if n < 0 {
		return -n
	}
	return n
}

// ciFoldersOf is the folders on this machine that push to repo.
func (d *Daemon) ciFoldersOf(repo citimings.Repo) []string {
	var out []string
	for _, f := range d.folderPaths() {
		if r := d.folderRepo(f); r.forge == repo.Forge && r.path == repo.Path {
			out = append(out, f)
		}
	}
	return out
}

func ciSlowedDraft(repo citimings.Repo, branch string, c citimings.Change, folder string) wire.EventDraft {
	if branch == "" {
		branch = c.FirstSlow.Branch
	}
	num := func(v float64) string { return strconv.FormatFloat(v, 'f', 1, 64) }
	sentence := fmt.Sprintf("%s in %s got slower on %s: %s to %s, from %s.", c.Job, c.Workflow, branch,
		ciSeconds(c.MedianBefore), ciSeconds(c.MedianAfter), c.FirstSlow.Ref)
	return wire.EventDraft{Name: ciSlowedName, At: wire.DateOf(nowFunc()), Scope: folderScope(folder), Sentence: sentence,
		Details: map[string]string{
			"repo": repo.Path, "workflow": c.Workflow, "job": c.Job, "branch": branch,
			"first_slow_run": c.FirstSlow.Ref, "first_slow_run_url": c.FirstSlow.URL,
			"last_fast_run": c.LastFast.Ref, "last_fast_run_url": c.LastFast.URL,
			"median_before": num(c.MedianBefore), "median_after": num(c.MedianAfter), "score": num(c.Score),
		}}
}

// ciSeconds is a run time in words: seconds under two minutes, else minutes.
func ciSeconds(s float64) string {
	if s < 120 {
		return strconv.FormatFloat(s, 'f', 0, 64) + " s"
	}
	return strconv.FormatFloat(s/60, 'f', 1, 64) + " min"
}

// ciSlowedSentAt is when ci.slowed was sent for c, if it was.
func (d *Daemon) ciSlowedSentAt(repo citimings.Repo, c citimings.Change) *wire.Date {
	d.ciMu.Lock()
	defer d.ciMu.Unlock()
	st := d.ciFileLocked().Repos[repo.String()]
	if st == nil {
		return nil
	}
	if s, ok := st.Slowed[ciSlowedID(c)]; ok {
		return new(wire.DateOf(s.At))
	}
	return nil
}

// ciSlowedEnvelope is ci.slowed's subject and key: the first slow run, and the workflow and
// job, so its id is the same on every machine that finds the change.
func ciSlowedEnvelope(e wire.Event) (wire.Ref, string, bool) {
	ref, err := wire.ParseRef(e.Details["first_slow_run"])
	if err != nil || e.Details["workflow"] == "" || e.Details["job"] == "" {
		return wire.Ref{}, "", false
	}
	return ref, e.Details["workflow"] + "/" + e.Details["job"], true
}
