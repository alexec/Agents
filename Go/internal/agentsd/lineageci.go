package agentsd

import (
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// CI runs (#3581, spec 3579-outer-loop): the build stage of the outer loop, as a node.
//
//   - Kind ci-run, ref github:<owner>/<repo>/actions/run/<id> (GitLab:
//     gitlab:<group>/<project>/pipelines/<id>; Bitbucket: bitbucket:<workspace>/<repo>/pipelines/<n>,
//     the Pipelines run's build number; Azure DevOps: azuredevops:<org>/<project>/<repo>/builds/<id>,
//     the Azure Pipelines build's id). Not workflow-run: that is an Agents
//     workflow's run.
//   - checks.passed and checks.failed link the run builds its PR. A rerun has the same id,
//     so it is the same node.
//   - run.completed on a version tag (as release.yml on v0.16.0) links the run builds the
//     tag's release, whatever its conclusion: a failed release build is part of the story.
//   - CI time to green (#4554): checks.* say the run's head commit, when the run was made and
//     when it finished. The PR's cost node keeps its last head commit's first run and last
//     pass (notePRCI), for lineage.DeliveryOf.
//   - A PR keeps at most ciRunsPerPR active runs: an older run's link ends, and the store's
//     own bounds (KeepEnded, MostLinks) let it go.
//   - Deploys (#3584, #5241): a run's deploy notices no longer make nodes here. The deploy.*
//     events do (lineagedeploy.go), and the run builds each deploy it ran.

// ciRunsPerPR is how many runs a PR keeps active.
const ciRunsPerPR = 20

// ciRun is a CI run of r (#4800): <forge>:run:<path>#<id>, a GitHub Actions run, a GitLab or
// Bitbucket pipeline or an Azure Pipelines build.
func (r forgeRepo) ciRun(id int64) wire.LineageNode {
	return r.node(lineage.KindCIRun, "run", strconv.FormatInt(id, 10))
}

// ciRunPayload is what checks.passed, checks.failed and run.completed say of a run.
type ciRunPayload struct {
	PR struct {
		URL string `json:"url"`
	} `json:"pr"`
	// HeadSHA is checks.*'s head commit of the PR.
	HeadSHA string `json:"headSha"`
	Run     struct {
		ID     int64  `json:"id"`
		Branch string `json:"branch"`
		URL    string `json:"url"`
		// CreatedAt is when the run was made, by its push; a rerun keeps it (#4554).
		CreatedAt string `json:"createdAt"`
	} `json:"run"`
	CompletedAt string `json:"completedAt"`
}

// lineageCIEvent links the run a checks.* or run.completed event names.
func (d *Daemon) lineageCIEvent(e wire.Event) {
	var p ciRunPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil || p.Run.ID <= 0 {
		return
	}
	if e.Name == "run.completed" {
		repo, ok := repoOfRunURL(p.Run.URL)
		if !ok || !versionTagPattern.MatchString(p.Run.Branch) {
			return
		}
		at := nowFunc()
		if t, err := time.Parse(time.RFC3339, p.CompletedAt); err == nil {
			at = t
		}
		run, release := repo.ciRun(p.Run.ID), repo.release(p.Run.Branch)
		d.lineageDo(func() { d.linkAt(run, release, lineage.RelBuilds, lineage.SourceForge, at) })
		return
	}
	repo, n, ok := d.prOfURLHere(p.PR.URL)
	if !ok {
		return
	}
	run, pr := repo.ciRun(p.Run.ID), repo.pr(n)
	d.lineageDo(func() {
		d.link(run, pr, lineage.RelBuilds, lineage.SourceForge)
		d.boundCIRuns(pr)
		d.notePRCI(pr, p, e.Name == "checks.passed")
	})
}

// notePRCI keeps a PR's CI on its last head commit (#4554): when that commit's first run was
// made, and when the last of its runs that passed finished. A run of a new head commit starts
// it again; a run of an older commit, made before the kept one, changes nothing. An event
// with no head commit or no times (GitLab, Bitbucket, Azure DevOps) keeps nothing.
func (d *Daemon) notePRCI(pr wire.LineageNode, p ciRunPayload, passed bool) {
	created, err := time.Parse(time.RFC3339, p.Run.CreatedAt)
	if p.HeadSHA == "" || err != nil {
		return
	}
	pushed := wire.DateOf(created)
	var green *wire.Date
	if t, err := time.Parse(time.RFC3339, p.CompletedAt); passed && err == nil {
		g := wire.DateOf(t)
		green = &g
	}
	d.workMu.Lock()
	defer d.workMu.Unlock()
	if c, ok := d.costLedgerLocked().Nodes[costKey(pr)]; ok && c.Ci != nil && c.Ci.HeadSha != p.HeadSHA &&
		c.Ci.PushedAt != nil && pushed < *c.Ci.PushedAt {
		return
	}
	d.noteCostLocked(pr, nowFunc(), func(c *wire.LineageCostNode) {
		if c.Ci == nil || c.Ci.HeadSha != p.HeadSHA {
			c.Ci = &wire.LineagePRCI{HeadSha: p.HeadSHA}
		}
		if c.Ci.PushedAt == nil || pushed < *c.Ci.PushedAt {
			c.Ci.PushedAt = &pushed
		}
		if green != nil && (c.Ci.GreenAt == nil || *green > *c.Ci.GreenAt) {
			c.Ci.GreenAt = green
		}
	})
	d.costChangedLocked()
}

// boundCIRuns ends the builds links into pr past the newest ciRunsPerPR.
func (d *Daemon) boundCIRuns(pr wire.LineageNode) {
	kept := 0
	d.endLinks(pr, func(l wire.LineageLink) bool {
		if l.To != pr || l.Rel != lineage.RelBuilds || l.From.Kind != lineage.KindCIRun {
			return false
		}
		kept++
		return kept > ciRunsPerPR
	})
}

// repoOfRunURL is the repo of a GitHub Actions run's web address,
// github.com/<owner>/<repo>/actions/runs/<id>.
func repoOfRunURL(raw string) (forgeRepo, bool) {
	u, err := url.Parse(raw)
	if err != nil {
		return forgeRepo{}, false
	}
	path, _, ok := strings.Cut(strings.Trim(u.Path, "/"), "/actions/runs/")
	if !ok {
		return forgeRepo{}, false
	}
	r := forgeOf(u.Host, path)
	return r, r.forge == "github"
}
