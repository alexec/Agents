package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Release nodes from tags (#3023, part 1): the graph stopped at "merged"; this links a PR
// part-of the release that shipped it, and a milestone shipped-in the release whose title
// starts with its version, so the graph and the cost rollup reach "got to people".
//
//   - Kind release, ref github:<owner>/<repo>/release/<tag> (GitLab: gitlab:<group>/<project>/release/<tag>).
//   - The host reads each folder's tags with `git ls-remote --tags origin`, at most once an
//     hour (#3023's decided answer (a)): no forge event says "tag pushed" today.
//   - A new v* tag gets the commits since the version tag before it (the forge's compare
//     API), each one's PR from the "(#n)" / "!n" a squash title ends with, or asked of the
//     forge (commits/<sha>/pulls) when the title has no number. Bounded at releaseCommitsMax
//     commits.
//   - A tag with no earlier version tag links no PRs (decided answer (b)): the first release
//     does not get the whole history.
//   - A release's links are at the tag's commit time (decided answer (c)), not when the host
//     happened to notice it.
//   - Each tag is done once, kept in <root>/release-tags.json by repo, so a host that was off
//     when a tag was pushed still finds it, and never re-asks the forge for one it already did.

const (
	releaseTagsInterval = time.Hour
	// releaseCommitsMax bounds one release: a tag with more commits than this links only
	// the first releaseCommitsMax of them.
	releaseCommitsMax = 1_000
)

// releaseTagsDelay is how long after the start the first check is. Tests set it.
var releaseTagsDelay = time.Minute

var versionTagPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

type releaseTagsFile struct {
	// Done is each repo's (forge:path) tags already linked, so a tag is done once.
	Done map[string][]string `json:"done,omitempty"`
}

type releaseTagsBook struct {
	releaseMu   sync.Mutex
	releaseFile *releaseTagsFile
	// releaseTags, releaseCommitTime, releaseCompare, releaseCommitPR and releaseMilestones,
	// when set, are asked in place of the package defaults; only tests set them.
	releaseTags        func(folder string) ([]string, error)
	releaseCommitTime  func(ctx context.Context, folder string, repo forgeRepo, ref string) (time.Time, error)
	releaseCompare     func(ctx context.Context, folder string, repo forgeRepo, base, head string) ([]compareCommit, error)
	releaseCommitPR    func(ctx context.Context, folder string, repo forgeRepo, sha string) (int, error)
	releaseMilestones  func(ctx context.Context, folder string, repo forgeRepo) ([]forgeMilestone, error)
}

func (r forgeRepo) release(tag string) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindRelease, Ref: r.forge + ":" + r.path + "/release/" + tag}
}

func (d *Daemon) releaseTagsPath() string { return filepath.Join(d.Store.Loc.Root, "release-tags.json") }

func (d *Daemon) releaseTagsFileLocked() *releaseTagsFile {
	if d.releaseFile == nil {
		d.releaseFile = &releaseTagsFile{}
		readStore(d.releaseTagsPath(), d.releaseFile, "the releases found start again from the folders' tags")
		if d.releaseFile.Done == nil {
			d.releaseFile.Done = map[string][]string{}
		}
	}
	return d.releaseFile
}

func (d *Daemon) doneReleaseTags(repo forgeRepo) map[string]bool {
	d.releaseMu.Lock()
	defer d.releaseMu.Unlock()
	f := d.releaseTagsFileLocked()
	done := map[string]bool{}
	for _, t := range f.Done[repo.forge+":"+repo.path] {
		done[t] = true
	}
	return done
}

func (d *Daemon) markReleaseTagDone(repo forgeRepo, tag string) {
	d.releaseMu.Lock()
	defer d.releaseMu.Unlock()
	f := d.releaseTagsFileLocked()
	key := repo.forge + ":" + repo.path
	for _, t := range f.Done[key] {
		if t == tag {
			return
		}
	}
	f.Done[key] = append(f.Done[key], tag)
	if err := writeStore(d.releaseTagsPath(), f); err != nil {
		log.Printf("release-tags.json: could not save: %v", err)
	}
}

// checkReleaseTagsEveryHour reads every folder's tags a minute after the start, then every
// hour.
func (d *Daemon) checkReleaseTagsEveryHour() {
	safe.Go("release tags", func() {
		wait := time.NewTimer(releaseTagsDelay)
		defer wait.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-wait.C:
			}
			d.checkReleaseTags()
			wait.Reset(releaseTagsInterval)
		}
	})
}

// checkReleaseTags looks at every folder with a forge repo for a tag not yet linked.
func (d *Daemon) checkReleaseTags() {
	for _, folder := range d.folderPaths() {
		repo := d.folderRepo(folder)
		if repo.forge == "" {
			continue
		}
		d.checkReleaseTagsForFolder(d.ctx, folder, repo)
	}
}

func (d *Daemon) checkReleaseTagsForFolder(ctx context.Context, folder string, repo forgeRepo) {
	tags := gitVersionTags
	if d.releaseTags != nil {
		tags = d.releaseTags
	}
	found, err := tags(folder)
	if err != nil {
		log.Printf("lineage: the tags of %s: %v", folder, err)
		return
	}
	if len(found) == 0 {
		return
	}
	sortVersionTags(found)
	done := d.doneReleaseTags(repo)
	for i, tag := range found {
		if done[tag] {
			continue
		}
		prev := ""
		if i > 0 {
			prev = found[i-1]
		}
		if d.linkRelease(ctx, folder, repo, tag, prev) {
			d.markReleaseTagDone(repo, tag)
		}
	}
}

// linkRelease links tag's release node: its PRs (the commits since prev, when there is
// one) part-of it, and any milestone whose title starts with its version shipped-in it. It
// says whether the release is done: not when the forge could not say its commits, so the
// next hour tries again.
func (d *Daemon) linkRelease(ctx context.Context, folder string, repo forgeRepo, tag, prev string) bool {
	commitTime := forgeCommitTime
	if d.releaseCommitTime != nil {
		commitTime = d.releaseCommitTime
	}
	at, err := commitTime(ctx, folder, repo, tag)
	if err != nil {
		log.Printf("lineage: the commit time of %s %s: %v", repo.path, tag, err)
		return false
	}
	release := repo.release(tag)
	ok := true
	if prev != "" {
		compare := forgeCompareCommits
		if d.releaseCompare != nil {
			compare = d.releaseCompare
		}
		commits, err := compare(ctx, folder, repo, prev, tag)
		if err != nil {
			log.Printf("lineage: the commits of %s %s..%s: %v", repo.path, prev, tag, err)
			ok = false
		} else {
			d.linkReleaseCommits(ctx, folder, repo, release, at, commits)
		}
	}
	milestones := forgeMilestones
	if d.releaseMilestones != nil {
		milestones = d.releaseMilestones
	}
	found, err := milestones(ctx, folder, repo)
	if err != nil {
		log.Printf("lineage: the milestones of %s: %v", repo.path, err)
	} else {
		version := milestoneVersionOf(tag)
		for _, m := range found {
			if strings.HasPrefix(m.Title, version) {
				d.lineageDo(func() { d.linkAt(repo.milestone(m.Number), release, lineage.RelShippedIn, lineage.SourceForge, at) })
			}
		}
	}
	return ok
}

// linkReleaseCommits links the PR of each of commits, from its squash title or, when that
// has no number, the forge's own commits/<sha>/pulls, part-of release at at.
func (d *Daemon) linkReleaseCommits(ctx context.Context, folder string, repo forgeRepo, release wire.LineageNode, at time.Time, commits []compareCommit) {
	if len(commits) > releaseCommitsMax {
		log.Printf("lineage: %s %s has over %d commits; only the first %d are linked", repo.path, release.Ref, releaseCommitsMax, releaseCommitsMax)
		commits = commits[:releaseCommitsMax]
	}
	commitPR := forgeCommitPR
	if d.releaseCommitPR != nil {
		commitPR = d.releaseCommitPR
	}
	seen := map[int]bool{}
	for _, c := range commits {
		n, found := squashPRNumber(repo.forge, c.Message)
		if !found {
			asked, err := commitPR(ctx, folder, repo, c.SHA)
			if err != nil || asked <= 0 {
				continue
			}
			n = asked
		}
		if n <= 0 || seen[n] {
			continue
		}
		seen[n] = true
		pr := repo.pr(n)
		d.lineageDo(func() { d.linkAt(pr, release, lineage.RelPartOf, lineage.SourceForge, at) })
	}
}

// gitVersionTags is the v* tags of folder's origin, deduplicated, undated: git ls-remote
// gives no commit time, so a tag's own time is asked of the forge once it is new.
func gitVersionTags(folder string) ([]string, error) {
	out, err := git(folder, "ls-remote", "--tags", "origin")
	if err != nil {
		return nil, err
	}
	return versionTagsOf(out), nil
}

// versionTagsOf is the v* tags `git ls-remote --tags` named, deduplicated: a peeled
// "refs/tags/<tag>^{}" line (an annotated tag) names the same tag as its own line.
func versionTagsOf(out string) []string {
	seen := map[string]bool{}
	var tags []string
	for _, line := range strings.Split(out, "\n") {
		_, ref, ok := strings.Cut(strings.TrimSpace(line), "\t")
		if !ok {
			continue
		}
		ref = strings.TrimSuffix(ref, "^{}")
		tag, cut := strings.CutPrefix(ref, "refs/tags/")
		if !cut || !versionTagPattern.MatchString(tag) || seen[tag] {
			continue
		}
		seen[tag] = true
		tags = append(tags, tag)
	}
	return tags
}

// versionOf is tag's three numbers: v0.14.1 is [0, 14, 1].
func versionOf(tag string) [3]int {
	var v [3]int
	// A malformed tag never reaches here (versionTagPattern guards it); an error here is
	// only ever "fewer than three numbers", and v keeps the zeros for those.
	_, _ = fmt.Sscanf(strings.TrimPrefix(tag, "v"), "%d.%d.%d", &v[0], &v[1], &v[2])
	return v
}

// milestoneVersionOf is the version a milestone's title must start with to match tag: the
// tag without its leading v, a .0 patch dropped, as this repo names its minor milestones
// (v0.14.0 matches "0.14 Lineage and value"; v0.14.1 matches "0.14.1 Bug fixes").
func milestoneVersionOf(tag string) string {
	version := strings.TrimPrefix(tag, "v")
	if v := versionOf(tag); v[2] == 0 {
		if i := strings.LastIndex(version, "."); i >= 0 {
			return version[:i]
		}
	}
	return version
}

// sortVersionTags sorts tags by version, lowest first.
func sortVersionTags(tags []string) {
	sort.Slice(tags, func(i, j int) bool { return versionLess(versionOf(tags[i]), versionOf(tags[j])) })
}

func versionLess(a, b [3]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// compareCommit is one commit the forge's compare API named: its sha and message.
type compareCommit struct {
	SHA     string
	Message string
}

// forgeMilestone is one milestone the forge's list named: its number (GitLab: iid) and title.
type forgeMilestone struct {
	Number int
	Title  string
}

var (
	githubSquashPR = regexp.MustCompile(`\(#([0-9]+)\)\s*$`)
	gitlabSquashMR = regexp.MustCompile(`\(!([0-9]+)\)\s*$`)
)

// squashPRNumber is the PR or MR a squash commit's title names, from the "(#n)" GitHub
// adds, or the "(!n)" GitLab adds.
func squashPRNumber(forge, message string) (int, bool) {
	title, _, _ := strings.Cut(message, "\n")
	var re *regexp.Regexp
	switch forge {
	case "github":
		re = githubSquashPR
	case "gitlab":
		re = gitlabSquashMR
	default:
		return 0, false
	}
	m := re.FindStringSubmatch(strings.TrimRight(title, " "))
	if m == nil {
		return 0, false
	}
	n, err := strconv.Atoi(m[1])
	return n, err == nil && n > 0
}

// forgeCommitTime is the commit time of a tag or sha, asked of gh or glab in folder.
func forgeCommitTime(ctx context.Context, folder string, repo forgeRepo, ref string) (time.Time, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/commits/%s", repo.path, ref)
	case "gitlab":
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/repository/commits/%s", url.PathEscape(repo.path), ref)
	default:
		return time.Time{}, fmt.Errorf("no commits on %s", repo.forge)
	}
	if exe == "" {
		return time.Time{}, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return time.Time{}, err
	}
	return commitTimeOf(repo.forge, out)
}

func commitTimeOf(forge string, out []byte) (time.Time, error) {
	switch forge {
	case "github":
		var c struct {
			Commit struct {
				Committer struct {
					Date time.Time `json:"date"`
				} `json:"committer"`
			} `json:"commit"`
		}
		if err := json.Unmarshal(out, &c); err != nil {
			return time.Time{}, err
		}
		if c.Commit.Committer.Date.IsZero() {
			return time.Time{}, errors.New("the forge did not say the commit's date")
		}
		return c.Commit.Committer.Date, nil
	case "gitlab":
		var c struct {
			CommittedDate time.Time `json:"committed_date"`
		}
		if err := json.Unmarshal(out, &c); err != nil {
			return time.Time{}, err
		}
		if c.CommittedDate.IsZero() {
			return time.Time{}, errors.New("the forge did not say the commit's date")
		}
		return c.CommittedDate, nil
	}
	return time.Time{}, fmt.Errorf("no commits on %s", forge)
}

// forgeCompareCommits is the commits between base and head, asked of gh or glab in folder.
func forgeCompareCommits(ctx context.Context, folder string, repo forgeRepo, base, head string) ([]compareCommit, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/compare/%s...%s", repo.path, base, head)
	case "gitlab":
		exe, path = forgeCLI("glab"),
			fmt.Sprintf("projects/%s/repository/compare?from=%s&to=%s", url.PathEscape(repo.path), url.QueryEscape(base), url.QueryEscape(head))
	default:
		return nil, fmt.Errorf("no commits on %s", repo.forge)
	}
	if exe == "" {
		return nil, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return nil, err
	}
	return compareCommitsOf(repo.forge, out)
}

func compareCommitsOf(forge string, out []byte) ([]compareCommit, error) {
	switch forge {
	case "github":
		var r struct {
			Commits []struct {
				SHA    string `json:"sha"`
				Commit struct {
					Message string `json:"message"`
				} `json:"commit"`
			} `json:"commits"`
		}
		if err := json.Unmarshal(out, &r); err != nil {
			return nil, err
		}
		out2 := make([]compareCommit, 0, len(r.Commits))
		for _, c := range r.Commits {
			out2 = append(out2, compareCommit{c.SHA, c.Commit.Message})
		}
		return out2, nil
	case "gitlab":
		var r struct {
			Commits []struct {
				ID      string `json:"id"`
				Message string `json:"message"`
			} `json:"commits"`
		}
		if err := json.Unmarshal(out, &r); err != nil {
			return nil, err
		}
		out2 := make([]compareCommit, 0, len(r.Commits))
		for _, c := range r.Commits {
			out2 = append(out2, compareCommit{c.ID, c.Message})
		}
		return out2, nil
	}
	return nil, fmt.Errorf("no commits on %s", forge)
}

// forgeCommitPR is the PR (GitLab: MR) a commit is on, asked of gh or glab in folder, 0 for
// none: a squash commit whose title has no "(#n)" / "(!n)", such as a merge commit.
func forgeCommitPR(ctx context.Context, folder string, repo forgeRepo, sha string) (int, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/commits/%s/pulls", repo.path, sha)
	case "gitlab":
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/repository/commits/%s/merge_requests", url.PathEscape(repo.path), sha)
	default:
		return 0, fmt.Errorf("no commits on %s", repo.forge)
	}
	if exe == "" {
		return 0, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return 0, err
	}
	return commitPRNumberOf(repo.forge, out)
}

func commitPRNumberOf(forge string, out []byte) (int, error) {
	switch forge {
	case "github":
		var list []struct {
			Number int `json:"number"`
		}
		if err := json.Unmarshal(out, &list); err != nil {
			return 0, err
		}
		if len(list) == 0 {
			return 0, nil
		}
		return list[0].Number, nil
	case "gitlab":
		var list []struct {
			IID int `json:"iid"`
		}
		if err := json.Unmarshal(out, &list); err != nil {
			return 0, err
		}
		if len(list) == 0 {
			return 0, nil
		}
		return list[0].IID, nil
	}
	return 0, fmt.Errorf("no commits on %s", forge)
}

// forgeMilestones is every milestone of repo, open and closed, asked of gh or glab in folder.
func forgeMilestones(ctx context.Context, folder string, repo forgeRepo) ([]forgeMilestone, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/milestones?state=all&per_page=100", repo.path)
	case "gitlab":
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/milestones?state=all&per_page=100", url.PathEscape(repo.path))
	default:
		return nil, fmt.Errorf("no milestones on %s", repo.forge)
	}
	if exe == "" {
		return nil, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return nil, err
	}
	return milestonesOf(repo.forge, out)
}

func milestonesOf(forge string, out []byte) ([]forgeMilestone, error) {
	switch forge {
	case "github":
		var list []struct {
			Number int    `json:"number"`
			Title  string `json:"title"`
		}
		if err := json.Unmarshal(out, &list); err != nil {
			return nil, err
		}
		out2 := make([]forgeMilestone, 0, len(list))
		for _, m := range list {
			out2 = append(out2, forgeMilestone{m.Number, m.Title})
		}
		return out2, nil
	case "gitlab":
		var list []struct {
			IID   int    `json:"iid"`
			Title string `json:"title"`
		}
		if err := json.Unmarshal(out, &list); err != nil {
			return nil, err
		}
		out2 := make([]forgeMilestone, 0, len(list))
		for _, m := range list {
			out2 = append(out2, forgeMilestone{m.IID, m.Title})
		}
		return out2, nil
	}
	return nil, fmt.Errorf("no milestones on %s", forge)
}
