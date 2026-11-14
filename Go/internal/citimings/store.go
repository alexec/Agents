// Package citimings is the build timing store (#5177, specs/5166-build-deploy-trends/spec.md,
// "Where the timings live" and "The data spike"): for each CI run attempt of a repository, its
// jobs and their steps, as plain files, bounded, keyed by the run's ci-run ref. Lineage keeps
// only the ci-run node and its links; this store keeps the series.
//
//   - One folder per repository, <root>/<forge>/<path>, and one file per UTC day the run was
//     made, <YYYY-MM-DD>.jsonl, one line per run attempt. Times are seconds from the run's made
//     time.
//   - Bounds (Sweep): KeepDays; at most MostRuns a repository, the oldest pull request runs
//     going first, then the oldest default-branch runs; the steps of a run on a branch other
//     than the default branch (and not a tag) for StepDays, after which its day file is written
//     once more without them.
//
// The package reads and writes files and works out figures (figures.go) and change points
// (changes.go). It asks no forge: the daemon fills it (agentsd/citimings.go).
package citimings

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
)

const (
	// KeepDays is how long a run is kept, as lineage's KeepEnded: a day file past it is deleted
	// whole.
	KeepDays = 90
	// StepDays is how long a run on a branch other than the default branch keeps its steps.
	StepDays = 14
	// MostRuns bounds the run attempts of one repository, as lineage's MostLinks.
	MostRuns = 20_000
	// mostLine bounds one line read back: a run with 100 jobs of 100 steps is far under it.
	mostLine = 4 << 20
)

// mostRuns is MostRuns; a test makes it small.
var mostRuns = MostRuns

// Step is one step of a job, as the forge says it.
type Step struct {
	Name       string  `json:"name"`
	Number     int     `json:"number"`
	Started    float64 `json:"started"`
	Ended      float64 `json:"ended"`
	Conclusion string  `json:"conclusion,omitempty"`
}

// Job is one job of a run attempt: made is when the forge made it (waiting for a runner from
// then), started is when a runner took it.
type Job struct {
	Name       string  `json:"name"`
	Made       float64 `json:"made"`
	Started    float64 `json:"started"`
	Ended      float64 `json:"ended"`
	Conclusion string  `json:"conclusion,omitempty"`
	// Runner is the job's first runner label, as xcode-27 or ubuntu-latest.
	Runner string `json:"runner,omitempty"`
	Steps  []Step `json:"steps,omitempty"`
}

// Run is one attempt of a CI run: a GitHub Actions workflow run.
type Run struct {
	// Ref is the run's ci-run node ref, as github:run:alexec/agents#123.
	Ref     string `json:"ref"`
	ID      int64  `json:"id"`
	Attempt int    `json:"attempt"`
	// Workflow is the workflow's file name, as ci.yml.
	Workflow string `json:"workflow"`
	Event    string `json:"event,omitempty"`
	Branch   string `json:"branch,omitempty"`
	HeadSHA  string `json:"headSha,omitempty"`
	// Default is a run on the repository's default branch; Tag a run on a tag.
	Default bool `json:"default,omitempty"`
	Tag     bool `json:"tag,omitempty"`
	// PR is the run's pull request number, 0 for none.
	PR  int    `json:"pr,omitempty"`
	URL string `json:"url,omitempty"`
	// Made is when the run was made, in Unix seconds; a re-run keeps it.
	Made int64 `json:"made"`
	// Started is the attempt's start, Ended its last job's end, in seconds from Made.
	Started    float64 `json:"started"`
	Ended      float64 `json:"ended"`
	Conclusion string  `json:"conclusion,omitempty"`
	Jobs       []Job   `json:"jobs"`
}

// MadeAt is when the run was made.
func (r Run) MadeAt() time.Time { return time.Unix(r.Made, 0).UTC() }

// key is the run's line in its day file: one per ci-run ref and attempt.
func (r Run) key() string { return fmt.Sprintf("%s\t%d", r.Ref, r.Attempt) }

// pullRequest is a run that is neither on the default branch nor on a tag: the first to go.
func (r Run) pullRequest() bool { return !r.Default && !r.Tag }

func (r Run) hasSteps() bool {
	for _, j := range r.Jobs {
		if len(j.Steps) > 0 {
			return true
		}
	}
	return false
}

// Store is the timing store under Root. Safe for use by several goroutines.
type Store struct {
	Root string
	mu   sync.Mutex
}

// Repo is a repository as lineage refs name it: forge github, path owner/repo, lower case.
type Repo struct{ Forge, Path string }

func (r Repo) String() string { return r.Forge + ":" + r.Path }

// ParseRepo is a repository from its string form, forge:path.
func ParseRepo(s string) (Repo, error) {
	forge, path, ok := strings.Cut(strings.ToLower(strings.TrimSpace(s)), ":")
	r := Repo{forge, strings.Trim(path, "/")}
	if !ok || r.dirOK() != nil {
		return Repo{}, fmt.Errorf("not a repository: %q", s)
	}
	return r, nil
}

// dirOK refuses a repository whose folder would be outside the store.
func (r Repo) dirOK() error {
	parts := append([]string{r.Forge}, strings.Split(r.Path, "/")...)
	if r.Path == "" || len(parts) > 6 {
		return errors.New("no path")
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || strings.ContainsAny(p, `\`+"\x00") {
			return fmt.Errorf("bad part %q", p)
		}
	}
	return nil
}

func (s *Store) dir(r Repo) (string, error) {
	if err := r.dirOK(); err != nil {
		return "", err
	}
	return filepath.Join(append([]string{s.Root, r.Forge}, strings.Split(r.Path, "/")...)...), nil
}

func dayOf(t time.Time) string { return t.UTC().Format(time.DateOnly) }

// Put keeps runs, each in place of the line of the same ref and attempt.
func (s *Store) Put(r Repo, runs ...Run) error {
	dir, err := s.dir(r)
	if err != nil {
		return err
	}
	byDay := map[string][]Run{}
	for _, run := range runs {
		if run.Ref == "" || run.Attempt < 1 {
			return fmt.Errorf("a run with no ref or attempt: %d", run.ID)
		}
		byDay[dayOf(run.MadeAt())] = append(byDay[dayOf(run.MadeAt())], run)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for day, put := range byDay {
		path := filepath.Join(dir, day+".jsonl")
		kept, err := readDay(path)
		if err != nil {
			return err
		}
		at := map[string]int{}
		for i, k := range kept {
			at[k.key()] = i
		}
		for _, run := range put {
			if i, ok := at[run.key()]; ok {
				kept[i] = run
			} else {
				at[run.key()] = len(kept)
				kept = append(kept, run)
			}
		}
		if err := writeDay(path, kept); err != nil {
			return err
		}
	}
	return nil
}

// Has says whether the store has the attempt of ref, made on made's day.
func (s *Store) Has(r Repo, ref string, attempt int, made time.Time) bool {
	dir, err := s.dir(r)
	if err != nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	runs, _ := readDay(filepath.Join(dir, dayOf(made)+".jsonl"))
	return slices.ContainsFunc(runs, func(k Run) bool { return k.Ref == ref && k.Attempt == attempt })
}

// Runs is every run attempt made in [from, to), oldest first.
func (s *Store) Runs(r Repo, from, to time.Time) ([]Run, error) {
	dir, err := s.dir(r)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	days, err := dayFiles(dir)
	if err != nil {
		return nil, err
	}
	var out []Run
	for _, day := range days {
		if day < dayOf(from) || day > dayOf(to) {
			continue
		}
		runs, err := readDay(filepath.Join(dir, day+".jsonl"))
		if err != nil {
			return nil, err
		}
		for _, run := range runs {
			if t := run.MadeAt(); !t.Before(from) && t.Before(to) {
				out = append(out, run)
			}
		}
	}
	sortRuns(out)
	return out, nil
}

// Find is the attempts of ref, oldest attempt first, looking from the newest day back.
func (s *Store) Find(r Repo, ref string) ([]Run, error) {
	dir, err := s.dir(r)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	days, err := dayFiles(dir)
	if err != nil {
		return nil, err
	}
	for i := len(days) - 1; i >= 0; i-- {
		runs, err := readDay(filepath.Join(dir, days[i]+".jsonl"))
		if err != nil {
			return nil, err
		}
		var found []Run
		for _, run := range runs {
			if run.Ref == ref {
				found = append(found, run)
			}
		}
		if len(found) > 0 {
			sort.Slice(found, func(a, b int) bool { return found[a].Attempt < found[b].Attempt })
			return found, nil
		}
	}
	return nil, nil
}

// Repos is every repository the store has a folder for.
func (s *Store) Repos() []Repo {
	var out []Repo
	forges, _ := os.ReadDir(s.Root)
	for _, f := range forges {
		if !f.IsDir() {
			continue
		}
		base := filepath.Join(s.Root, f.Name())
		_ = filepath.WalkDir(base, func(p string, e os.DirEntry, err error) error {
			if err != nil || e.IsDir() || !strings.HasSuffix(p, ".jsonl") {
				return nil
			}
			rel, _ := filepath.Rel(base, filepath.Dir(p))
			r := Repo{f.Name(), filepath.ToSlash(rel)}
			if !slices.Contains(out, r) {
				out = append(out, r)
			}
			return filepath.SkipDir
		})
	}
	return out
}

// Sweep applies the bounds to r's runs at now.
func (s *Store) Sweep(r Repo, now time.Time) error {
	dir, err := s.dir(r)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	days, err := dayFiles(dir)
	if err != nil {
		return err
	}
	oldest, stepsFrom := dayOf(now.AddDate(0, 0, -KeepDays)), dayOf(now.AddDate(0, 0, -StepDays))
	type held struct {
		day     string
		n       int
		pr      int
		removed bool
	}
	var kept []held
	total := 0
	for _, day := range days {
		path := filepath.Join(dir, day+".jsonl")
		if day < oldest {
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			continue
		}
		runs, err := readDay(path)
		if err != nil {
			return err
		}
		if day < stepsFrom && slices.ContainsFunc(runs, func(run Run) bool { return run.pullRequest() && run.hasSteps() }) {
			for i := range runs {
				if runs[i].pullRequest() {
					for j := range runs[i].Jobs {
						runs[i].Jobs[j].Steps = nil
					}
				}
			}
			if err := writeDay(path, runs); err != nil {
				return err
			}
		}
		h := held{day: day, n: len(runs)}
		for _, run := range runs {
			if run.pullRequest() {
				h.pr++
			}
		}
		kept = append(kept, h)
		total += len(runs)
	}
	if total <= mostRuns {
		return nil
	}
	// Past the bound: the oldest pull request runs first, then the oldest runs of any kind.
	over := total - mostRuns
	for _, onlyPRs := range []bool{true, false} {
		for i := range kept {
			if over == 0 {
				return nil
			}
			if kept[i].removed || onlyPRs && kept[i].pr == 0 {
				continue
			}
			path := filepath.Join(dir, kept[i].day+".jsonl")
			runs, err := readDay(path)
			if err != nil {
				return err
			}
			sortRuns(runs)
			var left []Run
			for _, run := range runs {
				if over > 0 && (!onlyPRs || run.pullRequest()) {
					over--
					continue
				}
				left = append(left, run)
			}
			if len(left) == 0 {
				kept[i].removed = true
				if err := os.Remove(path); err != nil {
					return err
				}
				continue
			}
			kept[i].pr = 0
			for _, run := range left {
				if run.pullRequest() {
					kept[i].pr++
				}
			}
			if err := writeDay(path, left); err != nil {
				return err
			}
		}
	}
	return nil
}

func sortRuns(runs []Run) {
	sort.SliceStable(runs, func(a, b int) bool {
		if runs[a].Made != runs[b].Made {
			return runs[a].Made < runs[b].Made
		}
		if runs[a].ID != runs[b].ID {
			return runs[a].ID < runs[b].ID
		}
		return runs[a].Attempt < runs[b].Attempt
	})
}

// dayFiles is the days dir has a file for, oldest first.
func dayFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var days []string
	for _, e := range entries {
		day, ok := strings.CutSuffix(e.Name(), ".jsonl")
		if _, err := time.Parse(time.DateOnly, day); ok && err == nil && !e.IsDir() {
			days = append(days, day)
		}
	}
	sort.Strings(days)
	return days, nil
}

// readDay is a day file's runs. A line that cannot be read is skipped: one bad line does not
// lose the day.
func readDay(path string) ([]Run, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 0, 64<<10), mostLine)
	var runs []Run
	for sc.Scan() {
		var run Run
		if json.Unmarshal(sc.Bytes(), &run) == nil && run.Ref != "" {
			runs = append(runs, run)
		}
	}
	return runs, nil
}

func writeDay(path string, runs []Run) error {
	sortRuns(runs)
	var b bytes.Buffer
	for _, run := range runs {
		line, err := json.Marshal(run)
		if err != nil {
			return err
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return store.WriteAtomically(path, b.Bytes(), 0o644)
}
