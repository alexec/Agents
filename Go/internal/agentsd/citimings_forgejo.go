package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
	"github.com/agentloops-dev/agent-loops/Go/internal/forgejomcp"
)

// Build timings from Forgejo and Gitea Actions (#5224, spec 5166, "The data spike"), as from
// GitHub (citimings.go): the same store, bounds and pacing, with the person's Forgejo
// connection, for a folder on the connected Forgejo (citimings/forgejo.go says the fields).
//
//   - Live: the newest runs (actions/runs, newest first, ciForgejoPage a page), and for each
//     finished run the store does not have, its jobs (actions/runs/{id}/jobs): one call a run,
//     and one a job (actions/jobs/{id}) when the list gives no steps, as Forgejo 17's does not.
//     When a job's own answer has no steps either (Forgejo 16), the run's other jobs are not
//     asked.
//   - Backfill: the same list, page after page, until a page is older than citimings.KeepDays
//     or the list ends. Decided: Forgejo's list has no time filter, so the backfill keeps the
//     next page's number, as Bitbucket's does; a run made since moves the pages on, so a page
//     is seen again, never missed. Alex can overrule.
//   - Decided: a run the store has is not read again, so a job run again after the first read
//     is not seen, because Forgejo's list does not say the attempt (Gitea's does, and is
//     used), as on GitLab. Alex can overrule.
//   - Paced with GitHub's budget (ciBudgetLeft): Forgejo says no hourly limit.

const (
	// ciForgejoPage is Forgejo's most runs on one page (MAX_RESPONSE_ITEMS).
	ciForgejoPage = 50
	// ciForgejoJobReads bounds the job reads of one run.
	ciForgejoJobReads = 50
	// ciForgejoMostPages bounds the backfill's pages: 20,000 runs, the store's bound.
	ciForgejoMostPages = citimings.MostRuns / ciForgejoPage
)

// ciForgejoAt is the connected Forgejo's root, when folder's repository is on it, and the
// repository.
func (d *Daemon) ciForgejoAt(ctx context.Context, folder string) (root, repo string) {
	if d.ciForgejoAPI != "" {
		return d.ciForgejoAPI, d.folderRepo(folder).path
	}
	c, root := d.forgejoRoot()
	if root == "" {
		return "", ""
	}
	at, repo := d.forgejoRepoAt(ctx, folder, c.URL)
	if at != root || repo == "" {
		return "", ""
	}
	return root, repoPath(repo)
}

// ciForgejoList is one page of the newest runs.
func (d *Daemon) ciForgejoList(ctx context.Context, h ciRepoHere, page int) ([]citimings.ForgejoRun, error) {
	q := url.Values{"limit": {strconv.Itoa(ciForgejoPage)}, "page": {strconv.Itoa(page)}}
	raw, err := d.ciGet(ctx, h, fmt.Sprintf("repos/%s/actions/runs?%s", h.repo.path, q.Encode()))
	if err != nil {
		return nil, err
	}
	var list citimings.ForgejoRunList
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, fmt.Errorf("the run list: %v", err)
	}
	return list.Runs, nil
}

// ciForgejoLive reads the newest runs, until a page has nothing new.
func (d *Daemon) ciForgejoLive(ctx context.Context, h ciRepoHere, key, def string) error {
	for page := 1; page <= ciLivePages; page++ {
		runs, err := d.ciForgejoList(ctx, h, page)
		if err != nil {
			return err
		}
		added, err := d.ciKeepForgejoRuns(ctx, h, def, runs, nowFunc())
		if err != nil {
			return err
		}
		if added == 0 || len(runs) < ciForgejoPage {
			break
		}
	}
	at := nowFunc()
	d.ciMu.Lock()
	d.ciRepoLocked(key).ReadAt = &at
	d.saveCIFileLocked()
	d.ciMu.Unlock()
	return nil
}

// ciForgejoBackfill reads older pages while the hour's budget lasts.
func (d *Daemon) ciForgejoBackfill(ctx context.Context, h ciRepoHere, key, def string) error {
	for ctx.Err() == nil && d.ciBudgetLeft() {
		d.ciMu.Lock()
		st := d.ciRepoLocked(key)
		filled, page := st.Filled, st.BackfillPage+1
		d.ciMu.Unlock()
		if filled {
			return nil
		}
		now := nowFunc()
		runs, err := d.ciForgejoList(ctx, h, page)
		if err != nil {
			return err
		}
		if _, err := d.ciKeepForgejoRuns(ctx, h, def, runs, now); err != nil {
			return err
		}
		oldest := now
		for _, r := range runs {
			if t, ok := r.MadeAt(); ok && t.Before(oldest) {
				oldest = t
			}
		}
		ended := len(runs) < ciForgejoPage
		d.ciMu.Lock()
		st = d.ciRepoLocked(key)
		st.BackfillPage = page
		st.FilledFrom = &oldest
		st.Filled = ended || page >= ciForgejoMostPages || now.Sub(oldest) >= citimings.KeepDays*24*time.Hour
		if st.Filled {
			// The backfill reached as far back as the store keeps, or the list's start.
			from := now.Add(-citimings.KeepDays * 24 * time.Hour)
			if ended && oldest.After(from) {
				from = oldest
			}
			st.FilledFrom = &from
		}
		d.saveCIFileLocked()
		d.ciMu.Unlock()
	}
	return nil
}

// ciKeepForgejoRuns reads the jobs of each finished run the store does not have, within its
// bounds, and keeps them; it says how many it kept.
func (d *Daemon) ciKeepForgejoRuns(ctx context.Context, h ciRepoHere, def string, runs []citimings.ForgejoRun, now time.Time) (int, error) {
	repo := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}
	added := 0
	for _, r := range runs {
		if ctx.Err() != nil {
			return added, ctx.Err()
		}
		made, ok := r.MadeAt()
		if !ok || r.Result() == "" || r.Number() <= 0 {
			continue
		}
		pr := r.PR() != 0 || strings.HasPrefix(r.Event, "pull_request")
		onDefault := r.Branch() == def && !pr
		onTag := !pr && versionTagPattern.MatchString(r.Branch())
		keep := citimings.StepDays
		if onDefault || onTag {
			keep = citimings.KeepDays
		}
		ref := h.repo.ciRun(int64(r.Number())).Ref
		if now.Sub(made) > time.Duration(keep)*24*time.Hour {
			continue
		}
		if r.RunAttempt > 0 && d.ciTimings().Has(repo, ref, r.RunAttempt, made) || r.RunAttempt == 0 && d.ciTimings().HasRun(repo, ref, made) {
			continue
		}
		raw, err := d.ciGet(ctx, h, fmt.Sprintf("repos/%s/actions/runs/%d/jobs?limit=%d", h.repo.path, r.ID, ciForgejoPage))
		if err != nil {
			return added, err
		}
		jobs, err := citimings.ForgejoJobs(raw)
		if err != nil {
			log.Printf("build timings: %s: run %d: the jobs answer: %v", h.repo.path, r.Number(), err)
			continue
		}
		if jobs, err = d.ciForgejoSteps(ctx, h, jobs); err != nil {
			return added, err
		}
		got, err := citimings.FromForgejo(r, jobs, ref, onDefault, onTag)
		if err != nil {
			log.Printf("build timings: %s: %v", h.repo.path, err)
			continue
		}
		if err := d.ciTimings().Put(repo, got...); err != nil {
			return added, err
		}
		added++
	}
	if added > 0 {
		d.ciChanged(repo.String())
	}
	return added, nil
}

// ciForgejoSteps reads the steps of each job the list gave none for, until one job's own
// answer has none either: that Forgejo has no steps in its API.
func (d *Daemon) ciForgejoSteps(ctx context.Context, h ciRepoHere, jobs []citimings.ForgejoJob) ([]citimings.ForgejoJob, error) {
	reads := 0
	for i, j := range jobs {
		if j.Timed() || j.ID == 0 || j.Status == "skipped" {
			continue
		}
		if reads >= ciForgejoJobReads {
			break
		}
		reads++
		raw, err := d.ciGet(ctx, h, fmt.Sprintf("repos/%s/actions/jobs/%d", h.repo.path, j.ID))
		if err != nil {
			return nil, err
		}
		var full citimings.ForgejoJob
		if json.Unmarshal(raw, &full) != nil || !full.Timed() {
			break
		}
		jobs[i] = full
	}
	return jobs, nil
}

// ciGetForgejo is one GET of Forgejo's API with the person's connection.
func (d *Daemon) ciGetForgejo(ctx context.Context, path string) ([]byte, error) {
	root, token := d.ciForgejoAPI, "test"
	if root == "" {
		c, at := d.forgejoRoot()
		if at == "" || c.Access == "" {
			return nil, errors.New(forgejomcp.NotConnected)
		}
		root, token = at, c.Access
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(root, "/")+"/api/v1/"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	// Go drops it on a redirect to another host.
	req.Header.Set("Authorization", "token "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Forgejo answered %d", resp.StatusCode)
	}
	return body, nil
}
