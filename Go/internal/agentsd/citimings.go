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
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Build timings (#5177, specs/5166-build-deploy-trends/spec.md, "The data spike"): this
// machine reads each GitHub repository's CI runs, with their jobs and steps, into the timing
// store (citimings), and answers builds/history and builds/run from it.
//
//   - Live: every ciLiveEvery, and soon after a run.completed or checks.* event, the newest
//     finished runs (actions/runs?status=completed), and for each attempt the store does not
//     have, its jobs and steps (actions/runs/{id}/jobs?filter=all): one call a run.
//   - Backfill, when a repository is first read: the run list in ciWindow windows, newest
//     first; default-branch and tag runs for citimings.KeepDays, others for
//     citimings.StepDays. Paced at a tenth of the token's hourly limit (ciBackfillShare), so the
//     forge's events never wait; it goes on where it stopped, also after a restart.
//   - The store's bounds are applied once an hour (citimings.Store.Sweep).
//   - What is read: refs, times, attempts, conclusions, runner labels, and the names of
//     workflows, jobs and steps. No titles, no logs (principle 7).
//
// Decided: the daemon reads GitHub's REST API with the token it has for the owner (the
// agents' bot, then the person's GitHub connection), or the person's own gh in the folder
// when it has neither, as lineage's parent lookup does, and on its own clock, not on a
// run.completed subscription, because an event reaches the daemon only when a workflow or a
// wait subscribes to it. An event still makes the next read sooner. Alex can overrule.
//
// The control plane's copy (the spike's "Copy on the control plane") is its own task: the web
// page asks the host that has the folder, as lineage/figures does, while the Mac is awake.

const (
	ciFirstRead  = time.Minute
	ciLiveEvery  = 5 * time.Minute
	ciSoon       = 20 * time.Second
	ciSweepEvery = time.Hour
	// ciWindow is one backfill list: GitHub lists at most 1,000 runs for one query.
	ciWindow = 3 * 24 * time.Hour
	// ciLivePages bounds the pages of the newest runs one live read lists.
	ciLivePages = 5
	// ciWindowPages bounds the pages of one backfill window: 1,000 runs.
	ciWindowPages = 10
	// ciBackfillShare is the share of the token's hourly limit the backfill may use.
	ciBackfillShare = 10
	// ciDefaultLimit is GitHub's hourly limit for a token, when no answer said it.
	ciDefaultLimit = 5000
	// ciMostRepos bounds the repositories read.
	ciMostRepos = 20
	// ciDefaultEvery is how often a repository's default branch is asked again.
	ciDefaultEvery = 24 * time.Hour
	githubAPI      = "https://api.github.com"
)

type ciTimingsBook struct {
	ciOnce  sync.Once
	ciStore *citimings.Store
	ciMu    sync.Mutex
	ciFile  *ciTimingsFile
	ciKick  chan struct{}
	// ciGen moves each time a repository's runs change; ciChanges is its change points as
	// found at a generation.
	ciGen     map[string]int
	ciChanges map[string]ciChangesFound
	// ciAPI is GitHub's API; "" is api.github.com. A test sets it.
	ciAPI string
}

type ciChangesFound struct {
	gen     int
	changes []citimings.Change
}

// ciTimingsFile is <root>/ci-timings/state.json: where each repository's reading has got to,
// and the calls made this hour.
type ciTimingsFile struct {
	Repos map[string]*ciRepoState `json:"repos"`
	// Hour is the start of the hour Calls counts; Limit the token's hourly limit as last said.
	Hour  time.Time `json:"hour"`
	Calls int       `json:"calls"`
	Limit int       `json:"limit,omitempty"`
}

type ciRepoState struct {
	Default   string    `json:"default,omitempty"`
	DefaultAt time.Time `json:"defaultAt"`
	// ReadAt is the last live read that worked.
	ReadAt *time.Time `json:"readAt,omitempty"`
	// BackfillTo is the end of the next backfill window; zero is now. FilledFrom is the oldest
	// time the backfill reached; Filled says it is done.
	BackfillTo time.Time  `json:"backfillTo"`
	FilledFrom *time.Time `json:"filledFrom,omitempty"`
	Filled     bool       `json:"filled,omitempty"`
	SweptAt    time.Time  `json:"sweptAt"`
}

func (d *Daemon) ciTimingsDir() string { return filepath.Join(d.Store.Loc.Root, "ci-timings") }

func (d *Daemon) ciTimings() *citimings.Store {
	d.ciOnce.Do(func() {
		d.ciStore = &citimings.Store{Root: d.ciTimingsDir()}
		d.ciKick = make(chan struct{}, 1)
	})
	return d.ciStore
}

// ciFileLocked is the state, read on first use.
func (d *Daemon) ciFileLocked() *ciTimingsFile {
	if d.ciFile == nil {
		f := &ciTimingsFile{}
		readStore(filepath.Join(d.ciTimingsDir(), "state.json"), f, "the build timings are read again from the newest")
		if f.Repos == nil {
			f.Repos = map[string]*ciRepoState{}
		}
		d.ciFile = f
	}
	return d.ciFile
}

func (d *Daemon) saveCIFileLocked() {
	if err := writeStore(filepath.Join(d.ciTimingsDir(), "state.json"), d.ciFileLocked()); err != nil {
		log.Printf("build timings: state not saved: %v", err)
	}
}

func (d *Daemon) ciRepoLocked(repo string) *ciRepoState {
	f := d.ciFileLocked()
	if f.Repos[repo] == nil {
		f.Repos[repo] = &ciRepoState{}
	}
	return f.Repos[repo]
}

// StartCITimings reads the build timings on their clock.
func (d *Daemon) StartCITimings() {
	d.ciTimings()
	d.goLoop("build timings", d.ciTimingsClock)
}

// kickCITimings reads the timings soon: a run finished.
func (d *Daemon) kickCITimings() {
	d.ciTimings()
	select {
	case d.ciKick <- struct{}{}:
	default:
	}
}

func (d *Daemon) ciTimingsClock(ctx context.Context) {
	wait := ciFirstRead
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		case <-d.ciKick:
			// A burst of events is one read.
			select {
			case <-ctx.Done():
				return
			case <-time.After(ciSoon):
			}
		}
		d.readCITimings(ctx)
		wait = ciLiveEvery
	}
}

// ciRepoHere is a GitHub repository a folder pushes to, and that folder, for gh.
type ciRepoHere struct {
	repo   forgeRepo
	folder string
}

// ciReposHere is the GitHub repositories the folders push to, at most ciMostRepos.
func (d *Daemon) ciReposHere() []ciRepoHere {
	seen := map[string]bool{}
	var out []ciRepoHere
	for _, f := range d.folderPaths() {
		r := d.folderRepo(f)
		if r.forge != "github" || seen[r.path] || len(out) >= ciMostRepos {
			continue
		}
		seen[r.path] = true
		out = append(out, ciRepoHere{r, f})
	}
	return out
}

// readCITimings is one read of every repository: live, then the backfill within its budget,
// then the bounds once an hour.
func (d *Daemon) readCITimings(ctx context.Context) {
	for _, h := range d.ciReposHere() {
		if ctx.Err() != nil {
			return
		}
		if err := d.readCIRepo(ctx, h); err != nil {
			log.Printf("build timings: %s: %v", h.repo.path, err)
		}
	}
}

func (d *Daemon) readCIRepo(ctx context.Context, h ciRepoHere) error {
	key := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}.String()
	def, err := d.ciDefaultBranch(ctx, h, key)
	if err != nil {
		return err
	}
	if err := d.ciLive(ctx, h, key, def); err != nil {
		return err
	}
	if err := d.ciBackfill(ctx, h, key, def); err != nil {
		return err
	}
	d.ciMu.Lock()
	st := d.ciRepoLocked(key)
	sweep := nowFunc().Sub(st.SweptAt) >= ciSweepEvery
	if sweep {
		st.SweptAt = nowFunc()
		d.saveCIFileLocked()
	}
	d.ciMu.Unlock()
	if sweep {
		repo := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}
		if err := d.ciTimings().Sweep(repo, nowFunc()); err != nil {
			return fmt.Errorf("sweep: %w", err)
		}
		d.ciChanged(key)
	}
	return nil
}

// ciDefaultBranch is the repository's default branch, asked once a day.
func (d *Daemon) ciDefaultBranch(ctx context.Context, h ciRepoHere, key string) (string, error) {
	d.ciMu.Lock()
	st := d.ciRepoLocked(key)
	def, at := st.Default, st.DefaultAt
	d.ciMu.Unlock()
	if def != "" && nowFunc().Sub(at) < ciDefaultEvery {
		return def, nil
	}
	raw, err := d.ciGet(ctx, h, "repos/"+h.repo.path)
	if err != nil {
		return "", err
	}
	var repo struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := json.Unmarshal(raw, &repo); err != nil || repo.DefaultBranch == "" {
		return "", errors.New("GitHub did not say the default branch")
	}
	d.ciMu.Lock()
	st = d.ciRepoLocked(key)
	st.Default, st.DefaultAt = repo.DefaultBranch, nowFunc()
	d.saveCIFileLocked()
	d.ciMu.Unlock()
	return repo.DefaultBranch, nil
}

// ciLive reads the newest finished runs, until a page has nothing new.
func (d *Daemon) ciLive(ctx context.Context, h ciRepoHere, key, def string) error {
	for page := 1; page <= ciLivePages; page++ {
		list, err := d.ciList(ctx, h, url.Values{"status": {"completed"}, "per_page": {"100"}, "page": {strconv.Itoa(page)}})
		if err != nil {
			return err
		}
		added, err := d.ciKeepRuns(ctx, h, def, list.WorkflowRuns, nowFunc())
		if err != nil {
			return err
		}
		if added == 0 || len(list.WorkflowRuns) < 100 {
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

// ciBackfill reads older windows while the hour's budget lasts.
func (d *Daemon) ciBackfill(ctx context.Context, h ciRepoHere, key, def string) error {
	for ctx.Err() == nil && d.ciBudgetLeft() {
		d.ciMu.Lock()
		st := d.ciRepoLocked(key)
		filled, to := st.Filled, st.BackfillTo
		d.ciMu.Unlock()
		now := nowFunc()
		if filled {
			return nil
		}
		if to.IsZero() {
			to = now
		}
		from := to.Add(-ciWindow)
		done := true
		for page := 1; page <= ciWindowPages; page++ {
			if !d.ciBudgetLeft() {
				done = false
				break
			}
			list, err := d.ciList(ctx, h, url.Values{"status": {"completed"}, "per_page": {"100"}, "page": {strconv.Itoa(page)},
				"created": {from.UTC().Format(time.RFC3339) + ".." + to.UTC().Format(time.RFC3339)}})
			if err != nil {
				return err
			}
			if _, err := d.ciKeepRuns(ctx, h, def, list.WorkflowRuns, now); err != nil {
				return err
			}
			if len(list.WorkflowRuns) < 100 {
				break
			}
		}
		if !done {
			return nil
		}
		d.ciMu.Lock()
		st = d.ciRepoLocked(key)
		st.BackfillTo = from
		f := from
		st.FilledFrom = &f
		st.Filled = now.Sub(from) >= citimings.KeepDays*24*time.Hour
		d.saveCIFileLocked()
		d.ciMu.Unlock()
	}
	return nil
}

// ciKeepRuns reads the jobs of each run the store does not have, within its bounds, and keeps
// them; it says how many it kept.
func (d *Daemon) ciKeepRuns(ctx context.Context, h ciRepoHere, def string, runs []citimings.GitHubRun, now time.Time) (int, error) {
	repo := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}
	added := 0
	for _, r := range runs {
		if ctx.Err() != nil {
			return added, ctx.Err()
		}
		made, err := time.Parse(time.RFC3339, r.CreatedAt)
		if err != nil || r.Status != "" && r.Status != "completed" {
			continue
		}
		onDefault := r.HeadBranch == def && r.Event != "pull_request"
		onTag := versionTagPattern.MatchString(r.HeadBranch)
		keep := citimings.StepDays
		if onDefault || onTag {
			keep = citimings.KeepDays
		}
		ref := h.repo.ciRun(r.ID).Ref
		if now.Sub(made) > time.Duration(keep)*24*time.Hour || d.ciTimings().Has(repo, ref, max(r.RunAttempt, 1), made) {
			continue
		}
		raw, err := d.ciGet(ctx, h, fmt.Sprintf("repos/%s/actions/runs/%d/jobs?filter=all&per_page=100", h.repo.path, r.ID))
		if err != nil {
			return added, err
		}
		got, err := citimings.FromGitHub(r, raw, ref, onDefault, onTag)
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

func (d *Daemon) ciList(ctx context.Context, h ciRepoHere, q url.Values) (citimings.GitHubRunList, error) {
	var list citimings.GitHubRunList
	raw, err := d.ciGet(ctx, h, fmt.Sprintf("repos/%s/actions/runs?%s", h.repo.path, q.Encode()))
	if err != nil {
		return list, err
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return list, fmt.Errorf("the run list: %v", err)
	}
	return list, nil
}

// ciBudgetLeft says the backfill may make another call this hour.
func (d *Daemon) ciBudgetLeft() bool {
	d.ciMu.Lock()
	defer d.ciMu.Unlock()
	f := d.ciFileLocked()
	d.ciHourLocked(f)
	limit := f.Limit
	if limit <= 0 {
		limit = ciDefaultLimit
	}
	return f.Calls < limit/ciBackfillShare
}

func (d *Daemon) ciHourLocked(f *ciTimingsFile) {
	if hour := nowFunc().Truncate(time.Hour); !f.Hour.Equal(hour) {
		f.Hour, f.Calls = hour, 0
	}
}

// ciGet is one GET of GitHub's API, counted against the hour: with the owner's token, or the
// person's gh in the folder when this machine has none.
func (d *Daemon) ciGet(ctx context.Context, h ciRepoHere, path string) ([]byte, error) {
	d.ciMu.Lock()
	f := d.ciFileLocked()
	d.ciHourLocked(f)
	f.Calls++
	d.ciMu.Unlock()
	owner, _, _ := strings.Cut(h.repo.path, "/")
	token, _ := d.githubTokenFor(ctx, owner)
	if token == "" && d.ciAPI == "" {
		exe := forgeCLI("gh")
		if exe == "" {
			return nil, errors.New("no GitHub token and no gh")
		}
		return runForgeCLI(ctx, exe, h.folder, nil, "api", path)
	}
	base := d.ciAPI
	if base == "" {
		base = githubAPI
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if n, err := strconv.Atoi(resp.Header.Get("X-RateLimit-Limit")); err == nil && n > 0 {
		d.ciMu.Lock()
		d.ciFileLocked().Limit = n
		d.ciMu.Unlock()
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub answered %d", resp.StatusCode)
	}
	return body, nil
}

// ciChanged notes that key's runs changed, so its change points are found again.
func (d *Daemon) ciChanged(key string) {
	d.ciMu.Lock()
	if d.ciGen == nil {
		d.ciGen = map[string]int{}
	}
	d.ciGen[key]++
	d.ciMu.Unlock()
}

// ciChangesOf is repo's change points over every run the store has, found again only when its
// runs changed.
func (d *Daemon) ciChangesOf(repo citimings.Repo) ([]citimings.Change, error) {
	key := repo.String()
	d.ciMu.Lock()
	gen := d.ciGen[key]
	found, ok := d.ciChanges[key]
	d.ciMu.Unlock()
	if ok && found.gen == gen {
		return found.changes, nil
	}
	now := nowFunc()
	runs, err := d.ciTimings().Runs(repo, now.AddDate(0, 0, -citimings.KeepDays-1), now.Add(time.Hour))
	if err != nil {
		return nil, err
	}
	changes := citimings.Changes(runs)
	d.ciMu.Lock()
	if d.ciChanges == nil {
		d.ciChanges = map[string]ciChangesFound{}
	}
	d.ciChanges[key] = ciChangesFound{gen, changes}
	d.ciMu.Unlock()
	return changes, nil
}

// MARK: The wire

func (d *Daemon) registerBuilds() {
	On(d, wire.CallBuildsHistory, func(_ context.Context, _ *Client, r wire.BuildsHistoryRequest) (wire.BuildsHistory, error) {
		return d.buildsHistory(r)
	})
	On(d, wire.CallBuildsRun, func(_ context.Context, _ *Client, r wire.BuildsRunRequest) (wire.BuildsRunAnswer, error) {
		return d.buildsRun(r)
	})
}

func (d *Daemon) buildsHistory(r wire.BuildsHistoryRequest) (wire.BuildsHistory, error) {
	repo, err := citimings.ParseRepo(r.Repo)
	if err != nil {
		return wire.BuildsHistory{}, Invalid("builds/history: %v", err)
	}
	from, to := r.From.Time(), r.To.Time()
	if !to.After(from) || to.Sub(from) > (citimings.KeepDays+1)*24*time.Hour {
		return wire.BuildsHistory{}, Invalid("builds/history: from must be before to, at most %d days", citimings.KeepDays)
	}
	loc := time.UTC
	if r.TimeZone != nil && *r.TimeZone != "" {
		if loc, err = time.LoadLocation(*r.TimeZone); err != nil {
			return wire.BuildsHistory{}, Invalid("builds/history: no time zone %q", *r.TimeZone)
		}
	}
	out := wire.BuildsHistory{Repo: repo.String(), Reader: "none", Workflows: []string{}, Jobs: []string{},
		Branches: []string{}, Days: []wire.BuildsDay{}, Changes: []wire.BuildsChange{}, Total: buildsFigures(citimings.Figures{})}
	if repo.Forge != "github" {
		return out, nil
	}
	out.Reader = "github"
	d.ciMu.Lock()
	if st := d.ciFileLocked().Repos[repo.String()]; st != nil {
		if st.Default != "" {
			out.DefaultBranch = new(st.Default)
		}
		if st.ReadAt != nil {
			out.ReadAt = new(wire.DateOf(*st.ReadAt))
		}
		if st.FilledFrom != nil {
			out.FilledFrom = new(wire.DateOf(*st.FilledFrom))
		}
	}
	d.ciMu.Unlock()
	runs, err := d.ciTimings().Runs(repo, from, to)
	if err != nil {
		return out, err
	}
	f := citimings.Filter{Workflow: deref(r.Workflow), Job: deref(r.Job), Branch: deref(r.Branch),
		PullRequests: r.PullRequests != nil && *r.PullRequests}
	out.Workflows, out.Jobs, out.Branches = buildsNames(runs)
	total, days := citimings.Trend(runs, f, loc)
	out.Total = buildsFigures(total)
	for _, day := range days {
		out.Days = append(out.Days, wire.BuildsDay{Day: day.Day, Figures: buildsFigures(day.Figures)})
	}
	if w, ok := citimings.LongestRunnerWait(runs, f); ok {
		out.LongestRunnerWait = &wire.BuildsRunnerWait{Run: buildsRunRef(w.Run), Job: w.Job, Wait: w.Wait, Ran: w.Ran}
	}
	changes, err := d.ciChangesOf(repo)
	if err != nil {
		return out, err
	}
	for _, c := range changes {
		at := c.FirstSlow.MadeAt()
		if at.Before(from) || !at.Before(to) || f.Workflow != "" && c.Workflow != f.Workflow || f.Job != "" && c.Job != f.Job {
			continue
		}
		out.Changes = append(out.Changes, buildsChange(c))
	}
	return out, nil
}

func (d *Daemon) buildsRun(r wire.BuildsRunRequest) (wire.BuildsRunAnswer, error) {
	repo, err := citimings.ParseRepo(r.Repo)
	if err != nil {
		return wire.BuildsRunAnswer{}, Invalid("builds/run: %v", err)
	}
	attempts, err := d.ciTimings().Find(repo, r.Ref)
	if err != nil {
		return wire.BuildsRunAnswer{}, err
	}
	want := 1
	if r.Attempt != nil {
		want = int(*r.Attempt)
	}
	for _, run := range attempts {
		if run.Attempt != want {
			continue
		}
		out := wire.BuildsRunAnswer{Run: buildsRun(run), Attempts: int64(len(attempts))}
		// The run before is days old at most for a pull request; StepDays covers it.
		near, err := d.ciTimings().Runs(repo, run.MadeAt().AddDate(0, 0, -citimings.StepDays), run.MadeAt().Add(time.Second))
		if err != nil {
			return out, err
		}
		if before, ok := citimings.Before(near, run); ok {
			b := buildsRun(before)
			out.Before = &b
		}
		return out, nil
	}
	return wire.BuildsRunAnswer{}, Invalid("builds/run: no attempt %d of %s", want, r.Ref)
}

func buildsNames(runs []citimings.Run) (workflows, jobs, branches []string) {
	workflows, jobs, branches = citimings.Names(runs)
	for _, l := range []*[]string{&workflows, &jobs, &branches} {
		if *l == nil {
			*l = []string{}
		}
	}
	return workflows, jobs, branches
}

func buildsStat(s citimings.Stat) wire.BuildsStat {
	return wire.BuildsStat{Median: s.Median, P90: s.P90, N: int64(s.N)}
}

func buildsFigures(f citimings.Figures) wire.BuildsFigures {
	return wire.BuildsFigures{Runs: int64(f.Runs), Green: int64(f.Green), Reruns: int64(f.Reruns),
		ToGreen: buildsStat(f.ToGreen), Run: buildsStat(f.Run), Runner: buildsStat(f.Runner), Turn: buildsStat(f.Turn)}
}

func buildsRunRef(r citimings.Run) wire.BuildsRunRef {
	out := wire.BuildsRunRef{Ref: r.Ref, ID: r.ID, Attempt: int64(r.Attempt), Made: wire.DateOf(r.MadeAt()),
		URL: optional(r.URL), HeadSha: optional(r.HeadSHA), Branch: optional(r.Branch), Conclusion: optional(r.Conclusion)}
	if r.PR > 0 {
		out.Pr = new(int64(r.PR))
	}
	return out
}

func buildsChange(c citimings.Change) wire.BuildsChange {
	out := wire.BuildsChange{Workflow: c.Workflow, Job: c.Job, Slower: c.Slower(), At: wire.DateOf(c.FirstSlow.MadeAt()),
		LastFast: buildsRunRef(c.LastFast), FirstSlow: buildsRunRef(c.FirstSlow), MedianBefore: c.MedianBefore,
		MedianAfter: c.MedianAfter, QueueBefore: c.QueueBefore, QueueAfter: c.QueueAfter, Score: c.Score,
		Runner: optional(c.Runner), Between: []wire.BuildsBetween{}, Points: []wire.BuildsPoint{}}
	for _, b := range c.Between {
		w := wire.BuildsBetween{Run: buildsRunRef(b.Run), Ran: b.Ran}
		if b.Ran {
			w.JobRun = new(b.JobRun)
		}
		out.Between = append(out.Between, w)
	}
	for _, p := range c.Points {
		out.Points = append(out.Points, wire.BuildsPoint{Ref: p.Run.Ref, Made: wire.DateOf(p.Run.MadeAt()), Ran: p.Ran, Queue: p.Queue})
	}
	return out
}

func buildsRun(r citimings.Run) wire.BuildsRun {
	out := wire.BuildsRun{Ref: r.Ref, ID: r.ID, Attempt: int64(r.Attempt), Workflow: r.Workflow, Event: optional(r.Event),
		Branch: optional(r.Branch), HeadSha: optional(r.HeadSHA), URL: optional(r.URL), Made: wire.DateOf(r.MadeAt()),
		Started: r.Started, Ended: r.Ended, Turn: r.Turn(), Conclusion: optional(r.Conclusion), Jobs: []wire.BuildsJob{}}
	if r.PR > 0 {
		out.Pr = new(int64(r.PR))
	}
	if r.Default {
		out.Default = new(true)
	}
	if r.Tag {
		out.Tag = new(true)
	}
	for _, j := range r.Jobs {
		job := wire.BuildsJob{Name: j.Name, Made: j.Made, Started: j.Started, Ended: j.Ended, Conclusion: optional(j.Conclusion),
			Runner: optional(j.Runner), Steps: []wire.BuildsStep{}}
		for _, s := range j.Steps {
			job.Steps = append(job.Steps, wire.BuildsStep{Name: s.Name, Number: int64(s.Number), Started: s.Started,
				Ended: s.Ended, Conclusion: optional(s.Conclusion)})
		}
		out.Jobs = append(out.Jobs, job)
	}
	return out
}
