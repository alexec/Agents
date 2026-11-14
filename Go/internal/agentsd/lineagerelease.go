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
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Release nodes from tags (#3023, part 1): the graph stopped at "merged"; this links a PR
// part-of the release that shipped it, so the graph and the cost rollup reach "got to people".
//
//   - Kind release, ref github:<owner>/<repo>/release/<tag> (GitLab: gitlab:<group>/<project>/release/<tag>;
//     Forgejo: forgejo:<owner>/<repo>/release/<tag>, Bitbucket: bitbucket:<workspace>/<repo>/release/<tag>,
//     and Azure DevOps: azuredevops:<org>/<project>/<repo>/release/<tag>, asked by their
//     connections, lineageforgejo.go, lineagebitbucket.go and lineageazuredevops.go).
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

// releaseTagsKept is how many done tags release-tags.json keeps for each repo (#3652): the
// newest. A tag older than the oldest kept is done too, so a dropped one is not linked again.
const releaseTagsKept = 50

type releaseTagsFile struct {
	// Done is each repo's (forge:path) tags already linked, so a tag is done once.
	Done map[string][]string `json:"done,omitempty"`
}

type releaseTagsBook struct {
	releaseMu   sync.Mutex
	releaseFile *releaseTagsFile
	// releaseTags, releaseCommitTime, releaseCompare and releaseCommitPR, when set,
	// are asked in place of the package defaults; only tests set them.
	releaseTags       func(folder string) ([]string, error)
	releaseCommitTime func(ctx context.Context, folder string, repo forgeRepo, ref string) (time.Time, error)
	releaseCompare    func(ctx context.Context, folder string, repo forgeRepo, base, head string) ([]compareCommit, error)
	releaseCommitPR   func(ctx context.Context, folder string, repo forgeRepo, sha string) (int, error)
}

func (r forgeRepo) release(tag string) wire.LineageNode {
	return r.node(lineage.KindRelease, "release", tag)
}

func (d *Daemon) releaseTagsPath() string {
	return filepath.Join(d.Store.Loc.Root, "release-tags.json")
}

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

// doneReleaseTags is a repo's done tags, and, when the list is full, the oldest of them:
// every tag older than that one is done too.
func (d *Daemon) doneReleaseTags(repo forgeRepo) (done map[string]bool, floor string) {
	d.releaseMu.Lock()
	defer d.releaseMu.Unlock()
	f := d.releaseTagsFileLocked()
	done = map[string]bool{}
	list := f.Done[repo.forge+":"+repo.path]
	for _, t := range list {
		done[t] = true
		if floor == "" || versionLess(versionOf(t), versionOf(floor)) {
			floor = t
		}
	}
	if len(list) < releaseTagsKept {
		floor = ""
	}
	return done, floor
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
	f.Done[key] = keepNewestTags(append(f.Done[key], tag))
	if err := writeStore(d.releaseTagsPath(), f); err != nil {
		log.Printf("release-tags.json: could not save: %v", err)
	}
}

// checkReleaseTagsEveryHour reads every folder's tags a minute after the start, then every
// hour, until Shutdown (#3522).
func (d *Daemon) checkReleaseTagsEveryHour() {
	d.goLoop("release tags", func(ctx context.Context) {
		wait := time.NewTimer(releaseTagsDelay)
		defer wait.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-wait.C:
			}
			d.checkReleaseTags(ctx)
			wait.Reset(releaseTagsInterval)
		}
	})
}

// checkReleaseTags looks at every folder with a repo on a forge lineage asks for a tag not yet linked.
func (d *Daemon) checkReleaseTags(ctx context.Context) {
	for _, folder := range d.folderPaths() {
		// A release's commits are asked by the forge's CLI (forgeKind.cli).
		repo := d.folderRepo(folder)
		if !repo.asks() {
			continue
		}
		d.checkReleaseTagsForFolder(ctx, folder, repo)
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
	done, floor := d.doneReleaseTags(repo)
	for i, tag := range found {
		if done[tag] || floor != "" && versionLess(versionOf(tag), versionOf(floor)) {
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
// one) part-of it. It says whether the release is done: not when the forge could not say its commits, so the
// next hour tries again.
func (d *Daemon) linkRelease(ctx context.Context, folder string, repo forgeRepo, tag, prev string) bool {
	commitTime, compare := forgeCommitTime, forgeCompareCommits
	if c, ok := d.connectionAsks(repo.forge); ok {
		commitTime, compare = c.commitTime, c.compare
	}
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
	if c, ok := d.connectionAsks(repo.forge); ok {
		commitPR = c.commitPR
	}
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

// sortVersionTags sorts tags by version, lowest first.
// keepNewestTags is tags sorted, the newest releaseTagsKept of them.
func keepNewestTags(tags []string) []string {
	sortVersionTags(tags)
	if n := len(tags) - releaseTagsKept; n > 0 {
		tags = slices.Clone(tags[n:])
	}
	return tags
}

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
	// At is when it was committed, zero when the forge did not say: a squash merge's is its
	// merge, the lead time's start (#5245).
	At time.Time
}

var (
	githubSquashPR = regexp.MustCompile(`\(#([0-9]+)\)\s*$`)
	gitlabSquashMR = regexp.MustCompile(`\(!([0-9]+)\)\s*$`)
	// bitbucketMergedPR is the "(pull request #n)" Bitbucket ends its merge and squash titles with.
	bitbucketMergedPR = regexp.MustCompile(`\(pull request #([0-9]+)\)\s*$`)
	// azureDevOpsMergedPR is the "Merged PR n: " Azure Repos starts its merge and squash titles with.
	azureDevOpsMergedPR = regexp.MustCompile(`^Merged PR ([0-9]+):`)
)

// squashPRNumber is the PR or MR a squash commit's title names, from the "(#n)" GitHub and
// Forgejo add, the "(!n)" GitLab adds, Bitbucket's "(pull request #n)", or Azure Repos's
// "Merged PR n: ".
func squashPRNumber(forge, message string) (int, bool) {
	title, _, _ := strings.Cut(message, "\n")
	var re *regexp.Regexp
	switch forge {
	case "github", "forgejo":
		re = githubSquashPR
	case "gitlab":
		re = gitlabSquashMR
	case "bitbucket":
		re = bitbucketMergedPR
	case "azuredevops":
		re = azureDevOpsMergedPR
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
					Message   string `json:"message"`
					Committer struct {
						Date time.Time `json:"date"`
					} `json:"committer"`
				} `json:"commit"`
			} `json:"commits"`
		}
		if err := json.Unmarshal(out, &r); err != nil {
			return nil, err
		}
		out2 := make([]compareCommit, 0, len(r.Commits))
		for _, c := range r.Commits {
			out2 = append(out2, compareCommit{SHA: c.SHA, Message: c.Commit.Message, At: c.Commit.Committer.Date})
		}
		return out2, nil
	case "gitlab":
		var r struct {
			Commits []struct {
				ID            string    `json:"id"`
				Message       string    `json:"message"`
				CommittedDate time.Time `json:"committed_date"`
			} `json:"commits"`
		}
		if err := json.Unmarshal(out, &r); err != nil {
			return nil, err
		}
		out2 := make([]compareCommit, 0, len(r.Commits))
		for _, c := range r.Commits {
			out2 = append(out2, compareCommit{SHA: c.ID, Message: c.Message, At: c.CommittedDate})
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
