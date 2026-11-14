package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agents/Go/internal/citimings"
)

// Build timings from Azure Pipelines (#5222), as citimings.go reads GitHub's: the same store,
// bounds, backfill pacing and clock, for each folder on Azure DevOps (dev.azure.com or the
// connected Azure DevOps Server) with a token here.
//
//   - Live: the newest finished builds by finish time (build/builds), and for each build the
//     store does not have as it finished, its timeline (build/builds/{id}/timeline), plus the
//     timeline of each earlier attempt of a job run again: one call a build, more only for a
//     re-run.
//   - Backfill: the build list by queue time in ciWindow windows, newest first, default-branch
//     and tag builds for citimings.KeepDays, others for citimings.StepDays.
//   - Azure DevOps has no hourly limit to read (its limits are a sliding cost, said only when
//     near): the backfill takes a tenth of GitHub's default, ciDefaultLimit/ciBackfillShare
//     calls an hour, counted apart from GitHub's. A call it refuses (429) ends the read; the
//     next goes on where it stopped.
//
// Decided: a job's runner is the build's agent pool, because a timeline record does not say
// its own pool, and an agent's name (Azure Pipelines 3) changes from run to run. Alex can
// overrule.

// ciAzureDevOps is what the build timings ask of Azure DevOps; azuredevopsmcp.RealAzureDevOps
// has it, and a test gives a fake.
type ciAzureDevOps interface {
	TimingBuilds(ctx context.Context, repo string, order azuredevopsmcp.TimingsOrder, from, to time.Time) ([]byte, error)
	TimingTimeline(ctx context.Context, repo string, build int64, timeline string) ([]byte, error)
	DefaultBranch(ctx context.Context, repo string) (string, error)
}

// ciAzureRead is one read of an Azure DevOps repository: its default branch, live, then the
// backfill within its budget. A folder with no token here is not read.
func (d *Daemon) ciAzureRead(ctx context.Context, h ciRepoHere, key string) error {
	root, named := d.azureDevOpsRepoAt(ctx, h.folder)
	if named == "" || d.azureDevOpsToken(root) == "" {
		return nil
	}
	ado, ok := d.forgeAzureDevOps(root).(ciAzureDevOps)
	if !ok {
		return errors.New("this Azure DevOps reads no builds")
	}
	a := ciAzure{d: d, ado: ado, h: h, repo: named, key: key}
	def, err := a.defaultBranch(ctx)
	if err != nil {
		return err
	}
	if err := a.live(ctx, def); err != nil {
		return err
	}
	return a.backfill(ctx, def)
}

// ciAzure is one read of one repository: repo as Azure DevOps names it, key as the store does.
type ciAzure struct {
	d         *Daemon
	ado       ciAzureDevOps
	h         ciRepoHere
	repo, key string
}

func (a ciAzure) store() citimings.Repo {
	return citimings.Repo{Forge: a.h.repo.forge, Path: a.h.repo.path}
}

// count notes one call this hour.
func (a ciAzure) count() {
	a.d.ciMu.Lock()
	f := a.d.ciFileLocked()
	a.d.ciHourLocked(f)
	f.AzureDevOpsCalls++
	a.d.ciMu.Unlock()
}

// budgetLeft says the backfill may make another call this hour.
func (a ciAzure) budgetLeft() bool {
	a.d.ciMu.Lock()
	defer a.d.ciMu.Unlock()
	f := a.d.ciFileLocked()
	a.d.ciHourLocked(f)
	return f.AzureDevOpsCalls < ciDefaultLimit/ciBackfillShare
}

func (a ciAzure) defaultBranch(ctx context.Context) (string, error) {
	a.d.ciMu.Lock()
	st := a.d.ciRepoLocked(a.key)
	def, at := st.Default, st.DefaultAt
	a.d.ciMu.Unlock()
	if def != "" && nowFunc().Sub(at) < ciDefaultEvery {
		return def, nil
	}
	a.count()
	def, err := a.ado.DefaultBranch(ctx, a.repo)
	if err != nil {
		return "", err
	}
	if def == "" {
		return "", errors.New("no default branch from Azure DevOps")
	}
	a.d.ciMu.Lock()
	st = a.d.ciRepoLocked(a.key)
	st.Default, st.DefaultAt = def, nowFunc()
	a.d.saveCIFileLocked()
	a.d.ciMu.Unlock()
	return def, nil
}

func (a ciAzure) list(ctx context.Context, order azuredevopsmcp.TimingsOrder, from, to time.Time) ([]citimings.AzureBuild, error) {
	a.count()
	raw, err := a.ado.TimingBuilds(ctx, a.repo, order, from, to)
	if err != nil {
		return nil, err
	}
	var list citimings.AzureBuildList
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, fmt.Errorf("the build list: %v", err)
	}
	return list.Value, nil
}

// ciAzurePage is a full page of the build list: there may be more.
const ciAzurePage = 100

// live reads the newest finished builds, until a page has nothing new.
func (a ciAzure) live(ctx context.Context, def string) error {
	var to time.Time
	for page := 1; page <= ciLivePages; page++ {
		builds, err := a.list(ctx, azuredevopsmcp.ByFinish, time.Time{}, to)
		if err != nil {
			return err
		}
		added, err := a.keep(ctx, def, builds, nowFunc())
		if err != nil {
			return err
		}
		if added == 0 || len(builds) < ciAzurePage {
			break
		}
		next, ok := builds[len(builds)-1].FinishedAt()
		if !ok || !to.IsZero() && !next.Before(to) {
			break
		}
		to = next
	}
	at := nowFunc()
	a.d.ciMu.Lock()
	a.d.ciRepoLocked(a.key).ReadAt = &at
	a.d.saveCIFileLocked()
	a.d.ciMu.Unlock()
	return nil
}

// backfill reads older windows by queue time while the hour's budget lasts.
func (a ciAzure) backfill(ctx context.Context, def string) error {
	for ctx.Err() == nil && a.budgetLeft() {
		a.d.ciMu.Lock()
		st := a.d.ciRepoLocked(a.key)
		filled, to := st.Filled, st.BackfillTo
		a.d.ciMu.Unlock()
		now := nowFunc()
		if filled {
			return nil
		}
		if to.IsZero() {
			to = now
		}
		from, upTo := to.Add(-ciWindow), to
		done := true
		for page := 1; page <= ciWindowPages; page++ {
			if !a.budgetLeft() {
				done = false
				break
			}
			builds, err := a.list(ctx, azuredevopsmcp.ByQueue, from, upTo)
			if err != nil {
				return err
			}
			if _, err := a.keep(ctx, def, builds, now); err != nil {
				return err
			}
			if len(builds) < ciAzurePage {
				break
			}
			// The next page is older than this one's oldest; one queued at that time again is
			// in the store already.
			next, ok := builds[len(builds)-1].MadeAt()
			if !ok || !next.Before(upTo) {
				break
			}
			upTo = next
		}
		if !done {
			return nil
		}
		a.d.ciMu.Lock()
		st = a.d.ciRepoLocked(a.key)
		st.BackfillTo = from
		f := from
		st.FilledFrom = &f
		st.Filled = now.Sub(from) >= citimings.KeepDays*24*time.Hour
		a.d.saveCIFileLocked()
		a.d.ciMu.Unlock()
	}
	return nil
}

// keep reads the timeline of each build the store does not have as it finished, within its
// bounds, and keeps its attempts; it says how many builds it kept.
func (a ciAzure) keep(ctx context.Context, def string, builds []citimings.AzureBuild, now time.Time) (int, error) {
	repo := a.store()
	added := 0
	for _, b := range builds {
		if ctx.Err() != nil {
			return added, ctx.Err()
		}
		made, ok := b.MadeAt()
		finished, done := b.FinishedAt()
		if !ok || !done || b.Status != "" && b.Status != "completed" {
			continue
		}
		branch := b.Branch()
		onDefault := branch == def && b.PullRequest() == 0 && b.Reason != "pullRequest"
		onTag := b.OnTag() || versionTagPattern.MatchString(branch)
		bound := citimings.StepDays
		if onDefault || onTag {
			bound = citimings.KeepDays
		}
		ref := a.h.repo.ciRun(b.ID).Ref
		if now.Sub(made) > time.Duration(bound)*24*time.Hour || a.has(repo, ref, made, finished) {
			continue
		}
		a.count()
		raw, err := a.ado.TimingTimeline(ctx, a.repo, b.ID, "")
		if err != nil {
			return added, err
		}
		earlier := map[string][]byte{}
		for _, id := range citimings.AzureEarlierTimelines(raw) {
			a.count()
			old, err := a.ado.TimingTimeline(ctx, a.repo, b.ID, id)
			if err != nil {
				// An earlier attempt gone is not this one lost.
				log.Printf("build timings: %s: build %d, attempt timeline %s: %v", a.h.repo.path, b.ID, id, err)
				continue
			}
			earlier[id] = old
		}
		got, err := citimings.FromAzureDevOps(b, raw, earlier, ref, onDefault, onTag)
		if err != nil {
			log.Printf("build timings: %s: %v", a.h.repo.path, err)
			continue
		}
		if err := a.d.ciTimings().Put(repo, got...); err != nil {
			return added, err
		}
		added++
	}
	if added > 0 {
		a.d.ciChanged(repo.String())
	}
	return added, nil
}

// has says the store has the build as it finished: a job run again finishes it later, and the
// build's id is the same, so its attempt is read again.
func (a ciAzure) has(repo citimings.Repo, ref string, made, finished time.Time) bool {
	at := time.Unix(made.Unix(), 0)
	runs, err := a.d.ciTimings().Runs(repo, at, at.Add(time.Second))
	if err != nil {
		return false
	}
	ended := finished.Sub(made).Seconds()
	for _, r := range runs {
		if r.Ref == ref && r.Ended >= ended-1 {
			return true
		}
	}
	return false
}
