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
	"github.com/agentloops-dev/agent-loops/Go/internal/gitlabmcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Build timings (#5177, specs/5166-build-deploy-trends/spec.md, "The data spike"): this
// machine reads each GitHub repository's CI runs (and Azure DevOps's builds, #5222,
// citimingsazure.go), with their jobs and steps, into the timing
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
// The control plane keeps a copy (#5232, cisync.go): each day of runs that changes goes to it
// a few seconds later (builds/sync), and it answers builds/historyAll and builds/runAll from
// it while this machine sleeps.

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
	// ciGitLabJobPages bounds the pages of one pipeline's jobs: 500.
	ciGitLabJobPages = 5
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
	// ciAPI is GitHub's API; "" is api.github.com. A test sets it. ciGitLabAPI is the same for
	// GitLab's root, with no connection needed.
	ciAPI, ciGitLabAPI string
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
	// AzureDevOpsCalls counts Azure DevOps's calls this hour apart (citimingsazure.go).
	AzureDevOpsCalls int `json:"azureDevOpsCalls,omitempty"`
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
	// Slowed is each change ci.slowed was sent for, by its id (#5200, cislowed.go).
	Slowed map[string]ciSlowedSent `json:"slowed,omitempty"`
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

// ciRepoHere is a GitHub or Azure DevOps repository a folder pushes to, and that folder, for
// gh or for the Azure DevOps it is on.
type ciRepoHere struct {
	repo   forgeRepo
	folder string
}

// ciReposHere is the GitHub, GitLab and Azure DevOps repositories the folders push to, at most
// ciMostRepos. A GitLab one counts when the person's GitLab connection is on its root.
func (d *Daemon) ciReposHere(ctx context.Context) []ciRepoHere {
	seen := map[string]bool{}
	var out []ciRepoHere
	for _, f := range d.folderPaths() {
		r := d.folderRepo(f)
		if r.forge == "gitlab" {
			if root, project := d.ciGitLabAt(ctx, f); root != "" {
				r.path = project
			} else {
				continue
			}
		}
		if !ciReads(r.forge) || seen[r.forge+":"+r.path] || len(out) >= ciMostRepos {
			continue
		}
		seen[r.forge+":"+r.path] = true
		out = append(out, ciRepoHere{r, f})
	}
	return out
}

// ciGitLabAt is the connected GitLab's root, when folder's project is on it, and the project.
func (d *Daemon) ciGitLabAt(ctx context.Context, folder string) (root, project string) {
	if d.ciGitLabAPI != "" {
		return d.ciGitLabAPI, d.folderRepo(folder).path
	}
	c, ok := d.gitlabConnection()
	if !ok || !c.Usable(nowFunc()) {
		return "", ""
	}
	at, project := d.gitlabProjectAt(ctx, folder, c.URL)
	if at != gitlabmcp.BaseURL(c.URL) || project == "" {
		return "", ""
	}
	return at, project
}

// readCITimings is one read of every repository: live, then the backfill within its budget,
// then the bounds once an hour.
func (d *Daemon) readCITimings(ctx context.Context) {
	for _, h := range d.ciReposHere(ctx) {
		if ctx.Err() != nil {
			return
		}
		if err := d.readCIRepo(ctx, h); err != nil {
			log.Printf("build timings: %s: %v", h.repo.path, err)
		}
	}
}

// ciReads says the build timings read a forge's CI: its builds/history reader.
func ciReads(forge string) bool { return citimings.Reads(forge) }

func (d *Daemon) readCIRepo(ctx context.Context, h ciRepoHere) error {
	key := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}.String()
	read := d.ciGitHubRead
	if h.repo.forge == "azuredevops" {
		read = d.ciAzureRead
	}
	if err := read(ctx, h, key); err != nil {
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
		changed, err := d.ciTimings().Sweep(repo, nowFunc())
		d.noteCIDays(repo, changed...)
		if err != nil {
			return fmt.Errorf("sweep: %w", err)
		}
		d.ciChanged(key)
	}
	d.ciSendSlowed(citimings.Repo{Forge: h.repo.forge, Path: h.repo.path})
	return nil
}

// ciGitHubRead is one read of a GitHub repository: its default branch, live, then the backfill
// within its budget.
func (d *Daemon) ciGitHubRead(ctx context.Context, h ciRepoHere, key string) error {
	def, err := d.ciDefaultBranch(ctx, h, key)
	if err != nil {
		return err
	}
	if err := d.ciLive(ctx, h, key, def); err != nil {
		return err
	}
	return d.ciBackfill(ctx, h, key, def)
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
	raw, err := d.ciGet(ctx, h, d.ciRepoPath(h))
	if err != nil {
		return "", err
	}
	var repo struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := json.Unmarshal(raw, &repo); err != nil || repo.DefaultBranch == "" {
		return "", fmt.Errorf("%s did not say the default branch", ciForgeName(h))
	}
	d.ciMu.Lock()
	st = d.ciRepoLocked(key)
	st.Default, st.DefaultAt = repo.DefaultBranch, nowFunc()
	d.saveCIFileLocked()
	d.ciMu.Unlock()
	d.noteCIMeta(key)
	return repo.DefaultBranch, nil
}

// ciLive reads the newest finished runs, until a page has nothing new.
func (d *Daemon) ciLive(ctx context.Context, h ciRepoHere, key, def string) error {
	for page := 1; page <= ciLivePages; page++ {
		listed, added, err := d.ciPage(ctx, h, def, page, nil, nowFunc())
		if err != nil {
			return err
		}
		if added == 0 || listed < 100 {
			break
		}
	}
	at := nowFunc()
	d.ciMu.Lock()
	d.ciRepoLocked(key).ReadAt = &at
	d.saveCIFileLocked()
	d.ciMu.Unlock()
	d.noteCIMeta(key)
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
			listed, _, err := d.ciPage(ctx, h, def, page, &[2]time.Time{from, to}, now)
			if err != nil {
				return err
			}
			if listed < 100 {
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
		d.noteCIMeta(key)
	}
	return nil
}

// ciPage reads one page of finished runs, in window when there is one, and keeps each the store
// does not have: how many the page listed and how many it kept.
func (d *Daemon) ciPage(ctx context.Context, h ciRepoHere, def string, page int, window *[2]time.Time, now time.Time) (listed, added int, err error) {
	if h.repo.forge == "gitlab" {
		q := url.Values{"scope": {"finished"}, "per_page": {"100"}, "page": {strconv.Itoa(page)}}
		if window != nil {
			q.Set("created_after", window[0].UTC().Format(time.RFC3339))
			q.Set("created_before", window[1].UTC().Format(time.RFC3339))
		}
		raw, err := d.ciGet(ctx, h, fmt.Sprintf("projects/%s/pipelines?%s", ciGitLabID(h), q.Encode()))
		if err != nil {
			return 0, 0, err
		}
		var list []citimings.GitLabPipeline
		if err := json.Unmarshal(raw, &list); err != nil {
			return 0, 0, fmt.Errorf("the pipeline list: %v", err)
		}
		added, err = d.ciKeepPipelines(ctx, h, def, list, now)
		return len(list), added, err
	}
	q := url.Values{"status": {"completed"}, "per_page": {"100"}, "page": {strconv.Itoa(page)}}
	if window != nil {
		q.Set("created", window[0].UTC().Format(time.RFC3339)+".."+window[1].UTC().Format(time.RFC3339))
	}
	list, err := d.ciList(ctx, h, q)
	if err != nil {
		return 0, 0, err
	}
	added, err = d.ciKeepRuns(ctx, h, def, list.WorkflowRuns, now)
	return len(list.WorkflowRuns), added, err
}

// ciKeepPipelines is ciKeepRuns for GitLab: the jobs of each pipeline the store does not have,
// retried tries included (one call, or one a page of 100 jobs).
func (d *Daemon) ciKeepPipelines(ctx context.Context, h ciRepoHere, def string, pipelines []citimings.GitLabPipeline, now time.Time) (int, error) {
	repo := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}
	added := 0
	for _, p := range pipelines {
		if ctx.Err() != nil {
			return added, ctx.Err()
		}
		made, err := time.Parse(time.RFC3339, p.CreatedAt)
		if err != nil || !p.Finished() {
			continue
		}
		onDefault := p.Ref == def && p.Source != "merge_request_event"
		onTag := versionTagPattern.MatchString(p.Ref)
		keep := citimings.StepDays
		if onDefault || onTag {
			keep = citimings.KeepDays
		}
		ref := h.repo.ciRun(p.ID).Ref
		// Decided: a pipeline the store has is not read again, so a retry after the first read
		// is not seen (GitHub's list says the attempt; GitLab's does not).
		if now.Sub(made) > time.Duration(keep)*24*time.Hour || d.ciTimings().Has(repo, ref, 1, made) {
			continue
		}
		var jobs []json.RawMessage
		for page := 1; page <= ciGitLabJobPages; page++ {
			raw, err := d.ciGet(ctx, h, fmt.Sprintf("projects/%s/pipelines/%d/jobs?include_retried=true&per_page=100&page=%d", ciGitLabID(h), p.ID, page))
			if err != nil {
				return added, err
			}
			var got []json.RawMessage
			if err := json.Unmarshal(raw, &got); err != nil {
				return added, fmt.Errorf("pipeline %d: the jobs answer: %v", p.ID, err)
			}
			jobs = append(jobs, got...)
			if len(got) < 100 {
				break
			}
		}
		all, _ := json.Marshal(jobs)
		got, err := citimings.FromGitLab(p, all, ref, onDefault, onTag)
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
		for _, run := range got {
			d.noteCIDays(repo, citimings.DayOf(run.MadeAt()))
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
		f.Hour, f.Calls, f.AzureDevOpsCalls = hour, 0, 0
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
	if h.repo.forge == "gitlab" {
		return d.ciGetGitLab(ctx, h, path)
	}
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

// ciGetGitLab is one GET of GitLab's API with the person's connection.
func (d *Daemon) ciGetGitLab(ctx context.Context, h ciRepoHere, path string) ([]byte, error) {
	root, token := d.ciGitLabAPI, "test"
	if root == "" {
		c, ok := d.gitlabConnection()
		if !ok || !c.Usable(nowFunc()) {
			return nil, errors.New(gitlabmcp.NotConnected)
		}
		root, token = gitlabmcp.BaseURL(c.URL), c.Access
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(root, "/")+"/api/v4/"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
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
		return nil, fmt.Errorf("GitLab answered %d", resp.StatusCode)
	}
	return body, nil
}

// ciRepoPath is the path of the repository itself.
func (d *Daemon) ciRepoPath(h ciRepoHere) string {
	if h.repo.forge == "gitlab" {
		return "projects/" + ciGitLabID(h)
	}
	return "repos/" + h.repo.path
}

// ciGitLabID is the project's path as GitLab's URLs take it.
func ciGitLabID(h ciRepoHere) string {
	return strings.ReplaceAll(url.PathEscape(h.repo.path), "/", "%2F")
}

func ciForgeName(h ciRepoHere) string {
	if h.repo.forge == "gitlab" {
		return "GitLab"
	}
	return "GitHub"
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
	a, err := citimings.ReadHistoryAsk(r)
	if err != nil {
		return wire.BuildsHistory{}, Invalid("builds/history: %v", err)
	}
	out := citimings.EmptyHistory(a.Repo)
	if !ciReads(a.Repo.Forge) {
		return out, nil
	}
	out.Reader = a.Repo.Forge
	d.ciMu.Lock()
	if st := d.ciFileLocked().Repos[a.Repo.String()]; st != nil {
		out.DefaultBranch, out.ReadAt, out.FilledFrom = st.wireMeta()
	}
	d.ciMu.Unlock()
	runs, err := d.ciTimings().Runs(a.Repo, a.From, a.To)
	if err != nil {
		return out, err
	}
	changes, err := d.ciChangesOf(a.Repo)
	if err != nil {
		return out, err
	}
	// A change point says when this machine sent its ci.slowed (#5200).
	return citimings.History(out, a, runs, changes, func(c citimings.Change, w *wire.BuildsChange) {
		w.SlowedSent = d.ciSlowedSentAt(a.Repo, c)
	}), nil
}

// wireMeta is the repository's default branch, last read and backfill reach, as the wire says
// them.
func (st *ciRepoState) wireMeta() (def *string, readAt, filledFrom *wire.Date) {
	if st.Default != "" {
		def = new(st.Default)
	}
	if st.ReadAt != nil {
		readAt = new(wire.DateOf(*st.ReadAt))
	}
	if st.FilledFrom != nil {
		filledFrom = new(wire.DateOf(*st.FilledFrom))
	}
	return def, readAt, filledFrom
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
	out, ok, err := citimings.RunAnswer(attempts, want, func(run citimings.Run) ([]citimings.Run, error) {
		from, to := citimings.NearFrom(run)
		return d.ciTimings().Runs(repo, from, to)
	})
	if !ok {
		return out, Invalid("builds/run: no attempt %d of %s", want, r.Ref)
	}
	return out, err
}
