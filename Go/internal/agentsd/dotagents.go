package agentsd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// The ready-made workflows and skills (#1342, #1633, #3307) are not in this binary (#5091): they
// are in a GitHub repository, readyMadeRepo, as workflows/<id>.md and skills/<id>/SKILL.md, the
// same layout as ~/.agents. A workflow's skill is the skill of its id; a skill with no workflow
// of its id is a ready-made skill with no workflow, such as start-a-new-app.
//
// Each release pins one tag of it, and that tag's commit: the release sets both
// (scripts/dotagents.sh pin), so a skill names the tools that this release serves, and a push to
// the repository changes nothing a release installs. agentsd fetches the pinned tag in the
// background, keeps the last copy it fetched in readyMadeCopyPath, and installs from that copy.
// With no network and no copy yet, it installs nothing and tries again later.

// readyMadeRepo is the repository of the ready-made workflows and skills, owner/name.
var readyMadeRepo = "agentloops-dev/dotagents"

// readyMadeTag and readyMadeCommit are the release's pin: the tag fetched, and the commit it
// must be. A copy of another commit is refused, so a moved tag installs nothing.
var (
	readyMadeTag    = "v0.1.0"
	readyMadeCommit = "32b6fdf090eeefc2acc60838ea33d99f7591c5a3"
)

// readyMadeGitBase is where the repository is cloned from: GitHub, or a folder of bare
// repositories in a test.
var readyMadeGitBase = "https://github.com"

// readyMadeMaxBytes bounds the repository's files, so a large repository is refused rather
// than read into memory.
const readyMadeMaxBytes = 4 << 20

// readyMadeRetry is how long after a failed fetch the next is tried.
const readyMadeRetry = 10 * time.Minute

// readyMadeWorkflow is one ready-made workflow and its skill.
type readyMadeWorkflow struct {
	Workflow string `json:"workflow"`
	Skill    string `json:"skill"`
}

// readyMadeSet is one fetched version of the repository: what readyMadeCopyPath keeps.
type readyMadeSet struct {
	Tag       string                       `json:"tag"`
	Commit    string                       `json:"commit"`
	Workflows map[string]readyMadeWorkflow `json:"workflows"`
	Skills    map[string]string            `json:"skills"` // with no workflow
}

// pinned is whether this set is the release's pin, so its text is the release's own.
func (s *readyMadeSet) pinned() bool {
	return s != nil && readyMadeCommit != "" && s.Commit == readyMadeCommit
}

// current is whether this set is the pinned tag, so no fetch is needed.
func (s *readyMadeSet) current() bool {
	return s != nil && s.Tag == readyMadeTag && (readyMadeCommit == "" || s.Commit == readyMadeCommit)
}

// ids is every ready-made workflow, by id, sorted.
func (s *readyMadeSet) ids() []string { return sortedKeys(s.workflowMap()) }

// skillIDs is every ready-made skill with no workflow, by id, sorted.
func (s *readyMadeSet) skillIDs() []string {
	if s == nil {
		return nil
	}
	return sortedKeys(s.Skills)
}

func (s *readyMadeSet) workflowMap() map[string]readyMadeWorkflow {
	if s == nil {
		return nil
	}
	return s.Workflows
}

func (s *readyMadeSet) has(id string) bool {
	_, ok := s.workflowMap()[id]
	return ok
}

// text is a ready-made workflow and its skill, or "" for an id that is not one.
func (s *readyMadeSet) text(id string) (workflow, skill string) {
	w := s.workflowMap()[id]
	return w.Workflow, w.Skill
}

// readyMadeCopyPath is where the last fetched copy is kept.
func readyMadeCopyPath(home string) string {
	return filepath.Join(home, ".agents", "settings", "ready-made-copy.json")
}

// readyMadeCache keeps the copy read from each home's file, so a scan does not read it again
// until the file changes.
var readyMadeCache struct {
	sync.Mutex
	byPath map[string]readyMadeCached
}

type readyMadeCached struct {
	modTime time.Time
	size    int64
	set     *readyMadeSet
}

// loadReadyMade is the copy kept in home, or nil when there is none, or it does not read.
func loadReadyMade(home string) *readyMadeSet {
	if home == "" {
		return nil
	}
	path := readyMadeCopyPath(home)
	fi, err := os.Stat(path)
	if err != nil {
		return nil
	}
	readyMadeCache.Lock()
	defer readyMadeCache.Unlock()
	if c, ok := readyMadeCache.byPath[path]; ok && c.modTime.Equal(fi.ModTime()) && c.size == fi.Size() {
		return c.set
	}
	var set *readyMadeSet
	if data, err := os.ReadFile(path); err == nil {
		var s readyMadeSet
		if json.Unmarshal(data, &s) == nil {
			set = &s
		}
	}
	if readyMadeCache.byPath == nil {
		readyMadeCache.byPath = map[string]readyMadeCached{}
	}
	readyMadeCache.byPath[path] = readyMadeCached{modTime: fi.ModTime(), size: fi.Size(), set: set}
	return set
}

// saveReadyMade keeps a fetched copy in home.
func saveReadyMade(home string, set *readyMadeSet) error {
	data, err := json.Marshal(set)
	if err != nil {
		return err
	}
	path := readyMadeCopyPath(home)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return store.WriteAtomically(path, data, 0o644)
}

// readyMadeFetch fetches a tag of the repository. A test replaces it with a fixture.
var readyMadeFetch = fetchReadyMadeFromGit

// readyMadeFetchInline makes the fetch run in the scan that needs it, not after: a test's
// daemon then has its ready-made workflows when it starts. Never in the app, where the scan
// holds workflowMu and a fetch can wait on the network.
var readyMadeFetchInline = false

// fetchReadyMadeFromGit is a shallow clone of repo's tag, read into a set. It refuses a clone
// whose commit is not commit, when commit is set.
func fetchReadyMadeFromGit(repo, tag, commit string) (*readyMadeSet, error) {
	dir, err := os.MkdirTemp("", "agents-dotagents-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	env := []string{"GIT_TERMINAL_PROMPT=0"}
	clone := filepath.Join(dir, "dotagents")
	if _, err := newAppGit(dir, env, "clone", "-q", "--depth=1", "--branch", tag, "--", readyMadeGitBase+"/"+repo+".git", clone); err != nil {
		return nil, fmt.Errorf("could not fetch %s at %s: %v", repo, tag, err)
	}
	head, err := newAppGit(clone, env, "rev-parse", "HEAD")
	if err != nil {
		return nil, err
	}
	if commit != "" && head != commit {
		return nil, fmt.Errorf("%s at %s is commit %s, not the pinned %s", repo, tag, head, commit)
	}
	set, err := readReadyMadeDir(clone)
	if err != nil {
		return nil, err
	}
	set.Tag, set.Commit = tag, head
	return set, nil
}

// readReadyMadeDir reads a copy of the repository: workflows/<id>.md and skills/<id>/SKILL.md.
// A workflow with no skill of its id is left out.
func readReadyMadeDir(dir string) (*readyMadeSet, error) {
	set := &readyMadeSet{Workflows: map[string]readyMadeWorkflow{}, Skills: map[string]string{}}
	total := 0
	read := func(p string) (string, bool, error) {
		fi, err := os.Lstat(p)
		if errors.Is(err, fs.ErrNotExist) {
			return "", false, nil
		}
		if err != nil || !fi.Mode().IsRegular() {
			return "", false, err
		}
		if total += int(fi.Size()); total > readyMadeMaxBytes {
			return "", false, fmt.Errorf("the ready-made workflows are more than %d MB", readyMadeMaxBytes>>20)
		}
		b, err := os.ReadFile(p)
		return string(b), err == nil, err
	}
	skills, _ := os.ReadDir(filepath.Join(dir, "skills"))
	for _, e := range skills {
		id := e.Name()
		if !e.IsDir() || !validWorkflowID(id) {
			continue
		}
		skill, ok, err := read(filepath.Join(dir, "skills", id, "SKILL.md"))
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		workflow, ok, err := read(filepath.Join(dir, "workflows", id+".md"))
		if err != nil {
			return nil, err
		}
		if ok {
			set.Workflows[id] = readyMadeWorkflow{Workflow: workflow, Skill: skill}
		} else {
			set.Skills[id] = skill
		}
	}
	if len(set.Workflows)+len(set.Skills) == 0 {
		return nil, errors.New("the repository has no ready-made workflows or skills")
	}
	return set, nil
}

// readyMadeFetching is one fetch at a time, and when the last one failed.
type readyMadeFetching struct {
	readyMadeMu     sync.Mutex
	readyMadeBusy   bool
	readyMadeFailed time.Time
}

// readyMadeLocked is the ready-made copy to install from: the last one fetched into home. When
// it is not the pinned tag, a fetch starts; the scan after it installs what it fetched.
func (d *Daemon) readyMadeLocked(home string) *readyMadeSet {
	set := loadReadyMade(home)
	if home == "" || set.current() {
		return set
	}
	d.readyMadeMu.Lock()
	if d.readyMadeBusy || time.Since(d.readyMadeFailed) < readyMadeRetry {
		d.readyMadeMu.Unlock()
		return set
	}
	d.readyMadeBusy = true
	d.readyMadeMu.Unlock()
	if readyMadeFetchInline {
		if d.fetchReadyMade(home) {
			return loadReadyMade(home)
		}
		return set
	}
	if !d.goAfterTurn("ready-made fetch", func() {
		if d.fetchReadyMade(home) && !d.going() {
			d.workflowMu.Lock()
			d.scanLocked()
			d.workflowMu.Unlock()
			d.tellEveryWorkflow()
		}
	}) {
		d.readyMadeMu.Lock()
		d.readyMadeBusy = false
		d.readyMadeMu.Unlock()
	}
	return set
}

// fetchReadyMade fetches the pinned tag into home, and says whether it did.
func (d *Daemon) fetchReadyMade(home string) bool {
	set, err := readyMadeFetch(readyMadeRepo, readyMadeTag, readyMadeCommit)
	if err == nil {
		err = saveReadyMade(home, set)
	}
	d.readyMadeMu.Lock()
	d.readyMadeBusy = false
	if err != nil {
		d.readyMadeFailed = time.Now()
	} else {
		d.readyMadeFailed = time.Time{}
	}
	d.readyMadeMu.Unlock()
	if err != nil {
		log.Printf("workflows: the ready-made workflows were not fetched, trying again in %s: %v", readyMadeRetry, err)
		return false
	}
	log.Printf("workflows: fetched the ready-made workflows %s at %s (%s)", readyMadeRepo, set.Tag, strings.TrimSpace(set.Commit))
	return true
}
