package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/gitlabmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/internal/safe"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The links the host makes on its own (#2349), so agents and people seldom have to:
//
//   - A session's label #n, P#n, a Linear key (ENG-4) or a version tag (v1.2.0, #4524) is a
//     works-on link to that issue, PR or release: from the start (the Issues and PR pages give one), or added later by the agent
//     (set_session_labels) or the person. Taking the label off ends the link.
//   - A helper is started by its parent session, a workflow's session by its run, and the
//     run is part of its workflow. A run started by a PR's checks.* or pr.* event works on
//     that PR (#4524).
//   - pr.opened links the PR to every session that worked on its branch (opens), and the
//     PR to the issues its body closes (fixes). pr.merged and pr.closed link what its body
//     closes too, so a closed PR's cost stays against its issues (#2350).
//   - Each GitHub issue named here is part of its parent issue (lineageparent.go, #3582).
//   - A session opens each forge issue it files (lineagefiled.go, #3582).
//   - checks.passed and checks.failed link the CI run builds its PR; run.completed on a
//     version tag links the run builds its release (lineageci.go, #3581).
//   - pr.merged and pr.closed end the sessions' links to the PR; pr.closed also ends its
//     fixes links, as a PR closed without a merge fixed nothing. An archived session's
//     links end.
//
// The work is done in order on one goroutine, off the agent lock: a label's issue needs
// the folder's git remote.

// lineageJobsHeld bounds the work waiting; past it, a link is dropped and logged.
const lineageJobsHeld = 1024

// linkerMu guards linkerJobs and linkerDone. stopLinker closes the jobs, so the goroutine
// ends with the host (#3617); work given after that is dropped.
type lineageLinker struct {
	linkerMu   sync.Mutex
	linkerJobs chan func()
	linkerDone bool
	repoMu     sync.Mutex
	// repos is each folder's forge repo, looked up again only when its git config changes.
	repos map[string]forgeRepo
	// otherHost is each folder in repos whose origin is on a host forgeOf does not name: it
	// may be the connected Forgejo's, which can change.
	otherHost map[string]bool
	// topics is each folder's topic for its agents nodes (folderTopic), looked up once.
	topics map[string]string
	// configs is each folder's git config file and when it last changed, as repos and topics
	// were read: a change (a new origin after a repo moved) reads them again (#5335).
	configs map[string]gitConfigStamp
}

// gitConfigStamp is a folder's git config file and its modification time.
type gitConfigStamp struct {
	path string
	mod  time.Time
}

// forgetChangedRemote drops what repos, otherHost and topics keep for folder when its git
// config changed since they were read. It costs one stat a call, and one git the first time.
func (d *Daemon) forgetChangedRemote(folder string) {
	d.repoMu.Lock()
	c, ok := d.configs[folder]
	d.repoMu.Unlock()
	if !ok {
		if dir, err := git(folder, "rev-parse", "--git-common-dir"); err == nil && dir != "" {
			if !filepath.IsAbs(dir) {
				dir = filepath.Join(folder, dir)
			}
			c.path = filepath.Join(dir, "config")
		}
	}
	var mod time.Time
	if c.path != "" {
		if fi, err := os.Stat(c.path); err == nil {
			mod = fi.ModTime()
		}
	}
	d.repoMu.Lock()
	defer d.repoMu.Unlock()
	if ok && mod.Equal(c.mod) {
		return
	}
	if ok {
		delete(d.repos, folder)
		delete(d.otherHost, folder)
		delete(d.topics, folder)
	}
	if d.configs == nil {
		d.configs = map[string]gitConfigStamp{}
	}
	d.configs[folder] = gitConfigStamp{path: c.path, mod: mod}
}

// forgeRepo is a repository on a forge, as lineage refs name it: forge github, gitlab, forgejo,
// bitbucket or azuredevops, path owner/repo (group/sub/project on GitLab, workspace/repo on
// Bitbucket, organization/project/repo on Azure DevOps), lower case. The zero value is none.
type forgeRepo struct{ forge, path string }

// forgeKind is what lineage does on one forge. A forge that is not in forgeKinds has no
// lineage; a new one is a row here, and each lookup's switch
// (lineageresolve.go, lineageparent.go, lineagerelease.go, lineagecomment.go, the doc and
// ref addresses) says what it asks there, or nothing.
type forgeKind struct {
	// prMark is between a pull request node's path and its number: GitLab numbers its merge
	// requests apart from its issues, so its mark is !.
	prMark string
	// prPath and issuePath are in a pull request's and an issue's web address; a forge with
	// no issues of its own has no issuePath.
	prPath, issuePath string
	// anyHost: the pull request's address says the forge on a host of any name.
	anyHost bool
	// cli is the person's CLI that lineage asks the forge with: a node's title, a GitHub
	// issue's parent, a release's commits, a merged pull request's cost comment.
	cli string
	// connection: lineage asks the forge the same by the person's connection to it
	// (connectionAsks: lineageforgejo.go, lineagebitbucket.go, lineageazuredevops.go), not a CLI. With neither, the
	// forge's nodes are linked, and nothing is looked up.
	connection bool
}

// forgeKinds, GitLab first: its addresses have a /-/ that GitHub's do not.
var forgeKinds = []struct {
	name string
	forgeKind
}{
	{"gitlab", forgeKind{prMark: "!", prPath: "/-/merge_requests/", issuePath: "/-/issues/", cli: "glab"}},
	{"github", forgeKind{prMark: "#", prPath: "/pull/", issuePath: "/issues/", cli: "gh"}},
	// Forgejo and Gitea number issues and pull requests together, as forgeforgejo.go's nodes
	// say. Only they say /pulls/12. They are asked by their connection, not a CLI.
	{"forgejo", forgeKind{prMark: "#", prPath: "/pulls/", issuePath: "/issues/", anyHost: true, connection: true}},
	// Bitbucket Cloud numbers its pull requests apart from its issues, but forgebitbucket.go's
	// nodes say both with #: the node's kind says which. It is only on bitbucket.org.
	{"bitbucket", forgeKind{prMark: "#", prPath: "/pull-requests/", issuePath: "/issues/", connection: true}},
	// Azure Repos has pull requests only: its issues are Azure Boards' work items (forgeRepo.issue).
	// Its pull request's address has /_git/ in it, on dev.azure.com or a Server of any name.
	{"azuredevops", forgeKind{prMark: "#", prPath: "/pullrequest/", anyHost: true, connection: true}},
}

// kindOf is forge's row of forgeKinds.
func kindOf(forge string) (forgeKind, bool) {
	for _, k := range forgeKinds {
		if k.name == forge {
			return k.forgeKind, true
		}
	}
	return forgeKind{}, false
}

// asks says lineage asks r's forge, by its CLI or its connection, about r's nodes.
func (r forgeRepo) asks() bool {
	k, _ := kindOf(r.forge)
	return k.cli != "" || k.connection
}

// forgeAsks is what lineage asks a forge by the person's connection to it (forgeKind.connection),
// each in the shape of the gh and glab default it takes the place of: a node's title and state
// (lineageresolve.go), a release's commit time, commits and pull requests (lineagerelease.go), and the cost comment on a merged
// pull request (lineagecomment.go). The folder each is given is not used: the connection is
// the person's in every folder.
type forgeAsks struct {
	resolve     resolveLookup
	commitTime  func(ctx context.Context, folder string, repo forgeRepo, ref string) (time.Time, error)
	compare     func(ctx context.Context, folder string, repo forgeRepo, base, head string) ([]compareCommit, error)
	commitPR    func(ctx context.Context, folder string, repo forgeRepo, sha string) (int, error)
	costComment func(ctx context.Context, r prCommentRecord, body string) (string, error)
}

// connectionAsks is what lineage asks forge by its connection; not ok for a forge it asks by
// a CLI, or not at all. A new forge with a connection is a case here.
func (d *Daemon) connectionAsks(forge string) (forgeAsks, bool) {
	switch forge {
	case "forgejo":
		return forgeAsks{d.forgejoResolveNode, d.forgejoCommitTime, d.forgejoCompareCommits, d.forgejoCommitPR,
			d.forgejoCostComment}, true
	case "bitbucket":
		return forgeAsks{d.bitbucketResolveNode, d.bitbucketCommitTime, d.bitbucketCompareCommits, d.bitbucketCommitPR,
			d.bitbucketCostComment}, true
	case "azuredevops":
		return forgeAsks{d.azureDevOpsResolveNode, d.azureDevOpsCommitTime, d.azureDevOpsCompareCommits,
			d.azureDevOpsCommitPR, d.azureDevOpsCostComment}, true
	}
	return forgeAsks{}, false
}

// issue is an issue of r; on Azure Repos, the work item n of r's project on Azure Boards, as a
// pull request's "#12" names one there.
func (r forgeRepo) issue(n int) wire.LineageNode {
	if r.forge == "azuredevops" {
		org, rest, _ := strings.Cut(r.path, "/")
		project, _, _ := strings.Cut(rest, "/")
		return boardsNode(org+"/"+project, n)
	}
	return r.node(lineage.KindIssue, "issue", strconv.Itoa(n))
}

// pr is a pull request, or a merge request on GitLab.
func (r forgeRepo) pr(n int) wire.LineageNode {
	return r.node(lineage.KindPR, wire.PullType(r.forge), strconv.Itoa(n))
}

// node is the node of kind for a thing of type typ in r, by its id (#4800):
// <forge>:<type>:<path>#<id>, such as github:pr:alexec/agents#12.
func (r forgeRepo) node(kind, typ, id string) wire.LineageNode {
	return lineage.NodeOf(kind, wire.Ref{Provider: r.forge, Type: typ, Topic: r.path, ID: id})
}

// repoOfRef is the repo of a node's ref in the full form (or the old form, as lineage.RefOf
// reads it), when it is on a forge forgeKinds names; its number is the ref's id, when it is
// one.
func repoOfRef(n wire.LineageNode) (forgeRepo, int, bool) {
	r, ok := lineage.RefOf(n)
	if !ok {
		return forgeRepo{}, 0, false
	}
	if _, known := kindOf(r.Provider); !known || r.Topic == "" {
		return forgeRepo{}, 0, false
	}
	num, err := strconv.Atoi(r.ID)
	if err != nil || num <= 0 {
		num = 0
	}
	return forgeRepo{r.Provider, r.Topic}, num, true
}

// forgeOf is the forge a remote is on: github.com, a host whose name says GitLab, codeberg.org
// or a host whose name says Forgejo or Gitea (as forgejomcp.RepoAt finds one), bitbucket.org,
// or Azure DevOps Services (dev.azure.com, <org>.visualstudio.com). A Forgejo, a GitLab or an
// Azure DevOps Server of another name is the connected one's, which folderRepo asks for.
func forgeOf(host, path string) forgeRepo {
	path = repoPath(path)
	switch host = strings.ToLower(host); {
	case path == "":
		return forgeRepo{}
	case host == "github.com":
		return forgeRepo{"github", path}
	case host == bitbucketmcp.Host:
		// A workspace's repository, never under a group.
		if strings.Count(path, "/") != 1 {
			return forgeRepo{}
		}
		return forgeRepo{"bitbucket", path}
	case host == "dev.azure.com" || host == "ssh.dev.azure.com" || strings.HasSuffix(host, ".visualstudio.com"):
		if repo, ok := azureDevOpsOfPath(host, path, false); ok {
			return forgeRepo{"azuredevops", repo}
		}
		return forgeRepo{}
	case strings.Contains(host, "gitlab"):
		return forgeRepo{"gitlab", path}
	case strings.Contains(host, "forgejo") || strings.Contains(host, "gitea") || strings.Contains(host, "codeberg"):
		return forgeRepo{"forgejo", path}
	}
	return forgeRepo{}
}

// repoPath is a repository's path as a node names it: lower case, with no .git.
func repoPath(path string) string {
	return strings.ToLower(strings.TrimSuffix(strings.Trim(path, "/"), ".git"))
}

// ofURL is the repo and number of the issue (or, pr, the pull request) at a forge's web
// address, by its host and path: github.com/o/r/issues/5, <gitlab>/group/project/-/issues/5,
// <forgejo>/o/r/pulls/5, bitbucket.org/w/r/pull-requests/5,
// dev.azure.com/org/project/_git/repo/pullrequest/5. The first forge whose address the
// path has must be one whose host it is on: GitHub's, Forgejo's and Bitbucket's issues have
// the same address.
func ofURL(host, path string, pr bool) (forgeRepo, int, bool) {
	matched := ""
	for _, k := range forgeKinds {
		sep := k.issuePath
		if pr {
			sep = k.prPath
		}
		if sep == "" || matched != "" && sep != matched {
			continue
		}
		repo, num, ok := strings.Cut(path, sep)
		if !ok {
			continue
		}
		matched = sep
		n, err := strconv.Atoi(strings.SplitN(num, "/", 2)[0])
		if err != nil || n <= 0 {
			return forgeRepo{}, 0, false
		}
		r := forgeOf(host, repo)
		if r.forge == "" && pr && k.anyHost {
			r = anyHostRepo(k.name, host, repo)
		}
		if r.path != "" && r.forge == k.name {
			return r, n, true
		}
	}
	return forgeRepo{}, 0, false
}

// anyHostRepo is the repo of forge's pull request address on a host whose name does not say
// it, by the path up to its prPath: owner/repo on a Forgejo, and the Server's
// collection/project/_git/repo on Azure DevOps.
func anyHostRepo(forge, host, path string) forgeRepo {
	if forge != "azuredevops" {
		return forgeRepo{forge, repoPath(path)}
	}
	if repo, ok := azureDevOpsOfPath(host, path, true); ok {
		return forgeRepo{forge, repo}
	}
	return forgeRepo{}
}

// prOfURL is the repo and number of a PR's web address: github.com/o/r/pull/5,
// <gitlab>/group/project/-/merge_requests/5, <forgejo>/o/r/pulls/5,
// bitbucket.org/w/r/pull-requests/5, or dev.azure.com/org/project/_git/repo/pullrequest/5.
func prOfURL(raw string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	if err != nil {
		return forgeRepo{}, 0, false
	}
	return ofURL(u.Host, strings.Trim(u.Path, "/"), true)
}

// sessionNode is a session's node (#4800), agents:session:<topic>#<id>, as the store names it:
// the topic is its folder's repo (folderTopic). Not under the agent lock: the first look at a
// folder asks git.
func (d *Daemon) sessionNode(id wire.UUID) wire.LineageNode {
	return d.lineage().Canon(lineage.SessionNode(d.agentsTopic(lineage.KindSession, string(id)), string(id)))
}

// agentsTopic is the topic of an agents node (#4800): the repo of the folder a session is in,
// or a workflow (<folder>/<name>) is of; "" when it is not known. lineage.OpenWith asks it for
// the lines in the old form.
func (d *Daemon) agentsTopic(kind, id string) string {
	switch kind {
	case lineage.KindSession:
		if a := d.Store.Agent(wire.UUID(id)); a != nil {
			return d.folderTopic(folderPath(a))
		}
	case lineage.KindWorkflow:
		if i := strings.LastIndex(id, "/"); i > 0 {
			return d.folderTopic(id[:i])
		}
	}
	return ""
}

// folderTopic is the topic of a folder's agents nodes: the path of its origin's repo, lower
// case, as forgeOf reads it on a forge it knows (owner/repo), else the remote's path; "" with
// no origin. It asks git once per folder, and never a forge, so it does not change with a
// connection.
func (d *Daemon) folderTopic(folder string) string {
	d.forgetChangedRemote(folder)
	d.repoMu.Lock()
	t, ok := d.topics[folder]
	d.repoMu.Unlock()
	if ok {
		return t
	}
	out, err := git(folder, "remote", "get-url", "origin")
	if err != nil && !isDir(folder) {
		return ""
	}
	if remote, ok := parseRemote(out); err == nil && ok {
		if r := forgeOf(remote.host, remote.path); r.forge != "" {
			t = r.path
		} else {
			t = repoPath(remote.path)
		}
	}
	if strings.ContainsAny(t, ":#") {
		t = ""
	}
	d.repoMu.Lock()
	if d.topics == nil {
		d.topics = map[string]string{}
	}
	d.topics[folder] = t
	d.repoMu.Unlock()
	return t
}

var (
	issueLabel  = regexp.MustCompile(`^#([0-9]{1,9})$`)
	prLabel     = regexp.MustCompile(`^P#([0-9]{1,9})$`)
	linearLabel = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}-[0-9]{1,9}$`)
	// linearTeam is a Linear team's key, as ENG.
	linearTeam = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}$`)
	// keyInText is a key in a PR's title or branch, in either case, not inside a longer word.
	keyInText = regexp.MustCompile(`(?i)\b[A-Z][A-Z0-9]{0,9}-[0-9]{1,9}\b`)
)

// labelNode is the issue, PR or release a label names, in the folder's repo: #n, P#n, a
// version tag such as v1.2.0 (its release, so a release session's cost goes on it, #4524), or
// a key such as ENG-4: on Jira when the folder's .agents/folder.json names its project in
// "jiraProjects" (#3260), else on Linear; or AB#n, a work item of the folder's Azure Boards
// project (#3815).
func (d *Daemon) labelNode(folder, label string) (wire.LineageNode, bool) {
	if versionTagPattern.MatchString(label) {
		repo := d.folderRepo(folder)
		return repo.release(label), repo.forge != ""
	}
	if linearLabel.MatchString(label) {
		return keyNode(label, d.folderJiraProjects(folder)), true
	}
	if abLabel.MatchString(label) {
		return d.boardsLabelNode(folder, label)
	}
	issue, pr := issueLabel.FindStringSubmatch(label), prLabel.FindStringSubmatch(label)
	if issue == nil && pr == nil {
		return wire.LineageNode{}, false
	}
	repo := d.folderRepo(folder)
	if repo.forge == "" {
		return wire.LineageNode{}, false
	}
	if issue != nil {
		n, _ := strconv.Atoi(issue[1])
		return repo.issue(n), n > 0
	}
	n, _ := strconv.Atoi(pr[1])
	return repo.pr(n), n > 0
}

// keyNode is the issue a key (ENG-4) names: on Jira when its project is one of jira, else on Linear.
func keyNode(key string, jira []string) wire.LineageNode {
	if project, _, _ := strings.Cut(key, "-"); slices.Contains(jira, project) {
		return jiraNode(key)
	}
	return linearNode(key)
}

// jiraKeys are the keys of the Jira projects jira that text names, each once: a PR's title or
// branch, as ABC-123 or abc-123-fix-it (#3260).
func jiraKeys(text string, jira []string) []string {
	var keys []string
	for _, m := range keyInText.FindAllString(text, -1) {
		key := strings.ToUpper(m)
		if project, _, _ := strings.Cut(key, "-"); slices.Contains(jira, project) && !slices.Contains(keys, key) {
			keys = append(keys, key)
		}
	}
	return keys
}

// folderRepo is the forge repo a folder pushes to, from its origin remote: on a host whose name
// says its forge, or on the connected Forgejo, GitLab or Azure DevOps Server.
func (d *Daemon) folderRepo(folder string) forgeRepo {
	d.forgetChangedRemote(folder)
	d.repoMu.Lock()
	r, ok := d.repos[folder]
	other := d.otherHost[folder]
	d.repoMu.Unlock()
	if ok {
		if other {
			return d.connectedRepo(folder)
		}
		return r
	}
	if out, err := git(folder, "remote", "get-url", "origin"); err == nil {
		if remote, ok := parseRemote(out); ok {
			r = forgeOf(remote.host, remote.path)
			other = r.forge == ""
		}
	} else if !isDir(folder) {
		// A folder gone is not remembered, in case it comes back.
		return forgeRepo{}
	}
	d.repoMu.Lock()
	if d.repos == nil {
		d.repos = map[string]forgeRepo{}
	}
	d.repos[folder] = r
	if other {
		if d.otherHost == nil {
			d.otherHost = map[string]bool{}
		}
		d.otherHost[folder] = true
	}
	d.repoMu.Unlock()
	if other {
		return d.connectedRepo(folder)
	}
	return r
}

// connectedRepo is folder's repo on the connected Forgejo, else on the connected GitLab (#4118),
// else on the connected Azure DevOps Server, as the Work pages find each (azureDevOpsRepoAt), or
// none.
func (d *Daemon) connectedRepo(folder string) forgeRepo {
	if r := d.connectedForgejoRepo(folder); r.forge != "" {
		return r
	}
	if r := d.connectedGitLabRepo(folder); r.forge != "" {
		return r
	}
	if _, repo := d.azureDevOpsRepoAt(context.Background(), folder); repo != "" {
		return forgeRepo{"azuredevops", strings.ToLower(repo)}
	}
	return forgeRepo{}
}

// connectedForgejoRepo is folder's repo on the connected Forgejo, as the Work pages find it
// (forgejoForge.Sources), or none.
func (d *Daemon) connectedForgejoRepo(folder string) forgeRepo {
	c, root := d.forgejoRoot()
	if root == "" {
		return forgeRepo{}
	}
	if at, repo := d.forgejoRepoAt(context.Background(), folder, c.URL); at == root && repo != "" {
		return forgeRepo{"forgejo", repoPath(repo)}
	}
	return forgeRepo{}
}

// connectedGitLabRepo is folder's project on the connected GitLab, as the Work pages find it
// (gitlabProjectAt), or none: a self-hosted GitLab's host need not say "gitlab".
func (d *Daemon) connectedGitLabRepo(folder string) forgeRepo {
	gl, connected := d.gitlabConnection()
	if !connected || !gl.Usable(nowFunc()) {
		return forgeRepo{}
	}
	if at, project := d.gitlabProjectAt(context.Background(), folder, gl.URL); at == gitlabmcp.BaseURL(gl.URL) && project != "" {
		return forgeRepo{"gitlab", repoPath(project)}
	}
	return forgeRepo{}
}

// lineageDo runs f after the work before it, on the linker's goroutine. It is false when
// f is dropped: the linker is stopped, or too much work waits.
func (d *Daemon) lineageDo(f func()) bool {
	d.linkerMu.Lock()
	defer d.linkerMu.Unlock()
	if d.linkerDone {
		return false
	}
	if d.linkerJobs == nil {
		d.linkerJobs = make(chan func(), lineageJobsHeld)
		jobs := d.linkerJobs
		safe.Go("lineage links", func() {
			for job := range jobs {
				job()
			}
		})
	}
	select {
	case d.linkerJobs <- f:
		return true
	default:
		log.Printf("lineage: %d links wait to be written; one was dropped", lineageJobsHeld)
		return false
	}
}

// stopLinker ends the linker's goroutine once the work given so far is done.
func (d *Daemon) stopLinker() {
	d.linkerMu.Lock()
	defer d.linkerMu.Unlock()
	if !d.linkerDone && d.linkerJobs != nil {
		close(d.linkerJobs)
	}
	d.linkerDone = true
}

// lineageSettle waits, at most wait, for the work given so far.
func (d *Daemon) lineageSettle(wait time.Duration) {
	done := make(chan struct{})
	if !d.lineageDo(func() { close(done) }) {
		return
	}
	select {
	case <-done:
	case <-time.After(wait):
	}
}

func (d *Daemon) link(from, to wire.LineageNode, rel, source string) {
	d.linkAt(from, to, rel, source, nowFunc())
}

// linkAt is link, at a time other than now: a release's links are backfilled to the tag's
// commit time (#3023), so a tag found hours or days late still lands where it happened.
func (d *Daemon) linkAt(from, to wire.LineageNode, rel, source string, at time.Time) {
	if _, err := d.lineage().Link(wire.LineageLinkRequest{From: from, To: to, Rel: rel, Source: source}, at); err != nil {
		log.Printf("lineage: %s %s %s: %v", from.Ref, rel, to.Ref, err)
	}
}

func (d *Daemon) unlink(from, to wire.LineageNode, rel string) {
	if _, err := d.lineage().End(wire.LineageEndRequest{From: from, To: to, Rel: rel}, nowFunc()); err != nil {
		log.Printf("lineage: end %s %s %s: %v", from.Ref, rel, to.Ref, err)
	}
}

// endLinks ends a node's active links that keep, either way.
func (d *Daemon) endLinks(n wire.LineageNode, keep func(wire.LineageLink) bool) {
	for _, l := range d.lineage().Links(n).Links {
		if l.EndedAt == nil && keep(l) {
			d.unlink(l.From, l.To, l.Rel)
		}
	}
}

// noteLineage makes the links a session's change says: before is nil for a new record.
func (d *Daemon) noteLineage(before *wire.Agent, a wire.Agent) {
	if a.Purpose != nil {
		return
	}
	d.noteSessionState(before, a)
	var was wire.Agent
	if before != nil {
		was = *before
	}
	had := map[string]bool{}
	for _, l := range was.Labels {
		had[l.Value] = true
	}
	has := map[string]bool{}
	var added []wire.SessionLabel
	for _, l := range a.Labels {
		has[l.Value] = true
		if !had[l.Value] {
			added = append(added, l)
		}
	}
	var removed []string
	for _, l := range was.Labels {
		if !has[l.Value] {
			removed = append(removed, l.Value)
		}
	}
	newly := func(now, then *wire.UUID) *wire.UUID {
		if now != nil && (then == nil || *then != *now) {
			return now
		}
		return nil
	}
	helper := newly(a.StartedByAgent, was.StartedByAgent)
	run := newly(a.StartedByRun, was.StartedByRun)
	var workflow *string
	if a.StartedByWorkflow != nil && (was.StartedByWorkflow == nil || *was.StartedByWorkflow != *a.StartedByWorkflow) {
		workflow = a.StartedByWorkflow
	}
	archived := before != nil && was.State != wire.AgentStateArchived && a.State == wire.AgentStateArchived
	if len(added) == 0 && len(removed) == 0 && helper == nil && run == nil && workflow == nil && !archived {
		return
	}
	folder := folderPath(&a)
	d.lineageDo(func() {
		s := d.sessionNode(a.ID)
		if helper != nil {
			d.link(d.sessionNode(*helper), s, lineage.RelStarted, lineage.SourceHelper)
		}
		if workflow != nil || run != nil {
			var wf wire.LineageNode
			if workflow != nil {
				wf = lineage.NodeOf(lineage.KindWorkflow,
					wire.Ref{Provider: "agents", Type: "workflow", Topic: d.folderTopic(folder), ID: folder + "/" + *workflow})
				wf = d.lineage().Canon(wf)
			}
			switch {
			case run != nil:
				r := d.lineage().Canon(lineage.NodeOf(lineage.KindWorkflowRun,
					wire.Ref{Provider: "agents", Type: "workflow-run", Topic: d.folderTopic(folder), ID: string(*run)}))
				d.link(r, s, lineage.RelStarted, lineage.SourceHelper)
				if workflow != nil {
					d.link(r, wf, lineage.RelPartOf, lineage.SourceHelper)
				}
			default:
				d.link(wf, s, lineage.RelStarted, lineage.SourceHelper)
			}
		}
		for _, l := range added {
			to, ok := d.labelNode(folder, l.Value)
			if !ok {
				continue
			}
			source := lineage.SourceStart
			if before != nil {
				source = lineage.SourcePerson
				if l.Owner == wire.SessionLabelOwnerAgent {
					source = lineage.SourceAgent
				}
			}
			d.link(s, to, lineage.RelWorksOn, source)
			d.lineageReportsHealth(s, to)
			if repo, n, ok := issueOfNode(to); ok {
				d.noteIssueParent(folder, repo, n)
			}
		}
		for _, v := range removed {
			if to, ok := d.labelNode(folder, v); ok {
				d.unlink(s, to, lineage.RelWorksOn)
			}
		}
		if archived {
			d.endLinks(s, func(l wire.LineageLink) bool { return l.From == s })
		}
	})
}

// prEventPayload is what a pr.* event of the GitHub and GitLab servers says of its PR.
type prEventPayload struct {
	PR struct {
		Title  string   `json:"title"`
		Branch string   `json:"branch"`
		URL    string   `json:"url"`
		Fixes  []string `json:"fixes"`
	} `json:"pr"`
	OpenedAt string `json:"openedAt"`
}

// lineagePRStarted links the session a workflow run started works-on the PR the event that
// started it names (#4524), so a fix-failed-checks run's cost goes on its PR: checks.*, and
// pr.* on an open PR. Not pr.merged or pr.closed: the PR is done, and what follows (a ship,
// a clean-up) is other work. pr.merged and pr.closed end the link, as they do every session's.
func (d *Daemon) lineagePRStarted(e wire.Event, session wire.UUID) {
	switch e.Name {
	case "pr.merged", "pr.closed":
		return
	}
	if !strings.HasPrefix(e.Name, "pr.") && !strings.HasPrefix(e.Name, "checks.") {
		return
	}
	var p prEventPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.PR.URL == "" {
		return
	}
	repo, n, ok := d.prOfURLHere(p.PR.URL)
	if !ok {
		return
	}
	d.lineageDo(func() { d.link(d.sessionNode(session), repo.pr(n), lineage.RelWorksOn, lineage.SourceHelper) })
}

// lineageEvent makes the links a raised event says: pr.opened, pr.merged and pr.closed,
// the CI runs of checks.* and run.completed (lineageci.go), the health signals of
// health.* (lineagehealth.go), and the approval wait of pr.labelled, pr.reviewed and
// pr.commented (lineageapproval.go).
func (d *Daemon) lineageEvent(e wire.Event) {
	switch e.Name {
	case "checks.failed", "checks.passed", "run.completed":
		d.lineageCIEvent(e)
		// A run finished: the build timings read it soon (#5177).
		d.kickCITimings()
	case "health.issue_new", "health.issue_regressed":
		d.lineageHealthEvent(e)
		return
	case "health.incident_started":
		d.lineageIncidentEvent(e)
		return
	case "pr.labelled", "pr.reviewed", "pr.commented":
		d.lineageApprovalEvent(e)
		return
	}
	switch e.Name {
	case "pr.opened", "pr.merged", "pr.closed", "checks.failed":
	default:
		return
	}
	var p prEventPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil {
		return
	}
	repo, n, ok := d.prOfURLHere(p.PR.URL)
	if !ok {
		return
	}
	pr := repo.pr(n)
	if e.Name == "checks.failed" {
		d.lineageDo(func() { d.notePROutcome(pr, e.Name, p.PR.Title) })
		return
	}
	var sessions []wire.UUID
	if e.Name == "pr.opened" && p.PR.Branch != "" {
		for _, a := range d.Store.Agents() {
			if a.Worktree != nil && a.Worktree.Branch != nil && *a.Worktree.Branch == p.PR.Branch && a.Purpose == nil {
				sessions = append(sessions, a.ID)
			}
		}
	}
	d.lineageDo(func() {
		for _, id := range sessions {
			// The same branch name in another repo is another branch.
			if a := d.Store.Agent(id); a != nil && d.folderRepo(folderPath(a)) == repo {
				d.link(d.sessionNode(id), pr, lineage.RelOpens, lineage.SourceBranch)
			}
		}
		// A PR closed without a merge links its issues too, and the links end below: it fixed
		// nothing, but its cost stays against them, as waste (#2350).
		folder := ""
		if len(p.PR.Fixes) > 0 {
			folder = d.repoFolder(repo)
		}
		for _, f := range p.PR.Fixes {
			if issue, ok := fixedIssue(repo, f); ok {
				d.link(pr, issue, lineage.RelFixes, lineage.SourcePRBody)
				if r, n, ok := issueOfNode(issue); ok {
					d.noteIssueParent(folder, r, n)
				}
			}
		}
		// A Jira key in its title or branch, of a project its repo's folder names (#3260): a PR
		// is never on the Jira site, so this is the way its cost reaches the Jira issue.
		if jira := d.folderJiraProjects(d.repoFolder(repo)); len(jira) > 0 {
			for _, key := range jiraKeys(p.PR.Title, jira) {
				d.link(pr, jiraNode(key), lineage.RelFixes, lineage.SourcePRBody)
			}
			for _, key := range jiraKeys(p.PR.Branch, jira) {
				d.link(pr, jiraNode(key), lineage.RelFixes, lineage.SourceBranch)
			}
		}
		// AB#12 in its title or branch, a work item of its repo's folder's first Azure Boards
		// project (#3815), as Azure Boards itself links a commit or a pull request to one.
		if boards := d.folderBoardsProjects(d.repoFolder(repo)); len(boards) > 0 {
			for _, id := range boardsKeys(p.PR.Title) {
				d.link(pr, boardsNode(boards[0], id), lineage.RelFixes, lineage.SourcePRBody)
			}
			for _, id := range boardsKeys(p.PR.Branch) {
				d.link(pr, boardsNode(boards[0], id), lineage.RelFixes, lineage.SourceBranch)
			}
		}
		// The approval wait's start when its label is unknown (#4553).
		if at, ok := payloadTime(p.OpenedAt); ok && e.Name == "pr.opened" {
			d.notePROpened(pr, at)
		}
		// How it ended, for its cost (#2350).
		d.notePROutcome(pr, e.Name, p.PR.Title)
		if e.Name == "pr.merged" {
			// Its cost, on the PR (#2352).
			d.prMerged(repo, n, pr)
			// Its files and the PR it reverts, for the delivery figures (#4552).
			d.askPRFacts(repo, n, pr)
		}
		if e.Name == "pr.opened" {
			return
		}
		closed := e.Name == "pr.closed"
		d.endLinks(pr, func(l wire.LineageLink) bool {
			return l.To == pr && l.From.Kind == lineage.KindSession || closed && l.From == pr && l.Rel == lineage.RelFixes
		})
	})
}

// fixedIssue is the issue a PR's fixes names: "#12" in the PR's own repo, or
// "owner/repo#12" on the same forge.
func fixedIssue(repo forgeRepo, ref string) (wire.LineageNode, bool) {
	path, num, ok := strings.Cut(ref, "#")
	n, err := strconv.Atoi(num)
	if !ok || err != nil || n <= 0 {
		return wire.LineageNode{}, false
	}
	if path != "" {
		repo = forgeRepo{repo.forge, strings.ToLower(path)}
	}
	return repo.issue(n), true
}
